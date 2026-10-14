// Local, explicitly paired TLS relay. No account/DRM or microphone access.
#import "PhoneRelayServer.h"
#import <Network/Network.h>
#import <Security/Security.h>
#include "PhoneRelayCore.h"
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>

static GRRing ring;
static GRResampler resampler;
static atomic_bool capturing, playing, producing;
static atomic_uint epoch;
static unsigned producerEpoch;
static atomic_ullong dropped, copied;
static nw_listener_t listener;
static nw_connection_t client;
static dispatch_queue_t relayQueue;
static NSString *serverStatus = @"not_configured", *token, *address;
static NSMutableData *requestBytes;
static unsigned sentChunks, generation;
static unsigned long long skipped, underflow;
static double streamStart, nextSend, lastSend;
static bool authenticated;

void GRObserve(GPFormat format, const GPBuffer *buffers, uint32_t frames) {
    if (!atomic_load_explicit(&capturing, memory_order_acquire) || format.rate < 24000) return;
    if (atomic_exchange_explicit(&producing, true, memory_order_acquire)) {
        atomic_fetch_add(&dropped, 1); return;
    }
    unsigned current = atomic_load_explicit(&epoch, memory_order_acquire);
    if (current != producerEpoch) { resampler = (GRResampler){0}; producerEpoch = current; }
    atomic_fetch_add(&dropped, gr_convert(&ring, &resampler, format, buffers, frames));
    atomic_fetch_add(&copied, frames);
    if (current == atomic_load_explicit(&epoch, memory_order_acquire)) atomic_store(&playing, true);
    atomic_store_explicit(&producing, false, memory_order_release);
}
void GRPause(void) {
    atomic_store(&playing, false);
    atomic_fetch_add(&epoch, 1);
}

static void closeClient(NSString *status) { // relay queue only
    atomic_store(&capturing, false);
    atomic_store(&playing, false);
    atomic_fetch_add(&epoch, 1);
    ++generation;
    if (client) {
        nw_connection_set_state_changed_handler(client, NULL);
        nw_connection_cancel(client); client = nil;
    }
    requestBytes = nil; authenticated = false;
    gr_discard(&ring);
    serverStatus = status;
}

static void sendData(NSData *data, unsigned run, void (^done)(void)) {
    if (!client || generation != run) return;
    dispatch_data_t bytes = dispatch_data_create(data.bytes, data.length, relayQueue, ^{ (void)data; });
    nw_connection_send(client, bytes, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
        if (generation != run) return;
        if (error) { closeClient(@"connection_ended"); return; }
        lastSend = NSProcessInfo.processInfo.systemUptime;
        done();
    });
}

static void checkProgress(unsigned run) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), relayQueue, ^{
        if (generation != run || !client || !authenticated) return;
        double now = NSProcessInfo.processInfo.systemUptime;
        if (now - lastSend > 8) { closeClient(@"network_stalled"); return; }
        if (now - streamStart > 12 * 3600) { closeClient(@"session_limit_reached"); return; }
        checkProgress(run);
    });
}

static void sendChunk(unsigned run) {
    if (generation != run || !client || !authenticated) return;
    double elapsed = NSProcessInfo.processInfo.systemUptime - streamStart;
    if (elapsed > 12 * 3600) { closeClient(@"session_limit_reached"); return; }
    int16_t samples[2400] = {0};
    if (atomic_load(&playing)) {
        skipped += gr_trim(&ring, 7200);
        underflow += 2400 - gr_read(&ring, samples, 2400);
    } else gr_discard(&ring);
    // HTTP chunk boundaries are removed by URLSession before PCM delivery.
    NSMutableData *data = [NSMutableData dataWithBytes:"12c0\r\n" length:6];
    [data appendBytes:samples length:sizeof(samples)];
    [data appendBytes:"\r\n" length:2];
    ++sentChunks;
    sendData(data, run, ^{
        double now = NSProcessInfo.processInfo.systemUptime;
        nextSend = fmax(nextSend + 0.1, now);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((nextSend - now) * NSEC_PER_SEC)),
                       relayQueue, ^{ sendChunk(run); });
    });
}

