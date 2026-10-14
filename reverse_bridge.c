/* Image-local compatibility aliases for the audited Chroma 0.51.0 beta image.
 * Original code: no fishhook source is incorporated. No UI, preferences,
 * entitlement, network-response, license, or code-section changes.
 */
typedef unsigned char U8;
typedef unsigned int U32;
typedef unsigned long long U64;
typedef unsigned long UPtr;
typedef long IPtr;
typedef void *Obj;
typedef Obj (*Lookup)(const char *);

#ifndef REVERSE_ENABLE_TRACK_ALIAS
#define REVERSE_ENABLE_TRACK_ALIAS 1
#endif

typedef struct { U32 magic,cpu,subtype,filetype,ncmds,sizeofcmds,flags,reserved; } Header;
typedef struct { U32 cmd,size; } Command;
typedef struct {
    U32 cmd,size; char name[16]; U64 vmaddr,vmsize,fileoff,filesize;
    int maxprot,initprot; U32 nsects,flags;
} Segment;
typedef struct {
    char name[16],segment[16]; U64 addr,size; U32 offset,align,reloff,nreloc,flags,reserved1,reserved2,reserved3;
} Section;
typedef struct { U32 cmd,size,symoff,nsyms,stroff,strsize; } Symbols;
typedef struct { U32 cmd,size; U32 fields[18]; } DynamicSymbols;
typedef struct { U32 strx; U8 type,sect; unsigned short desc; U64 value; } Symbol;

_Static_assert(sizeof(Header)==32,"Mach-O header ABI");
_Static_assert(sizeof(Segment)==72,"Mach-O segment ABI");
_Static_assert(sizeof(Section)==80,"Mach-O section ABI");
_Static_assert(sizeof(Symbol)==16,"Mach-O symbol ABI");

extern Obj objc_getClass(const char *);
extern Obj sel_registerName(const char *);
extern Obj objc_msgSend(Obj,Obj);
extern void NSLog(Obj,...);
extern void _dyld_register_func_for_add_image(void (*)(const Header *,IPtr));
extern U32 mach_task_self_;
extern int mach_vm_region(U32,U64 *,U64 *,int,int *,U32 *,U32 *);
extern int vm_protect(U32,UPtr,UPtr,int,int);
extern int mach_port_deallocate(U32,U32);

static const U8 target_uuid[16]={0xd4,0xc7,0x5c,0x03,0xb9,0x0b,0x32,0x9d,0x83,0xb9,0x60,0xd7,0x68,0xcc,0x43,0xaa};
static const char target_id[]="/Library/MobileSubstrate/DynamicLibraries/spotifyglass.dylib";
static const U64 target_slot=0x4c9558;
static Lookup original_lookup=objc_getClass;
static U32 installed,state_logged,state_missing;
#if REVERSE_ENABLE_TRACK_ALIAS
static U32 track_logged,track_missing;
#endif

