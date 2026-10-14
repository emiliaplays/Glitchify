/* Foreground music-haptics pause repair. Never changes preferences or system
 * Music Haptics. Call the original thread-safe gate; its worker owns stopping. */
typedef unsigned char U8;
typedef unsigned int U32;
typedef unsigned long long U64;
typedef unsigned long UPtr;
typedef long IPtr;
typedef void *Obj;
typedef void (*Imp)(void);
typedef struct {U32 magic,cpu,subtype,filetype,ncmds,sizeofcmds,flags,reserved;} Header;
typedef struct {U32 cmd,size;} Command;
typedef struct {U32 cmd,size;char name[16];U64 vmaddr,vmsize,fileoff,filesize;int maxprot,initprot;U32 nsects,flags;} Segment;
static const U8 expected_uuid[16]={0xd4,0xc7,0x5c,0x03,0xb9,0x0b,0x32,0x9d,0x83,0xb9,0x60,0xd7,0x68,0xcc,0x43,0xaa};
static const U8 gate_bytes[]={0x68,0x1a,0x00,0xf0,0x08,0xbd,0x41,0xf9,0xa8,0x00,0x00,0xb4,0x68,0x1a,0x00,0xf0,0x08,0x01,0x0e,0x91,0x00,0xfd,0x9f,0x08,0x02,0x00,0x00,0x14,0xc0,0x03,0x5f,0xd6,0xfd,0x7b,0xbf,0xa9,0xfd,0x03,0x00,0x91,0x68,0x1a,0x00,0xf0,0x08,0x01,0x0e,0x91,0x08,0xfd,0xdf,0x08,0x1f,0x05,0x00,0x71,0xc1,0x03,0x00,0x54,0x68,0x1a,0x00,0xf0,0x08,0x41,0x0e,0x91,0x08,0xfd,0xdf,0x08,0x48,0x03,0x00,0x36,0x68,0x1a,0x00,0xf0,0x08,0x05,0x0e,0x91,0x08,0xfd,0xdf,0x08,0x09,0x01,0x00,0x52,0x6a,0x1a,0x00,0xf0,0x4a,0x45,0x0e,0x91,0x4b,0xfd,0x5f,0x08,0x49,0xfd,0x0c,0x08,0xcc,0xff,0xff,0x35,0x6a,0x01,0x00,0x12,0x3f,0x01,0x0a,0x6b,0x00,0x03,0x00,0x54,0x68,0x02,0x00,0x37,0x68,0x1a,0x00,0xf0,0x08,0x01,0x27,0x91,0x09,0xfd,0x5f,0x88,0x29,0x05,0x00,0x11,0x09,0xfd,0x0a,0x88,0xaa,0xff,0xff,0x35,0x23,0x02,0x00,0x94,0x68,0x1a,0x00,0xf0,0x08,0xe5,0x44,0xf9,0x1f,0x05,0x00,0xb1,0xc1,0x01,0x00,0x54,0x07,0x00,0x00,0x14,0x68,0x1a,0x00,0xf0,0x08,0x45,0x0e,0x91,0x09,0xfd,0x5f,0x08,0x1f,0xfd,0x0a,0x08,0xca,0xff,0xff,0x35,0xa9,0x00,0x00,0x36,0x68,0x1a,0x00,0xf0,0x00,0xbd,0x41,0xf9,0xfd,0x7b,0xc1,0xa8,0xeb,0xd4,0x04,0x14,0xfd,0x7b,0xc1,0xa8,0xc0,0x03,0x5f,0xd6,0x8c,0xcc,0x04,0x94,0xf9,0xff,0xff,0x17};
static int same(const char *a,const char *b){if(!a||!b)return 0;while(*a&&*a==*b){++a;++b;}return *a==*b;}
static int gate_fingerprint(const U8 *p){if(!p)return 0;for(UPtr i=0;i<sizeof(gate_bytes);++i)if(p[i]!=gate_bytes[i])return 0;return 1;}
static int valid_image(const Header *h){
    if(!h||h->magic!=0xfeedfacf||h->cpu!=0x100000c||h->subtype||h->filetype!=6||h->ncmds>256||h->sizeofcmds>65536)return 0;
    const U8 *p=(const U8 *)h+32,*end=p+h->sizeofcmds;U32 uuid=0,identity=0,covered=0;
    const U64 addresses[]={0x1d50dc,0x1d8c64};const U64 lengths[]={sizeof(gate_bytes),4};
    const char install[]="/Library/MobileSubstrate/DynamicLibraries/spotifyglass.dylib";
    for(U32 i=0;i<h->ncmds;++i){
        if((UPtr)(end-p)<8)return 0;
        const Command *c=(const Command *)p;
        if(c->size<8||c->size%8||c->size>(UPtr)(end-p))return 0;
        if(c->cmd==0x1b&&c->size==24){uuid=1;for(U32 j=0;j<16;++j)if(p[8+j]!=expected_uuid[j])uuid=0;}
        if(c->cmd==0xd&&c->size>=24){U32 off=*(const U32 *)(p+8);if(off>=24&&off<c->size){U32 j=0;while(j<sizeof(install)&&off+j<c->size&&p[off+j]==(U8)install[j])++j;identity=j==sizeof(install);}}
        if(c->cmd==0x19&&c->size>=72){
            const Segment *s=(const Segment *)p;if(s->nsects>(c->size-72)/80)return 0;
            if((s->initprot&5)==5)for(U32 j=0;j<2;++j)if(s->vmsize>=lengths[j]&&addresses[j]>=s->vmaddr&&addresses[j]-s->vmaddr<=s->vmsize-lengths[j])covered|=1u<<j;
        }
        p+=c->size;
    }
    return p==end&&uuid&&identity&&covered==3;
}
typedef struct {U64 sequence;U32 accepted,pauses;int valid,playing,paused;} State;
/* A newer main-thread event must not be replaced by an older queued event. */
static int accept_state(State *s,U64 sequence,int valid,int playing,int paused){
    if(sequence<=s->sequence)return 0;
    if(valid&&paused&&s->valid&&!s->paused&&s->pauses<65535)++s->pauses;
    s->sequence=sequence;s->valid=valid!=0;s->playing=valid&&playing;s->paused=valid&&paused;
    if(s->accepted<65535)++s->accepted;
    return 1;
}
static int gate_policy(const State *s,int preference){return !s->valid?-1:(preference&&s->playing&&!s->paused);}
static int status_write_allowed(U32 attempts,U32 previous,U32 current){return attempts<128&&previous!=current;}

