// Opt-in diagnostic for the audited Glitchify phone image. It measures existing
// output buffers for three minutes; no audio is retained, sent, or modified.
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include "PhonePCMCore.h"
#if GLITCHIFY_RELAY
#import "PhoneRelayServer.h"
#endif

// The iPhone SDK deliberately omits mach_vm.h. This is the same region-query
// ABI used by the existing image-local compatibility bridge, not a memory write.
extern kern_return_t mach_vm_region(vm_map_t, mach_vm_address_t *, mach_vm_size_t *,
    vm_region_flavor_t, vm_region_info_t, mach_msg_type_number_t *, mach_port_t *);

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Render counters must be lock free");
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "Render flags must be lock free");
typedef OSStatus (*UnitCall)(AudioUnit);
static UnitCall previousStart, previousStop, previousDispose;
static atomic_bool enabled;
static atomic_ullong startCalls, stopCalls, disposeCalls, rejectedUnits, listenerErrors;
static pthread_mutex_t control = PTHREAD_MUTEX_INITIALIZER;
static NSString *installStatus = @"not_started";
static unsigned writeCount;

typedef struct {
    AudioUnit unit; // immutable after publication, never reused or freed
    GPFormat format;
    atomic_bool active, invalid, disposed, processing;
    atomic_ullong callbacks, frames, nonzero, rejected, concurrent, silent, latestPeak;
    bool listenerAdded, propertyAdded; // control mutex only
} Context;
static Context contexts[16];
static unsigned used;

static OSStatus observe(void *refcon, AudioUnitRenderActionFlags *flags,
                        const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                        AudioBufferList *data) {
    (void)time;
    Context *ctx = refcon;
    if (!atomic_load_explicit(&enabled, memory_order_relaxed)
        || !atomic_load_explicit(&ctx->active, memory_order_acquire)
        || atomic_load_explicit(&ctx->invalid, memory_order_relaxed)
        || !flags || !(*flags & kAudioUnitRenderAction_PostRender) || bus != 0) return noErr;
    atomic_fetch_add_explicit(&ctx->callbacks, 1, memory_order_relaxed);
    if (*flags & kAudioUnitRenderAction_PostRenderError || !data || data->mNumberBuffers > 2) {
        atomic_fetch_add_explicit(&ctx->rejected, 1, memory_order_relaxed); return noErr;
    }
    if (*flags & kAudioUnitRenderAction_OutputIsSilence) {
        atomic_fetch_add_explicit(&ctx->silent, 1, memory_order_relaxed); return noErr;
    }
    // Never wait for another render callback. Disable this context on concurrency.
    if (atomic_exchange_explicit(&ctx->processing, true, memory_order_acquire)) {
        atomic_store_explicit(&ctx->invalid, true, memory_order_release);
        atomic_fetch_add_explicit(&ctx->concurrent, 1, memory_order_relaxed); return noErr;
    }
    GPBuffer buffers[2] = {0};
    for (UInt32 i = 0; i < data->mNumberBuffers; ++i)
        buffers[i] = (GPBuffer){data->mBuffers[i].mData, data->mBuffers[i].mDataByteSize,
                               data->mBuffers[i].mNumberChannels};
    uint32_t peak = 0;
    bool valid = gp_measure(ctx->format, buffers, data->mNumberBuffers, frames, &peak);
    if (valid) {
        atomic_fetch_add_explicit(&ctx->frames, frames, memory_order_relaxed);
        if (peak) atomic_fetch_add_explicit(&ctx->nonzero, 1, memory_order_relaxed);
        atomic_store_explicit(&ctx->latestPeak, peak, memory_order_relaxed);
#if GLITCHIFY_RELAY
        GRObserve(ctx->format, buffers, frames);
#endif
    } else atomic_fetch_add_explicit(&ctx->rejected, 1, memory_order_relaxed);
    atomic_store_explicit(&ctx->processing, false, memory_order_release);
    return noErr; // Existing renderer and other listeners keep their result/buffers.
}

static void formatChanged(void *refcon, AudioUnit unit, AudioUnitPropertyID property,
                          AudioUnitScope scope, AudioUnitElement element) {
    (void)unit; (void)scope; (void)element;
    if (property == kAudioUnitProperty_StreamFormat) {
        atomic_store_explicit(&((Context *)refcon)->invalid, true, memory_order_release);
#if GLITCHIFY_RELAY
        GRPause();
#endif
    }
}

