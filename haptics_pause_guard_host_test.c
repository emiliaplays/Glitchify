/* Independent bounded tests; no Apple framework or app execution. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#define HAPTICS_PAUSE_GUARD_TEST 1
#define HAPTICS_PAUSE_GUARD_RUNTIME_TEST 1
#include "haptics_pause_guard.c"

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { \
    fprintf(stderr,"FAIL line %u: %s\n",(unsigned)__LINE__,#x); exit(1); \
} } while (0)

typedef struct {Obj cls;int playing,paused;} MockState;
static int class_string,class_defaults,class_thread,class_app,class_old,class_new;
static int class_other,class_watch,class_object;
static int defaults_object,application_object;
static int on_main=1,preference=1,application_state=0;
static int original_calls,gate_calls,last_gate=-1,retain_calls,release_calls;
static int original_sets_paused,wrong_encoding;
static int events[256],event_count;
static Obj expected_self,expected_command;
typedef struct {void (*fn)(void *);void *context;} Queued;
static Queued queue[64];static unsigned queued;
char _dispatch_main_q[1];
Obj NSUserDefaultsDidChangeNotification=(Obj)"defaults";
Obj UIApplicationDidBecomeActiveNotification=(Obj)"active";
Obj UIApplicationWillResignActiveNotification=(Obj)"inactive";

Obj objc_getClass(const char *name) {
    if(!strcmp(name,"NSString"))return &class_string;
    if(!strcmp(name,"NSUserDefaults"))return &class_defaults;
    if(!strcmp(name,"NSThread"))return &class_thread;
    if(!strcmp(name,"UIApplication"))return &class_app;
    if(!strcmp(name,"SPTPlayerStateImplementation"))return &class_old;
    if(!strcmp(name,"SPTPlayerState"))return &class_new;
    if(!strcmp(name,"SGSystemHapticsWatcher"))return &class_watch;
    if(!strcmp(name,"NSObject"))return &class_object;
    return NULL;
}
Obj object_getClass(Obj object) {CHECK(object!=NULL);return ((MockState *)object)->cls;}
Obj sel_registerName(const char *name) {return (Obj)name;}
Obj objc_retain(Obj value) {++retain_calls;return value;}
void objc_release(Obj value) {(void)value;++release_calls;}
Obj class_getInstanceMethod(Obj cls,Obj selector) {
    if(cls==&class_old || cls==&class_new) {
        if(!strcmp(selector,"isPlaying") || !strcmp(selector,"isPaused"))return selector;
    }
    return NULL;
}
const char *method_getTypeEncoding(Obj method) {CHECK(method!=NULL);return wrong_encoding?"c16@0:8":"B16@0:8";}
Obj haptics_test_send(Obj object,Obj selector,...) {
    const char *name=selector;Obj result=NULL;va_list ap;va_start(ap,selector);
    if(!strcmp(name,"stringWithUTF8String:")) {
        CHECK(object==&class_string);result=(Obj)va_arg(ap,const char *);
    } else if(!strcmp(name,"isMainThread")) {
        CHECK(object==&class_thread);result=(Obj)(UPtr)on_main;
    } else if(!strcmp(name,"standardUserDefaults")) {
        CHECK(object==&class_defaults);result=&defaults_object;
    } else if(!strcmp(name,"boolForKey:")) {
        CHECK(object==&defaults_object);
        CHECK(!strcmp(va_arg(ap,Obj),"spotifyglass.haptics.music"));result=(Obj)(UPtr)preference;
    } else if(!strcmp(name,"sharedApplication")) {
        CHECK(object==&class_app);result=&application_object;
    } else if(!strcmp(name,"applicationState")) {
        CHECK(object==&application_object);result=(Obj)(UPtr)application_state;
    } else if(!strcmp(name,"isKindOfClass:")) {
        Obj cls=va_arg(ap,Obj);result=(Obj)(UPtr)(object&&((MockState *)object)->cls==cls);
    } else if(!strcmp(name,"isPlaying")) {
        CHECK(object!=NULL);result=(Obj)(UPtr)((MockState *)object)->playing;
    } else if(!strcmp(name,"isPaused")) {
        CHECK(object!=NULL);result=(Obj)(UPtr)((MockState *)object)->paused;
    } else {
        fprintf(stderr,"Unexpected ObjC message: %s\n",name);CHECK(0);
    }
    va_end(ap);return result;
}
void dispatch_async_f(void *q,void *context,void (*fn)(void *)) {
    CHECK(q==_dispatch_main_q && queued<64);queue[queued++]=(Queued){fn,context};
}
static void drain_one(unsigned index) {
    CHECK(index<queued && queue[index].fn);Queued entry=queue[index];queue[index].fn=NULL;
    CHECK(on_main);entry.fn(entry.context);
}
static void original_test(Obj self,Obj command,Obj value) {
    CHECK(self==expected_self && command==expected_command);
    ++original_calls;CHECK(event_count<256);events[event_count++]=1;
    if(original_sets_paused && value)((MockState *)value)->paused=1;
}
static void gate_test(U8 value) {
    CHECK(on_main && value<=1);++gate_calls;last_gate=value;
    CHECK(event_count<256);events[event_count++]=value?3:2;
}
/* Installation is independently image/fingerprint-tested below. These stubs
 * must not be reached by callback-policy tests or the off-main install guard. */