static void watchDisconnect(unsigned run) {
    nw_connection_receive(client, 1, 1, ^(dispatch_data_t data, nw_content_context_t context, bool complete, nw_error_t error) {
        (void)context;
        if (generation != run) return;
        if (error || complete) { closeClient(@"connection_ended"); return; }
        if (data && dispatch_data_get_size(data)) { closeClient(@"request_rejected"); return; }
        watchDisconnect(run);
    });
}

static bool equalToken(NSString *candidate) {
    NSData *a = [candidate dataUsingEncoding:NSASCIIStringEncoding], *b = [token dataUsingEncoding:NSASCIIStringEncoding];
    if (a.length != 64 || b.length != 64) return false;
    const uint8_t *ap = a.bytes, *bp = b.bytes; uint8_t different = 0;
    for (unsigned i = 0; i < 64; ++i) different |= ap[i] ^ bp[i];
    return different == 0;
}
static bool acceptRequest(NSData *data) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\r\n"];
    if (!text || lines.count < 3 || ![lines[0] isEqualToString:@"GET /glitchify-phone HTTP/1.1"]
        || ![text hasSuffix:@"\r\n\r\n"]) return false;
    NSString *credential = nil;
    for (NSUInteger i = 1; i < lines.count; ++i) {
        NSString *line = lines[i]; NSRange separator = [line rangeOfString:@":"];
        if (!line.length) continue;
        if (separator.location == NSNotFound) return false;
        NSString *name = [[line substringToIndex:separator.location] lowercaseString];
        NSString *value = [[line substringFromIndex:separator.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([name isEqualToString:@"content-length"] || [name isEqualToString:@"transfer-encoding"]) return false;
        if ([name isEqualToString:@"authorization"]) {
            if (credential || ![value hasPrefix:@"Bearer "]) return false;
            credential = [value substringFromIndex:7];
        }
    }
    return equalToken(credential);
}

static void receiveRequest(unsigned run) {
    if (!client || generation != run) return;
    nw_connection_receive(client, 1, 4096, ^(dispatch_data_t data, nw_content_context_t context, bool complete, nw_error_t error) {
        (void)context;
        if (generation != run) return;
        if (error || complete || !data) { closeClient(@"request_ended"); return; }
        bool __block tooLarge = false;
        dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
            (void)region; (void)offset;
            if (size > 4096 - requestBytes.length) { tooLarge = true; return false; }
            [requestBytes appendBytes:bytes length:size]; return true;
        });
        if (tooLarge) { closeClient(@"request_rejected"); return; }
        NSData *end = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        if ([requestBytes rangeOfData:end options:0 range:NSMakeRange(0, requestBytes.length)].location == NSNotFound) {
            receiveRequest(run); return;
        }
        if (!acceptRequest(requestBytes)) { closeClient(@"request_rejected"); return; }
        authenticated = true; requestBytes = nil; sentChunks = 0; skipped = 0; underflow = 0;
        atomic_store(&dropped, 0); atomic_store(&copied, 0); atomic_store(&playing, false);
        atomic_fetch_add(&epoch, 1); gr_discard(&ring);
        atomic_store_explicit(&capturing, true, memory_order_release);
        serverStatus = @"streaming";
        NSData *header = [@"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\nX-Glitchify-Mode: live\r\nX-Glitchify-Format: pcm_s16le_24000_mono\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            dataUsingEncoding:NSASCIIStringEncoding];
        streamStart = NSProcessInfo.processInfo.systemUptime;
        nextSend = lastSend = streamStart;
        watchDisconnect(run);
        checkProgress(run);
        sendData(header, run, ^{ sendChunk(run); });
    });
}