#if !defined(HAPTICS_PAUSE_GUARD_TEST) || defined(HAPTICS_PAUSE_GUARD_RUNTIME_TEST)
extern Obj objc_getClass(const char *);
extern Obj object_getClass(Obj);
#ifdef HAPTICS_PAUSE_GUARD_RUNTIME_TEST
extern Obj haptics_test_send(Obj,Obj,...);
static Obj (*haptics_test_dispatch)(Obj,Obj,...)=haptics_test_send;
#define objc_msgSend haptics_test_dispatch
#else
extern Obj objc_msgSend(Obj,Obj);
#endif
extern Obj sel_registerName(const char *);
extern Obj objc_retain(Obj);
extern void objc_release(Obj);
extern Obj class_getInstanceMethod(Obj,Obj);
extern Obj class_getSuperclass(Obj);
extern const char *method_getTypeEncoding(Obj);
extern Imp method_getImplementation(Obj);
extern Imp method_setImplementation(Obj,Imp);
extern U8 class_addMethod(Obj,Obj,Imp,const char *);
extern Obj objc_allocateClassPair(Obj,const char *,UPtr);
extern void objc_registerClassPair(Obj);
extern void objc_disposeClassPair(Obj);
extern U32 _dyld_image_count(void);
extern const Header *_dyld_get_image_header(U32);
extern IPtr _dyld_get_image_vmaddr_slide(U32);
extern char _dispatch_main_q[];
extern void dispatch_async_f(void *,void *,void (*)(void *));
extern void *malloc(UPtr);
extern void free(void *);
extern void NSLog(Obj,...);
extern Obj NSUserDefaultsDidChangeNotification;
extern Obj UIApplicationDidBecomeActiveNotification;
extern Obj UIApplicationWillResignActiveNotification;