Obj class_getSuperclass(Obj x) {(void)x;CHECK(0);return NULL;}
Imp method_getImplementation(Obj x) {(void)x;CHECK(0);return NULL;}
Imp method_setImplementation(Obj x,Imp y) {(void)x;(void)y;CHECK(0);return NULL;}
U8 class_addMethod(Obj x,Obj y,Imp z,const char *t) {(void)x;(void)y;(void)z;(void)t;CHECK(0);return 0;}
Obj objc_allocateClassPair(Obj x,const char *y,UPtr z) {(void)x;(void)y;(void)z;CHECK(0);return NULL;}
void objc_registerClassPair(Obj x) {(void)x;CHECK(0);}
void objc_disposeClassPair(Obj x) {(void)x;CHECK(0);}
U32 _dyld_image_count(void) {CHECK(0);return 0;}
const Header *_dyld_get_image_header(U32 x) {(void)x;CHECK(0);return NULL;}
IPtr _dyld_get_image_vmaddr_slide(U32 x) {(void)x;CHECK(0);return 0;}
void NSLog(Obj format,...) {(void)format;CHECK(0);}

static void test_runtime_callbacks(void) {
    on_main=0;install(NULL);CHECK(!installed);on_main=1;
    state=(State){0};next_sequence=0;attempts=128; /* No diagnostic I/O in callback tests. */
    installed=1;music_gate=gate_test;original_watcher=(Imp)original_test;
    expected_self=&class_watch;expected_command=sel("playerStateDidChange:");
    MockState playing={&class_old,1,0},paused={&class_old,1,1};
    watcher(expected_self,expected_command,&playing);
    CHECK(original_calls==1 && gate_calls==1 && last_gate==1);
    CHECK(events[0]==1 && events[1]==3 && !queued);
    watcher(expected_self,expected_command,&paused);
    CHECK(original_calls==2 && gate_calls==2 && last_gate==0 && state.paused);
    CHECK(events[2]==1 && events[3]==2);
    watcher(expected_self,expected_command,&playing);
    CHECK(original_calls==3 && gate_calls==3 && last_gate==1);
    original_sets_paused=1;
    watcher(expected_self,expected_command,&playing);
    CHECK(original_calls==4 && last_gate==0 && state.paused); /* Sample after original. */
    original_sets_paused=0;playing.paused=0;
    preference=0;
    watcher(expected_self,expected_command,&playing);
    CHECK(original_calls==5 && last_gate==0 && state.playing);
    preference=1;
    MockState newer={&class_new,1,0};
    watcher(expected_self,expected_command,&newer);
    CHECK(original_calls==6 && last_gate==1);
    int previous_gate_calls=gate_calls;
    MockState unknown={&class_other,1,0};
    watcher(expected_self,expected_command,&unknown);
    CHECK(original_calls==7 && gate_calls==previous_gate_calls && !state.valid);
    watcher(expected_self,expected_command,NULL);
    CHECK(original_calls==8 && gate_calls==previous_gate_calls && !state.valid);
    wrong_encoding=1;
    watcher(expected_self,expected_command,&paused);
    CHECK(original_calls==9 && gate_calls==previous_gate_calls && !state.valid);
    wrong_encoding=0;
    /* Two old events are queued; a newer main-thread pause wins immediately. */
    on_main=0;watcher(expected_self,expected_command,&playing);
    watcher(expected_self,expected_command,&newer);
    CHECK(original_calls==11 && queued==2 && retain_calls==2 && release_calls==0);
    CHECK(gate_calls==previous_gate_calls);
    on_main=1;watcher(expected_self,expected_command,&paused);
    CHECK(original_calls==12 && last_gate==0 && state.paused);
    U64 sequence=state.sequence;previous_gate_calls=gate_calls;
    drain_one(1);drain_one(0);
    CHECK(state.sequence==sequence && state.paused && gate_calls==previous_gate_calls);
    CHECK(original_calls==12 && release_calls==2);
    /* New off-main event is retained, sampled once and released on main. */
    on_main=0;watcher(expected_self,expected_command,&playing);on_main=1;
    CHECK(queued==3 && retain_calls==3 && release_calls==2);
    drain_one(2);
    CHECK(last_gate==1 && original_calls==13 && release_calls==3);
    /* Preferences/lifecycle notifications coalesce and run after sync callers. */
    preference=0;previous_gate_calls=gate_calls;
    notification(NULL,NULL,NULL);notification(NULL,NULL,NULL);
    CHECK(queued==4 && refresh_pending==1 && gate_calls==previous_gate_calls);
    drain_one(3);CHECK(!refresh_pending && last_gate==0);
    preference=1;notification(NULL,NULL,NULL);CHECK(queued==5);drain_one(4);
    CHECK(last_gate==1 && original_calls==13);
    /* Lifecycle status does not call any system haptics or audio API. */
    application_state=2;watcher(expected_self,expected_command,&paused);
    CHECK(last_gate==0 && original_calls==14);
    CHECK(retain_calls==release_calls);
}