static bool readFormat(AudioUnit unit, GPFormat *out) {
    AudioComponent component = AudioComponentInstanceGetComponent(unit);
    AudioComponentDescription desc = {0};
    if (!component || AudioComponentGetDescription(component, &desc)
        || desc.componentType != kAudioUnitType_Output || desc.componentSubType != kAudioUnitSubType_RemoteIO) return false;
    AudioStreamBasicDescription f = {0}; UInt32 size = sizeof(f);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, &size)
        || size != sizeof(f) || f.mFormatID != kAudioFormatLinearPCM || f.mFramesPerPacket != 1
        || f.mBytesPerPacket != f.mBytesPerFrame) return false;
    UInt32 allowed = kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger
        | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    if ((f.mFormatFlags & ~allowed) || !(f.mFormatFlags & kAudioFormatFlagIsPacked)
        || (!!(f.mFormatFlags & kAudioFormatFlagIsFloat) == !!(f.mFormatFlags & kAudioFormatFlagIsSignedInteger))) return false;
    *out = (GPFormat){f.mSampleRate, f.mChannelsPerFrame, f.mBitsPerChannel, f.mBytesPerFrame,
        !!(f.mFormatFlags & kAudioFormatFlagIsFloat), !!(f.mFormatFlags & kAudioFormatFlagIsNonInterleaved)};
    return gp_valid_format(*out);
}

static void detach(Context *ctx) { // serialized with unit disposal
    atomic_store_explicit(&ctx->active, false, memory_order_release);
    if (ctx->listenerAdded) {
        if (AudioUnitRemoveRenderNotify(ctx->unit, observe, ctx)) atomic_fetch_add(&listenerErrors, 1);
        ctx->listenerAdded = false;
    }
    if (ctx->propertyAdded) {
        if (AudioUnitRemovePropertyListenerWithUserData(ctx->unit, kAudioUnitProperty_StreamFormat, formatChanged, ctx))
            atomic_fetch_add(&listenerErrors, 1);
        ctx->propertyAdded = false;
    }
}

static Context *attach(AudioUnit unit) {
    GPFormat f;
    if (!readFormat(unit, &f)) { atomic_fetch_add(&rejectedUnits, 1); return NULL; }
    for (unsigned i = 0; i < used; ++i) {
        Context *ctx = &contexts[i];
        if (ctx->unit != unit || atomic_load(&ctx->disposed)) continue;
        if (!atomic_load(&ctx->invalid) && ctx->listenerAdded
            && ctx->format.rate == f.rate && ctx->format.channels == f.channels
            && ctx->format.bits == f.bits && ctx->format.planar == f.planar
            && ctx->format.floating == f.floating && ctx->format.bytesPerFrame == f.bytesPerFrame) {
            atomic_store_explicit(&ctx->active, true, memory_order_release); return ctx;
        }
        atomic_store(&ctx->invalid, true);
        detach(ctx);
    }
    if (used == 16) { atomic_fetch_add(&rejectedUnits, 1); return NULL; }
    Context *ctx = &contexts[used++];
    ctx->unit = unit; ctx->format = f;
    if (AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat, formatChanged, ctx)) {
        atomic_store(&ctx->invalid, true); atomic_fetch_add(&listenerErrors, 1); return NULL;
    }
    ctx->propertyAdded = true;
    if (AudioUnitAddRenderNotify(unit, observe, ctx)) {
        atomic_store(&ctx->invalid, true); atomic_fetch_add(&listenerErrors, 1); detach(ctx); return NULL;
    }
    ctx->listenerAdded = true;
    atomic_store_explicit(&ctx->active, true, memory_order_release);
    return ctx;
}