static NSString *wifiAddress(void) {
    struct ifaddrs *all = NULL; NSString *found = @"";
    if (getifaddrs(&all)) return found;
    for (struct ifaddrs *i = all; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || strcmp(i->ifa_name, "en0")
            || !(i->ifa_flags & IFF_UP)) continue;
        char text[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, text, sizeof text)) found = @(text);
    }
    freeifaddrs(all); return found;
}
bool GRStartServer(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSURL *configURL = [bundle URLForResource:@"GlitchifyRelayPairing" withExtension:@"plist"];
    if (!configURL) return false;
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfURL:configURL];
    if (![config[@"enabled"] isEqual:@YES]) return false;
    token = config[@"token"];
    if (![token isKindOfClass:NSString.class] || token.length != 64
        || [token rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) {
        serverStatus = @"invalid_pairing"; return false;
    }
    NSURL *identityURL = [bundle URLForResource:@"GlitchifyRelayIdentity" withExtension:@"p12"];
    NSData *pkcs12 = identityURL ? [NSData dataWithContentsOfURL:identityURL] : nil;
    if (!pkcs12 || ![config[@"password"] isKindOfClass:NSString.class]) { serverStatus = @"identity_missing"; return false; }
    CFArrayRef imported = NULL;
    OSStatus result = SecPKCS12Import((__bridge CFDataRef)pkcs12,
        (__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase: config[@"password"]}, &imported);
    if (result || !imported || CFArrayGetCount(imported) != 1) {
        if (imported) CFRelease(imported); serverStatus = @"identity_rejected"; return false;
    }
    CFDictionaryRef item = CFArrayGetValueAtIndex(imported, 0);
    SecIdentityRef identity = (SecIdentityRef)CFDictionaryGetValue(item, kSecImportItemIdentity);
    sec_identity_t local = identity ? sec_identity_create(identity) : nil;
    CFRelease(imported);
    if (!local) { serverStatus = @"identity_rejected"; return false; }
    relayQueue = dispatch_queue_create("app.glitchify.audio-relay", dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        sec_protocol_options_t security = nw_tls_copy_sec_protocol_options(tls);
        sec_protocol_options_set_local_identity(security, local);
        sec_protocol_options_set_min_tls_protocol_version(security, tls_protocol_version_TLSv12);
    }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_required_interface_type(parameters, nw_interface_type_wifi);
    nw_parameters_set_include_peer_to_peer(parameters, false);
    listener = nw_listener_create_with_port("8766", parameters);
    if (!listener) { serverStatus = @"listener_failed"; return false; }
    nw_listener_set_queue(listener, relayQueue);
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        (void)error;
        if (state == nw_listener_state_ready) { serverStatus = @"ready"; address = wifiAddress(); }
        if (state == nw_listener_state_failed) { closeClient(@"listener_failed"); nw_listener_cancel(listener); }
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t incoming) {
        if (client) { nw_connection_cancel(incoming); return; }
        client = incoming; unsigned run = ++generation; requestBytes = [NSMutableData data];
        authenticated = false;
        nw_connection_set_queue(incoming, relayQueue);
        nw_connection_set_state_changed_handler(incoming, ^(nw_connection_state_t state, nw_error_t error) {
            (void)error;
            if (run != generation) return;
            if (state == nw_connection_state_ready) receiveRequest(run);
            if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) closeClient(@"connection_ended");
        });
        nw_connection_start(incoming);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), relayQueue, ^{
            if (run == generation && !authenticated) closeClient(@"authentication_timeout");
        });
    });
    serverStatus = @"starting"; nw_listener_start(listener);
    return true;
}
NSDictionary *GRStatus(void) {
    __block NSDictionary *result;
    void (^read)(void) = ^{
        result = @{@"state": serverStatus, @"host": address ?: @"", @"chunks": @(sentChunks),
            @"frames": @(atomic_load(&copied)), @"dropped": @(atomic_load(&dropped)),
            @"skipped": @(skipped), @"underflow": @(underflow),
            @"capturing": @(atomic_load(&capturing)), @"playing": @(atomic_load(&playing))};
    };
    if (relayQueue) dispatch_sync(relayQueue, read); else read();
    return result;
}