static void test_policy(void) {
    CHECK(same("B16@0:8","B16@0:8"));
    CHECK(!same("B16@0:8","c16@0:8") && !same(NULL,"B16@0:8"));
    State s={0};
    CHECK(gate_policy(&s,0)==-1 && gate_policy(&s,1)==-1);
    CHECK(!accept_state(&s,0,1,1,0));
    CHECK(accept_state(&s,1,1,1,0));
    CHECK(gate_policy(&s,1)==1 && gate_policy(&s,0)==0);
    CHECK(s.accepted==1 && s.pauses==0 && s.sequence==1);
    CHECK(accept_state(&s,2,1,1,1)); /* Spotify may retain playing on pause. */
    CHECK(gate_policy(&s,1)==0 && s.pauses==1);
    CHECK(accept_state(&s,3,1,0,1));
    CHECK(gate_policy(&s,1)==0 && s.pauses==1);
    State before=s;
    CHECK(!accept_state(&s,2,1,1,0)); /* Older queued event cannot resume. */
    CHECK(!memcmp(&s,&before,sizeof(s)));
    CHECK(!accept_state(&s,3,1,1,0)); /* Duplicate event cannot resume. */
    CHECK(!memcmp(&s,&before,sizeof(s)));
    CHECK(accept_state(&s,4,1,1,0));
    CHECK(gate_policy(&s,1)==1 && s.pauses==1);
    CHECK(accept_state(&s,5,1,0,0)); /* Stopped/not playing. */
    CHECK(gate_policy(&s,1)==0 && gate_policy(&s,0)==0);
    CHECK(accept_state(&s,6,0,1,1)); /* Unknown state does not invent values. */
    CHECK(!s.valid && !s.playing && !s.paused);
    CHECK(gate_policy(&s,0)==-1 && gate_policy(&s,1)==-1);
    CHECK(accept_state(&s,7,1,0,1));
    CHECK(s.pauses==1 && gate_policy(&s,1)==0);
    CHECK(accept_state(&s,8,1,1,0));
    CHECK(accept_state(&s,9,1,1,1));
    CHECK(s.pauses==2 && gate_policy(&s,1)==0);
    s.accepted=65535;s.pauses=65535;s.paused=0;
    CHECK(accept_state(&s,10,1,1,1));
    CHECK(s.accepted==65535 && s.pauses==65535);
    for(int valid=0;valid<2;++valid)
        for(int playing=0;playing<2;++playing)
            for(int paused=0;paused<2;++paused)
                for(int preference=0;preference<2;++preference) {
                    State t={.valid=valid,.playing=playing,.paused=paused};
                    int expected=valid?(preference && playing && !paused):-1;
                    CHECK(gate_policy(&t,preference)==expected);
                }
    CHECK(status_write_allowed(0,~0u,0));
    CHECK(!status_write_allowed(0,0,0));
    CHECK(status_write_allowed(127,0,1));
    CHECK(!status_write_allowed(128,0,1));
    CHECK(!status_write_allowed(UINT32_MAX,0,1));
}