static OSStatus startUnit(AudioUnit unit) {
    atomic_fetch_add(&startCalls, 1);
    Context *ctx = NULL;
    if (atomic_load(&enabled)) {
        pthread_mutex_lock(&control); ctx = attach(unit); pthread_mutex_unlock(&control);
    }
    OSStatus result = previousStart(unit); // Chroma's existing wrapper, exactly once
    if (result && ctx) atomic_store_explicit(&ctx->active, false, memory_order_release);
    return result;
}
static OSStatus stopUnit(AudioUnit unit) {
#if GLITCHIFY_RELAY
    GRPause();
#endif
    atomic_fetch_add(&stopCalls, 1);
    pthread_mutex_lock(&control);
    for (unsigned i = 0; i < used; ++i) if (contexts[i].unit == unit)
        atomic_store_explicit(&contexts[i].active, false, memory_order_release);
    pthread_mutex_unlock(&control);
    return previousStop(unit);
}
static OSStatus disposeUnit(AudioUnit unit) {
#if GLITCHIFY_RELAY
    GRPause();
#endif
    atomic_fetch_add(&disposeCalls, 1);
    pthread_mutex_lock(&control);
    for (unsigned i = 0; i < used; ++i) if (contexts[i].unit == unit && !atomic_load(&contexts[i].disposed)) {
        detach(&contexts[i]); atomic_store(&contexts[i].disposed, true);
    }
    pthread_mutex_unlock(&control);
    return previousDispose(unit);
}

static const unsigned char mainUUID[16] = {0x8f,0xb9,0x25,0x98,0xf5,0x6c,0x3f,0x90,0xb9,0x99,0x3a,0xfd,0x76,0xed,0xe8,0x09};
static const unsigned char chromaUUID[16] = {0xd4,0xc7,0x5c,0x03,0xb9,0x0b,0x32,0x9d,0x83,0xb9,0x60,0xd7,0x68,0xcc,0x43,0xaa};
static bool boundedEqual(const char *text, size_t limit, const char *expected) {
    size_t length = strlen(expected);
    return length < limit && !memcmp(text, expected, length + 1);
}
static bool rangeInFile(const struct segment_command_64 *s, uint64_t offset, uint64_t size) {
    return offset >= s->fileoff && size <= s->filesize && offset - s->fileoff <= s->filesize - size;
}

// Resolve one pinned main-image import through its indirect symbol entry. UUID
// and address alone are insufficient; section, bounds and exact name must agree.
static uintptr_t *findSlot(const struct mach_header_64 *h, intptr_t slide, uint64_t address, const char *name) {
    if (!h || h->magic != MH_MAGIC_64 || h->cputype != CPU_TYPE_ARM64 || h->cpusubtype != 0
        || h->filetype != MH_EXECUTE || h->ncmds > 256 || h->sizeofcmds > 65536) return NULL;
    const uint8_t *at = (const uint8_t *)(h + 1), *end = at + h->sizeofcmds;
    const struct segment_command_64 *link = NULL, *data = NULL;
    const struct section_64 *got = NULL;
    const struct symtab_command *sym = NULL;
    const struct dysymtab_command *dyn = NULL;
    bool uuidOK = false;
    for (uint32_t i = 0; i < h->ncmds; ++i) {
        if (end - at < 8) return NULL;
        const struct load_command *cmd = (const void *)at;
        if (cmd->cmdsize < 8 || cmd->cmdsize % 8 || cmd->cmdsize > end - at) return NULL;
        if (cmd->cmd == LC_UUID && cmd->cmdsize == sizeof(struct uuid_command))
            uuidOK = !memcmp(((const struct uuid_command *)cmd)->uuid, mainUUID, 16);
        if (cmd->cmd == LC_SYMTAB && cmd->cmdsize == sizeof(*sym)) sym = (const void *)cmd;
        if (cmd->cmd == LC_DYSYMTAB && cmd->cmdsize == sizeof(*dyn)) dyn = (const void *)cmd;
        if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *s = (const void *)cmd;
            if (s->nsects > (cmd->cmdsize - sizeof(*s)) / sizeof(struct section_64)) return NULL;
            if (boundedEqual(s->segname, 16, "__LINKEDIT")) link = s;
            if (boundedEqual(s->segname, 16, "__DATA_CONST")) {
                data = s;
                const struct section_64 *sections = (const void *)(s + 1);
                for (uint32_t j = 0; j < s->nsects; ++j)
                    if (boundedEqual(sections[j].sectname, 16, "__got")
                        && (sections[j].flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) got = &sections[j];
            }
        }
        at += cmd->cmdsize;
    }
    if (at != end || !uuidOK || !link || !data || !got || !sym || !dyn
        || got->size < 8 || got->size % 8 || address < got->addr || address - got->addr > got->size - 8
        || (address - got->addr) % 8 || got->addr < data->vmaddr || got->size > data->vmsize
        || got->addr - data->vmaddr > data->vmsize - got->size) return NULL;
    uint64_t index = (address - got->addr) / 8 + got->reserved1;
    if (index >= dyn->nindirectsyms || !rangeInFile(link, dyn->indirectsymoff, (uint64_t)dyn->nindirectsyms * 4)
        || !rangeInFile(link, sym->symoff, (uint64_t)sym->nsyms * sizeof(struct nlist_64))
        || !rangeInFile(link, sym->stroff, sym->strsize)) return NULL;
    uintptr_t base = slide + link->vmaddr - link->fileoff;
    uint32_t si = ((const uint32_t *)(base + dyn->indirectsymoff))[index];
    if (si & 0xc0000000 || si >= sym->nsyms) return NULL;
    uint32_t str = ((const struct nlist_64 *)(base + sym->symoff))[si].n_un.n_strx;
    if (str >= sym->strsize || !boundedEqual((const char *)(base + sym->stroff + str), sym->strsize - str, name)) return NULL;
    return (uintptr_t *)(slide + address);
}