static int same(const char *a,const char *b) {
    if (!a || !b) return 0;
    while (*a && *a==*b) { ++a;++b; }
    return *a==*b;
}
static int bounded_same(const char *a,UPtr length,const char *b) {
    for (UPtr i=0;i<length;++i) {
        if (a[i]!=b[i]) return 0;
        if (!a[i]) return 1;
    }
    return 0;
}
static void note(const char *message) {
#ifdef REVERSE_BRIDGE_TEST
    extern void reverse_test_log(const char *);
    reverse_test_log(message);
#else
    Obj string=((Obj(*)(Obj,Obj,const char *))objc_msgSend)(objc_getClass("NSString"),sel_registerName("stringWithUTF8String:"),message);
    if (string) NSLog(string);
#endif
}
static Obj compatible_lookup(const char *name) {
    Lookup original=__atomic_load_n(&original_lookup,__ATOMIC_ACQUIRE);
    Obj result=original(name);
    if (result) return result;
    if (same(name,"SPTPlayerState")) {
        result=original("SPTPlayerStateImplementation");
        if (result) {
            if (!__atomic_exchange_n(&state_logged,1,__ATOMIC_RELAXED)) note("[GlitchifyReverseBridge] state alias used");
        } else if (!__atomic_exchange_n(&state_missing,1,__ATOMIC_RELAXED)) note("[GlitchifyReverseBridge] state fallback class unavailable");
    }
#if REVERSE_ENABLE_TRACK_ALIAS
    else if (same(name,"SPTPlayerTrack")) {
        result=original("SPTPlayerTrackImplementation");
        if (result) {
            if (!__atomic_exchange_n(&track_logged,1,__ATOMIC_RELAXED)) note("[GlitchifyReverseBridge] track alias used");
        } else if (!__atomic_exchange_n(&track_missing,1,__ATOMIC_RELAXED)) note("[GlitchifyReverseBridge] track fallback class unavailable");
    }
#endif
    return result;
}
static int file_range(const Segment *segment,U64 offset,U64 length) {
    return offset>=segment->fileoff && length<=segment->filesize && offset-segment->fileoff<=segment->filesize-length;
}
static Lookup *find_slot(const Header *header,IPtr slide) {
    if (!header || header->magic!=0xfeedfacf || header->cpu!=0x100000c || header->subtype!=0 || header->filetype!=6) return 0;
    if (header->ncmds>256 || header->sizeofcmds>65536) return 0;
    const U8 *begin=(const U8 *)header+32,*end=begin+header->sizeofcmds,*at=begin;
    const Segment *linkedit=0,*data=0;
    const Section *got=0;
    const Symbols *symbols=0;
    const DynamicSymbols *dynamic=0;
    int uuid_ok=0,id_ok=0;
    for (U32 i=0;i<header->ncmds;++i) {
        if ((UPtr)(end-at)<8) return 0;
        const Command *command=(const Command *)at;
        if (command->size<8 || command->size%8 || command->size>(UPtr)(end-at)) return 0;
        if (command->cmd==0x1b && command->size==24) {
            uuid_ok=1;
            for (U32 j=0;j<16;++j) if (at[8+j]!=target_uuid[j]) uuid_ok=0;
        } else if (command->cmd==0xd && command->size>=24) {
            U32 offset=*(const U32 *)(at+8);
            if (offset>=24 && offset<command->size) id_ok=bounded_same((const char *)at+offset,command->size-offset,target_id);
        } else if (command->cmd==0x2 && command->size==24) symbols=(const Symbols *)at;
        else if (command->cmd==0xb && command->size==80) dynamic=(const DynamicSymbols *)at;
        else if (command->cmd==0x19 && command->size>=72) {
            const Segment *segment=(const Segment *)at;
            if (segment->nsects>(command->size-72)/80) return 0;
            if (bounded_same(segment->name,16,"__LINKEDIT")) linkedit=segment;
            if (bounded_same(segment->name,16,"__DATA_CONST")) {
                data=segment;
                const Section *sections=(const Section *)(at+72);
                for (U32 j=0;j<segment->nsects;++j) {
                    if (bounded_same(sections[j].name,16,"__got") && (sections[j].flags&255)==6) got=&sections[j];
                }
            }
        }
        at+=command->size;
    }
    if (at!=end || !uuid_ok || !id_ok || !symbols || !dynamic || !linkedit || !data || !got) return 0;
    if (got->size<8 || got->size%8 || target_slot<got->addr || target_slot-got->addr>got->size-8 || (target_slot-got->addr)%8) return 0;
    if (got->addr<data->vmaddr || got->size>data->vmsize || got->addr-data->vmaddr>data->vmsize-got->size) return 0;
    U64 index=(target_slot-got->addr)/8+got->reserved1;
    U32 indirect_offset=dynamic->fields[12],indirect_count=dynamic->fields[13];
    if (index>=indirect_count || !file_range(linkedit,indirect_offset,(U64)indirect_count*4)) return 0;
    if (!file_range(linkedit,symbols->symoff,(U64)symbols->nsyms*16) || !file_range(linkedit,symbols->stroff,symbols->strsize)) return 0;
    UPtr base=(UPtr)slide+(UPtr)linkedit->vmaddr-(UPtr)linkedit->fileoff;
    U32 symbol_index=((const U32 *)(base+indirect_offset))[index];
    if ((symbol_index&0xc0000000) || symbol_index>=symbols->nsyms) return 0;
    const Symbol *symbol=(const Symbol *)(base+symbols->symoff)+symbol_index;
    if (symbol->strx>=symbols->strsize || !bounded_same((const char *)(base+symbols->stroff+symbol->strx),symbols->strsize-symbol->strx,"_objc_getClass")) return 0;
    return (Lookup *)((UPtr)slide+(UPtr)target_slot);
}
static void image_added(const Header *header,IPtr slide) {
    if (__atomic_load_n(&installed,__ATOMIC_ACQUIRE)) return;
    Lookup *slot=find_slot(header,slide);
    if (!slot) return;
    Lookup previous=__atomic_load_n(slot,__ATOMIC_ACQUIRE);
    if (!previous || previous==compatible_lookup) return;
    U64 address=(UPtr)slot,size=0;
    int info[16]={0}; U32 count=16,object=0;
    int status=mach_vm_region(mach_task_self_,&address,&size,9,info,&count,&object);
    if (object) mach_port_deallocate(mach_task_self_,object);
    if (status || count<2 || address>(UPtr)slot || size<8 || (UPtr)slot-address>size-8 || !(info[0]&1) || (info[0]&4)) {
        note("[GlitchifyReverseBridge] skipped: GOT mapping validation failed");return;
    }
    /* Request a private writable DATA page, never executable memory. */
    if (vm_protect(mach_task_self_,(UPtr)slot,8,0,1|2|16)) {
        note("[GlitchifyReverseBridge] skipped: GOT write permission denied");return;
    }
    __atomic_store_n(&original_lookup,previous,__ATOMIC_RELEASE);
    __atomic_store_n(slot,compatible_lookup,__ATOMIC_RELEASE);
    if (vm_protect(mach_task_self_,(UPtr)slot,8,0,info[0])) {
        __atomic_store_n(slot,previous,__ATOMIC_RELEASE);
        if (vm_protect(mach_task_self_,(UPtr)slot,8,0,info[0])) note("[GlitchifyReverseBridge] warning: GOT protection restore failed after rollback");
        note("[GlitchifyReverseBridge] skipped: import replacement rolled back");return;
    }
    __atomic_store_n(&installed,1,__ATOMIC_RELEASE);
    note("[GlitchifyReverseBridge] installed: Chroma objc_getClass import only");
}
#ifndef REVERSE_BRIDGE_TEST
__attribute__((constructor)) static void reverse_loaded(void) {
#if REVERSE_ENABLE_TRACK_ALIAS
    note("[GlitchifyReverseBridge] registering: state and track aliases");
#else
    note("[GlitchifyReverseBridge] registering: state alias only");
#endif
    _dyld_register_func_for_add_image(image_added);
}
#endif