static U8 *load_file(const char *path,size_t *length) {
    FILE *f=fopen(path,"rb");CHECK(f!=NULL);
    CHECK(fseek(f,0,SEEK_END)==0);long n=ftell(f);CHECK(n>0);
    CHECK(fseek(f,0,SEEK_SET)==0);
    U8 *p=malloc((size_t)n);CHECK(p!=NULL);
    CHECK(fread(p,1,(size_t)n,f)==(size_t)n);CHECK(fclose(f)==0);
    *length=(size_t)n;return p;
}
static U8 *find_command(U8 *image,U32 kind) {
    Header *h=(Header *)image;U8 *p=image+32;
    for(U32 i=0;i<h->ncmds;++i) {
        Command *c=(Command *)p;if(c->cmd==kind)return p;p+=c->size;
    }
    return NULL;
}
static U8 *file_address(U8 *image,size_t length,U64 address,size_t count) {
    Header *h=(Header *)image;U8 *p=image+32;
    for(U32 i=0;i<h->ncmds;++i) {
        Command *c=(Command *)p;
        if(c->cmd==0x19) {
            Segment *s=(Segment *)p;
            if(address>=s->vmaddr && address-s->vmaddr<s->filesize) {
                U64 offset=s->fileoff+address-s->vmaddr;
                CHECK(offset<=length && count<=length-offset);
                return image+(size_t)offset;
            }
        }
        p+=c->size;
    }
    CHECK(0);return NULL;
}
static void test_image(const char *path) {
    size_t length;U8 *real=load_file(path,&length);Header *h=(Header *)real;
    CHECK(length>sizeof(*h) && h->sizeofcmds<=length-sizeof(*h));
    CHECK(valid_image(h));CHECK(!valid_image(NULL));
    U8 *gate=file_address(real,length,0x1d50dc,sizeof(gate_bytes));
    CHECK(gate_fingerprint(gate));CHECK(!gate_fingerprint(NULL));
    U8 altered[sizeof(gate_bytes)];
    for(size_t i=0;i<sizeof(altered);++i) {
        memcpy(altered,gate,sizeof(altered));altered[i]^=1;
        CHECK(!gate_fingerprint(altered));
    }
    size_t n=sizeof(*h)+h->sizeofcmds;U8 *copy=malloc(n);CHECK(copy!=NULL);
    Header *c=(Header *)copy;
#define RESET() memcpy(copy,real,n)
#define REJECT(field,value) do { RESET(); c->field=(value); CHECK(!valid_image(c)); } while(0)
    REJECT(magic,0);REJECT(cpu,0x1000007);REJECT(subtype,2);
    REJECT(filetype,2);REJECT(ncmds,257);REJECT(sizeofcmds,65537);
    REJECT(ncmds,h->ncmds+1);REJECT(ncmds,h->ncmds-1);
    REJECT(sizeofcmds,h->sizeofcmds-8);
    RESET();U8 *uuid=find_command(copy,0x1b);CHECK(uuid!=NULL);
    for(size_t i=0;i<16;++i) {
        RESET();uuid=find_command(copy,0x1b);uuid[8+i]^=1;CHECK(!valid_image(c));
    }
    RESET();U8 *identity=find_command(copy,0xd);CHECK(identity!=NULL);
    U32 name_offset;memcpy(&name_offset,identity+8,4);identity[name_offset]^=1;
    CHECK(!valid_image(c));
    RESET();identity=find_command(copy,0xd);memset(identity+8,0,4);CHECK(!valid_image(c));
    RESET();((Command *)(copy+32))->size=0;CHECK(!valid_image(c));
    RESET();((Command *)(copy+32))->size=9;CHECK(!valid_image(c));
    RESET();((Command *)(copy+32))->size=h->sizeofcmds+8;CHECK(!valid_image(c));
    RESET();U8 *p=copy+32;
    for(U32 i=0;i<c->ncmds;++i) {
        Command *command=(Command *)p;
        if(command->cmd==0x19)((Segment *)p)->initprot&=~4;
        p+=command->size;
    }
    CHECK(!valid_image(c));
    RESET();Segment *first=(Segment *)find_command(copy,0x19);CHECK(first!=NULL);
    first->nsects=UINT32_MAX;CHECK(!valid_image(c));
    RESET();CHECK(valid_image(c));
    free(copy);free(real);
}
int main(int argc,char **argv) {
    CHECK(argc==2);test_policy();test_image(argv[1]);test_runtime_callbacks();
    printf("PASS: %u checks; pause/resume/unknown/disabled policy, original once before sample/gate, queued ordering/ownership, preference notification coalescing, bounded counters/status, real Chroma metadata and complete gate fingerprint negative cases\n",checks);
    return 0;
}