static uintptr_t chromaBase(void) {
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const struct mach_header_64 *h = (const void *)_dyld_get_image_header(index);
        if (!h || h->magic != MH_MAGIC_64 || h->filetype != MH_DYLIB || h->cputype != CPU_TYPE_ARM64
            || h->ncmds > 256 || h->sizeofcmds > 65536) continue;
        const uint8_t *at = (const uint8_t *)(h + 1), *end = at + h->sizeofcmds;
        bool uuidOK = false, rangeOK = false, commandsOK = true;
        for (uint32_t i = 0; i < h->ncmds; ++i) {
            if (end - at < 8) { commandsOK = false; break; }
            const struct load_command *cmd = (const void *)at;
            if (cmd->cmdsize < 8 || cmd->cmdsize % 8 || cmd->cmdsize > end - at) { commandsOK = false; break; }
            if (cmd->cmd == LC_UUID && cmd->cmdsize == sizeof(struct uuid_command))
                uuidOK = !memcmp(((const struct uuid_command *)cmd)->uuid, chromaUUID, 16);
            if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *s = (const void *)cmd;
                if (boundedEqual(s->segname, 16, "__TEXT") && s->vmaddr == 0 && s->vmsize >= 0x15b738
                    && (s->initprot & VM_PROT_EXECUTE)) rangeOK = true;
            }
            at += cmd->cmdsize;
        }
        if (!commandsOK || at != end || !uuidOK || !rangeOK) continue;
        uintptr_t base = _dyld_get_image_vmaddr_slide(index);
        const uint8_t fingerprint[16] = {0xf6,0x57,0xbd,0xa9,0xf4,0x4f,0x01,0xa9,0xfd,0x7b,0x02,0xa9,0xfd,0x83,0x00,0x91};
        if (!memcmp((const void *)(base + 0x15b560), fingerprint, 16)) return base;
    }
    return 0;
}