static State state;
static U64 next_sequence;
static U32 refresh_pending,installed,image_validated,attempts,write_failed;
static U32 last_status=~0u;
static int requested_known,requested_gate;
static void (*music_gate)(U8);
static Imp original_watcher;
static Obj observer;
static Obj sel(const char *name){return sel_registerName(name);}
static Obj get(Obj x,const char *name){return objc_msgSend(x,sel(name));}
static Obj string(const char *value){return ((Obj(*)(Obj,Obj,const char *))objc_msgSend)(objc_getClass("NSString"),sel("stringWithUTF8String:"),value);}
static int kind(Obj x,Obj cls){return x&&cls&&((U8(*)(Obj,Obj,Obj))objc_msgSend)(x,sel("isKindOfClass:"),cls);}
static int main_thread(void){return ((U8(*)(Obj,Obj))objc_msgSend)(objc_getClass("NSThread"),sel("isMainThread"))!=0;}
static int method_matches(Obj cls,const char *name,const char *types){Obj method=cls?class_getInstanceMethod(cls,sel(name)):0;return method&&same(method_getTypeEncoding(method),types);}
static int music_preference(void){return ((U8(*)(Obj,Obj,Obj))objc_msgSend)(get(objc_getClass("NSUserDefaults"),"standardUserDefaults"),sel("boolForKey:"),string("spotifyglass.haptics.music"))!=0;}
static int foreground(void){Obj app=get(objc_getClass("UIApplication"),"sharedApplication");return app&&((IPtr(*)(Obj,Obj))objc_msgSend)(app,sel("applicationState"))==0;}
static void put(Obj dictionary,const char *key,Obj value){if(value)((void(*)(Obj,Obj,Obj,Obj))objc_msgSend)(dictionary,sel("setObject:forKey:"),value,string(key));}
static void bool_item(Obj d,const char *key,int value){put(d,key,((Obj(*)(Obj,Obj,U8))objc_msgSend)(objc_getClass("NSNumber"),sel("numberWithBool:"),value!=0));}
static void number_item(Obj d,const char *key,U32 value){put(d,key,((Obj(*)(Obj,Obj,U32))objc_msgSend)(objc_getClass("NSNumber"),sel("numberWithUnsignedInt:"),value));}
static void write_status(int preference){
    int active=foreground();
    U32 mask=installed|(image_validated<<1)|((U32)state.valid<<2)|((U32)state.playing<<3)|((U32)state.paused<<4)|((U32)active<<5)|((U32)preference<<6)|((U32)requested_known<<7)|((U32)requested_gate<<8);
    if(!status_write_allowed(attempts,last_status,mask))return;
    last_status=mask;++attempts;
    Obj report=get(objc_getClass("NSMutableDictionary"),"dictionary");if(!report){write_failed=1;return;}
    number_item(report,"schema",1);put(report,"revision",string("reverse-v9-haptics-pause"));
    bool_item(report,"installed",installed);bool_item(report,"imageValidated",image_validated);
    bool_item(report,"lastStateValid",state.valid);bool_item(report,"playing",state.playing);bool_item(report,"paused",state.paused);
    bool_item(report,"foreground",active);bool_item(report,"musicPreference",preference);
    bool_item(report,"gateRequestedKnown",requested_known);bool_item(report,"requestedGate",requested_gate);
    number_item(report,"pauseTransitions",state.pauses);number_item(report,"acceptedStates",state.accepted);
    number_item(report,"writeAttempts",attempts);bool_item(report,"writePreviouslyFailed",write_failed);
    Obj manager=get(objc_getClass("NSFileManager"),"defaultManager");
    Obj paths=((Obj(*)(Obj,Obj,UPtr,UPtr))objc_msgSend)(manager,sel("URLsForDirectory:inDomains:"),13,1);
    Obj directory=get(paths,"firstObject");
    Obj url=directory?((Obj(*)(Obj,Obj,Obj))objc_msgSend)(directory,sel("URLByAppendingPathComponent:"),string("GlitchifyHapticsPauseGuard.plist")):0;
    U8 ok=url&&((U8(*)(Obj,Obj,Obj,U8))objc_msgSend)(report,sel("writeToURL:atomically:"),url,1);
    if(!ok)write_failed=1;
}
static void apply_current(void){
    int preference=music_preference(),wanted=gate_policy(&state,preference);
    if(installed&&music_gate&&wanted>=0){music_gate((U8)wanted);requested_known=1;requested_gate=wanted;}
    write_status(preference);
}
static void sample_state(Obj value,U64 sequence){
    int recognized=kind(value,objc_getClass("SPTPlayerStateImplementation"))||kind(value,objc_getClass("SPTPlayerState"));
    Obj cls=recognized?object_getClass(value):0;
    int valid=recognized&&method_matches(cls,"isPlaying","B16@0:8")&&method_matches(cls,"isPaused","B16@0:8");
    int playing=valid&&((U8(*)(Obj,Obj))objc_msgSend)(value,sel("isPlaying"));
    int paused=valid&&((U8(*)(Obj,Obj))objc_msgSend)(value,sel("isPaused"));
    if(accept_state(&state,sequence,valid,playing,paused))apply_current();
}
typedef struct {Obj value;U64 sequence;} PendingState;
static void consume_state(void *context){
    PendingState *pending=context;sample_state(pending->value,pending->sequence);
    objc_release(pending->value);free(pending);
}
static void watcher(Obj self,Obj command,Obj value){
    U64 sequence=__atomic_add_fetch(&next_sequence,1,__ATOMIC_RELAXED);
    ((void(*)(Obj,Obj,Obj))original_watcher)(self,command,value);
    if(main_thread()){sample_state(value,sequence);return;}
    PendingState *pending=malloc(sizeof(*pending));if(!pending)return;
    pending->value=objc_retain(value);pending->sequence=sequence;
    dispatch_async_f(_dispatch_main_q,pending,consume_state);
}
static void refresh(void *unused){
    (void)unused;__atomic_store_n(&refresh_pending,0,__ATOMIC_RELAXED);apply_current();
}
static void notification(Obj self,Obj command,Obj value){
    (void)self;(void)command;(void)value;
    /* Execute after all synchronous Chroma preference/lifecycle callbacks. */
    if(!__atomic_exchange_n(&refresh_pending,1,__ATOMIC_RELAXED))dispatch_async_f(_dispatch_main_q,0,refresh);
}
static int install_observer(void){
    Obj cls=objc_allocateClassPair(objc_getClass("NSObject"),"GlitchifyHapticsPauseObserver",0);if(!cls)return 0;
    if(!class_addMethod(cls,sel("changed:"),(Imp)notification,"v24@0:8@16")){objc_disposeClassPair(cls);return 0;}
    objc_registerClassPair(cls);observer=get(cls,"new");if(!observer)return 0;
    Obj center=get(objc_getClass("NSNotificationCenter"),"defaultCenter");
    Obj names[]={NSUserDefaultsDidChangeNotification,UIApplicationDidBecomeActiveNotification,UIApplicationWillResignActiveNotification};
    for(U32 i=0;i<3;++i)((void(*)(Obj,Obj,Obj,Obj,Obj,Obj))objc_msgSend)(center,sel("addObserver:selector:name:object:"),observer,sel("changed:"),names[i],0);
    return 1;
}
static void install(void *unused){
    (void)unused;if(installed||!main_thread())return;
    Obj info=get(get(objc_getClass("NSBundle"),"mainBundle"),"infoDictionary");
    Obj executable=((Obj(*)(Obj,Obj,Obj))objc_msgSend)(info,sel("objectForKey:"),string("CFBundleExecutable"));
    if(!((U8(*)(Obj,Obj,Obj))objc_msgSend)(executable,sel("isEqualToString:"),string("Spotify")))return;
    Obj cls=objc_getClass("SGSystemHapticsWatcher");
    if(!method_matches(cls,"playerStateDidChange:","v24@0:8@16"))return;
    Obj method=class_getInstanceMethod(cls,sel("playerStateDidChange:"));Imp current=method_getImplementation(method);
    U32 count=_dyld_image_count();if(count>4096)return;
    for(U32 i=0;i<count;++i){const Header *h=_dyld_get_image_header(i);if(!valid_image(h))continue;
        UPtr slide=(UPtr)_dyld_get_image_vmaddr_slide(i),gate=slide+0x1d50dc;
        if((UPtr)current!=slide+0x1d8c64||!gate_fingerprint((const U8 *)gate))continue;
        music_gate=(void(*)(U8))gate;image_validated=1;break;
    }
    if(!image_validated||!install_observer())return;
    original_watcher=current;
    if(!class_addMethod(cls,sel("playerStateDidChange:"),(Imp)watcher,method_getTypeEncoding(method))){
        Obj local=class_getInstanceMethod(cls,sel("playerStateDidChange:")),parent=class_getSuperclass(cls);
        if(!local||(parent&&local==class_getInstanceMethod(parent,sel("playerStateDidChange:")))||method_getImplementation(local)!=current)return;
        original_watcher=method_setImplementation(local,(Imp)watcher);
    }
    installed=1;apply_current();
    NSLog(string("[GlitchifyHapticsPause] installed foreground-only pause guard; system haptics unchanged"));
}
#ifndef HAPTICS_PAUSE_GUARD_RUNTIME_TEST
__attribute__((constructor))static void start(void){dispatch_async_f(_dispatch_main_q,0,install);}
#endif
#endif
