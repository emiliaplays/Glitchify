// Paired, Wi-Fi-only control of this phone process, separate from the audio socket.
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import "PhoneRelayControl.h"
#include "PhoneControlProtocol.h"
#include <dlfcn.h>
#include <unistd.h>
#include <math.h>

typedef void (*GCGetPID)(dispatch_queue_t, void (^)(int));
typedef Boolean (*GCSend)(int, CFDictionaryRef);
static GCGetPID getPlayingPID;
static GCSend sendCommand;
static nw_listener_t controlListener;
static dispatch_queue_t controlQueue;
static NSString *controlToken;
static unsigned activeConnections;
static double lastCommand;

@interface GCConnection : NSObject
@property(nonatomic, strong) nw_connection_t connection;
@property(nonatomic, strong) NSMutableData *request;
@property(nonatomic) BOOL finished, responding;
- (void)close;
- (void)receive;
- (void)respond:(NSDictionary *)body code:(unsigned)code;
@end

static NSString *boundedText(id value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    return [value substringToIndex:MIN([value length], 256)];
}
static double finiteNumber(id value) {
    double number = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
    return isfinite(number) ? fmax(0, number) : 0;
}

@implementation GCConnection
- (void)close {
    if (self.finished) return;
    self.finished = YES;
    nw_connection_set_state_changed_handler(self.connection, NULL);
    nw_connection_cancel(self.connection);
    if (activeConnections) --activeConnections;
    self.request = nil;
}
- (void)respond:(NSDictionary *)body code:(unsigned)code {
    if (self.finished || self.responding) return;
    self.responding = YES;
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    if (!json || json.length > 8192) { [self close]; return; }
    NSMutableData *data = [[[NSString stringWithFormat:@"HTTP/1.1 %u Result\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", code, (unsigned long)json.length] dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [data appendData:json];
    dispatch_data_t bytes = dispatch_data_create(data.bytes, data.length, controlQueue, ^{ (void)data; });
    nw_connection_send(self.connection, bytes, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        (void)error; [self close];
    });
}
- (void)handle:(GCRequest)action {
    if (!getPlayingPID || !sendCommand) { [self respond:@{@"error": @"control_unavailable"} code:503]; return; }
    // Do not send a global media command when a different app owns Now Playing.
    getPlayingPID(controlQueue, ^(int pid) {
        if (self.finished) return;
        if (pid != getpid()) { [self respond:@{@"error": @"open_glitchify_on_phone"} code:409]; return; }
        double now = NSProcessInfo.processInfo.systemUptime;
        if (action != GCStatus && now - lastCommand < 0.3) {
            [self respond:@{@"error": @"wait_before_next_command"} code:429]; return;
        }
        if (action != GCStatus) lastCommand = now;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (action == GCStatus) {
                NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo ?: @{};
                NSDictionary *result = @{@"title": boundedText(info[MPMediaItemPropertyTitle]),
                    @"artist": boundedText(info[MPMediaItemPropertyArtist]),
                    @"duration": @(finiteNumber(info[MPMediaItemPropertyPlaybackDuration])),
                    @"elapsed": @(finiteNumber(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])),
                    @"playing": @([info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue] > 0),
                    @"controls": @YES};
                dispatch_async(controlQueue, ^{ [self respond:result code:200]; });
            } else {
                // MediaRemote command values: play=0, pause=1, next=4, previous=5.
                int command = action == GCPlay ? 0 : action == GCPause ? 1 : action == GCNext ? 4 : 5;
                Boolean accepted = sendCommand(command, NULL);
                dispatch_async(controlQueue, ^{
                    [self respond:accepted ? @{@"accepted": @YES} : @{@"error": @"command_unavailable"} code:accepted ? 202 : 503];
                });
            }
        });
    });
}
- (void)receive {
    if (self.finished || self.responding) return;
    nw_connection_receive(self.connection, 1, 4096, ^(dispatch_data_t data, nw_content_context_t context, bool complete, nw_error_t error) {
        (void)context;
        if (self.finished) return;
        if (error || complete || !data) { [self close]; return; }
        __block bool tooLarge = false;
        dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
            (void)region; (void)offset;
            if (size > 4096 - self.request.length) { tooLarge = true; return false; }
            [self.request appendBytes:bytes length:size]; return true;
        });
        if (tooLarge) { [self close]; return; }
        NSData *end = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        if ([self.request rangeOfData:end options:0 range:NSMakeRange(0,self.request.length)].location == NSNotFound) {
            [self receive]; return;
        }
        GCRequest action = gc_request(self.request.bytes, self.request.length, controlToken.UTF8String);
        if (!action) { [self respond:@{@"error": @"request_rejected"} code:403]; return; }
        [self handle:action];
    });
}
@end

void GCStart(sec_identity_t identity, NSString *token) {
    if (controlListener) return;
    controlToken = [token copy];
    void *media = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
    if (media) {
        getPlayingPID = (GCGetPID)dlsym(media, "MRMediaRemoteGetNowPlayingApplicationPID");
        sendCommand = (GCSend)dlsym(media, "MRMediaRemoteSendCommand");
    }
    controlQueue = dispatch_queue_create("app.glitchify.control", DISPATCH_QUEUE_SERIAL);
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        sec_protocol_options_t security = nw_tls_copy_sec_protocol_options(tls);
        sec_protocol_options_set_local_identity(security, identity);
        sec_protocol_options_set_min_tls_protocol_version(security, tls_protocol_version_TLSv12);
    }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_required_interface_type(parameters, nw_interface_type_wifi);
    nw_parameters_set_include_peer_to_peer(parameters, false);
    controlListener = nw_listener_create_with_port("8767", parameters);
    if (!controlListener) return;
    nw_listener_set_queue(controlListener, controlQueue);
    nw_listener_set_new_connection_handler(controlListener, ^(nw_connection_t incoming) {
        if (activeConnections >= 4) { nw_connection_cancel(incoming); return; }
        ++activeConnections;
        GCConnection *session = [GCConnection new]; session.connection = incoming; session.request = [NSMutableData data];
        nw_connection_set_queue(incoming, controlQueue);
        nw_connection_set_state_changed_handler(incoming, ^(nw_connection_state_t state, nw_error_t error) {
            (void)error;
            if (state == nw_connection_state_ready) [session receive];
            if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) [session close];
        });
        nw_connection_start(incoming);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), controlQueue, ^{ [session close]; });
    });
    nw_listener_start(controlListener);
}