static bool install(void) {
    const struct mach_header_64 *main = (const void *)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    uintptr_t *slots[] = {
        findSlot(main, slide, 0x1090636f0, "_AudioOutputUnitStart"),
        findSlot(main, slide, 0x1090636f8, "_AudioOutputUnitStop"),
        findSlot(main, slide, 0x109063688, "_AudioComponentInstanceDispose")};
    uintptr_t chroma = chromaBase();
    if (!chroma || !slots[0] || !slots[1] || !slots[2]) { installStatus = @"image_validation_failed"; return false; }
    uintptr_t prior[3];
    for (unsigned i = 0; i < 3; ++i) prior[i] = __atomic_load_n(slots[i], __ATOMIC_ACQUIRE);
    if (prior[0] != chroma + 0x15b560 || prior[2] != chroma + 0x15b728
        || !prior[1] || prior[1] != (uintptr_t)dlsym(RTLD_DEFAULT, "AudioOutputUnitStop")) {
        installStatus = @"existing_audio_chain_not_ready"; return false;
    }
    mach_vm_address_t begin = (uintptr_t)slots[2], region = begin;
    mach_vm_size_t size = 0, span = (uintptr_t)slots[1] + 8 - begin;
    vm_region_basic_info_data_64_t info = {0}; mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = mach_vm_region(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object);
    if (object) mach_port_deallocate(mach_task_self(), object);
    if (result || region > begin || size < span || begin - region > size - span
        || !(info.protection & VM_PROT_READ) || (info.protection & VM_PROT_EXECUTE)) {
        installStatus = @"import_mapping_rejected"; return false;
    }
    if (vm_protect(mach_task_self(), begin, span, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)) {
        installStatus = @"import_write_denied"; return false;
    }
    previousStart = (UnitCall)prior[0]; previousStop = (UnitCall)prior[1]; previousDispose = (UnitCall)prior[2];
    uintptr_t replacements[] = {(uintptr_t)startUnit, (uintptr_t)stopUnit, (uintptr_t)disposeUnit};
    for (unsigned i = 0; i < 3; ++i) __atomic_store_n(slots[i], replacements[i], __ATOMIC_RELEASE);
    if (vm_protect(mach_task_self(), begin, span, false, info.protection)) {
        for (unsigned i = 0; i < 3; ++i) __atomic_store_n(slots[i], prior[i], __ATOMIC_RELEASE);
        vm_protect(mach_task_self(), begin, span, false, info.protection);
        installStatus = @"import_restore_failed"; return false;
    }
    installStatus = @"installed_preserving_chroma_chain";
    atomic_store(&enabled, true);
    return true;
}

static void writeSnapshot(void) {
    NSMutableArray *units = [NSMutableArray array];
    pthread_mutex_lock(&control);
    for (unsigned i = 0; i < used; ++i) {
        Context *ctx = &contexts[i];
        [units addObject:@{@"index": @(i), @"rate": @(ctx->format.rate), @"channels": @(ctx->format.channels),
            @"bits": @(ctx->format.bits), @"float": @(ctx->format.floating), @"planar": @(ctx->format.planar),
            @"active": @(atomic_load(&ctx->active)), @"invalid": @(atomic_load(&ctx->invalid)),
            @"disposed": @(atomic_load(&ctx->disposed)), @"callbacks": @(atomic_load(&ctx->callbacks)),
            @"frames": @(atomic_load(&ctx->frames)), @"nonzero_buffers": @(atomic_load(&ctx->nonzero)),
            @"rejected_buffers": @(atomic_load(&ctx->rejected)), @"concurrent_callbacks": @(atomic_load(&ctx->concurrent)),
            @"silent_buffers": @(atomic_load(&ctx->silent)), @"latest_peak_millionths": @(atomic_load(&ctx->latestPeak))}];
    }
    pthread_mutex_unlock(&control);
    NSMutableDictionary *snapshot = [@{@"revision": @"1.1-phone-pcm-probe.1", @"status": installStatus,
        @"enabled": @(atomic_load(&enabled)), @"sample": @(writeCount),
        @"start_calls": @(atomic_load(&startCalls)), @"stop_calls": @(atomic_load(&stopCalls)),
        @"dispose_calls": @(atomic_load(&disposeCalls)), @"rejected_units": @(atomic_load(&rejectedUnits)),
        @"listener_errors": @(atomic_load(&listenerErrors)), @"units": units,
        @"audio_saved": @NO, @"audio_transmitted": @NO} mutableCopy];
#if GLITCHIFY_RELAY
    snapshot[@"relay"] = GRStatus();
    snapshot[@"audio_transmitted"] = @([snapshot[@"relay"][@"chunks"] unsignedIntValue] > 0);
#endif
    NSURL *cache = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    if (cache) [snapshot writeToURL:[cache URLByAppendingPathComponent:@"GlitchifyPhonePCMProbe.plist"] atomically:YES];
}
static void tick(void) {
    if (++writeCount >= 180) atomic_store(&enabled, false);
    writeSnapshot();
    if (writeCount < 180) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ tick(); });
}
__attribute__((constructor)) static void loaded(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"GlitchifyPhonePCMProbe"] boolValue]) return;
        bool ready = install();
#if GLITCHIFY_RELAY
        if (ready) GRStartServer();
#else
        (void)ready;
#endif
        tick();
    });
}
