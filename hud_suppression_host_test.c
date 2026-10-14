/* Runtime-message mocks: layer lifecycle chaining and dictionary preservation. */
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define HUD_SUPPRESSION_TEST 1
#include "hud_suppression.c"

typedef struct Node {
    int kind,api;
    const char *text;
    Obj mode,logging,extra,properties,guard,device;
} Node;
static Node *allocated[1024];static unsigned allocation_count;
static Node strings_class={.kind=1},dictionary_class={.kind=2},layer_class={.kind=3},parent_class={.kind=3};
static int apply_count,release_count,log_count,reenter;
static int init_count,clone_count,device_count,fail_add;
static Obj init_result,last_clone_source,last_device;
static Node *node(int kind) {
    Node *n=calloc(1,sizeof(*n));assert(n && allocation_count<1024);
    allocated[allocation_count++]=n;n->kind=kind;n->api=1;return n;
}
static const char *str(Obj x) { return x ? ((Node *)x)->text : ""; }
Obj objc_getClass(const char *name) {
    if(!strcmp(name,"NSString"))return &strings_class;
    if(!strcmp(name,"NSMutableDictionary"))return &dictionary_class;
    if(!strcmp(name,"CAMetalLayer"))return &layer_class;
    return 0;
}
Obj sel_registerName(const char *name) { return (Obj)name; }
Obj objc_getAssociatedObject(Obj x,const void *key) { assert(key==&applying_key);return ((Node *)x)->guard; }
void objc_setAssociatedObject(Obj x,const void *key,Obj v,UPtr policy) {
    assert(key==&applying_key && policy==0);((Node *)x)->guard=v;
}
void NSLog(Obj format,...) { assert(str(format)[0]);++log_count; }
Obj hud_test_send(Obj x,Obj selector,...) {
    if(!x)return 0;
    const char *name=selector;Node *n=x;Obj out=0;
    va_list args;va_start(args,selector);
    if(!strcmp(name,"stringWithUTF8String:")) { Node *v=node(4);v->text=va_arg(args,const char *);out=v; }
    else if(!strcmp(name,"new"))out=node(5);
    else if(!strcmp(name,"respondsToSelector:")) { (void)va_arg(args,Obj);out=(Obj)(UPtr)n->api; }
    else if(!strcmp(name,"developerHUDProperties"))out=n->properties;
    else if(!strcmp(name,"mutableCopy")) { Node *v=node(n->kind);*v=*n;out=v; }
    else if(!strcmp(name,"objectForKey:")) {
        const char *key=str(va_arg(args,Obj));out=!strcmp(key,"mode")?n->mode:!strcmp(key,"logging")?n->logging:n->extra;
    }
    else if(!strcmp(name,"isEqual:"))out=(Obj)(UPtr)(strcmp(str(n),str(va_arg(args,Obj)))==0);
    else if(!strcmp(name,"setObject:forKey:")) {
        Obj value=va_arg(args,Obj);const char *key=str(va_arg(args,Obj));
        if(!strcmp(key,"mode"))n->mode=value;else if(!strcmp(key,"logging"))n->logging=value;else n->extra=value;
    }
    else if(!strcmp(name,"setDeveloperHUDProperties:")) {
        Obj properties=va_arg(args,Obj);++apply_count;
        assert(n->guard);if(reenter)suppress_hud(n);
        n->properties=properties;
    }
    else if(!strcmp(name,"release"))++release_count;
    else { fprintf(stderr,"Unexpected message: %s\n",name);abort(); }
    va_end(args);return out;
}
static Obj original_init_test(Obj self,Obj command) { (void)self;assert(!strcmp(command,"init"));++init_count;return init_result; }
static Obj original_clone_test(Obj self,Obj command,Obj source) {
    assert(!strcmp(command,"initWithLayer:"));++clone_count;last_clone_source=source;
    ((Node *)self)->properties=((Node *)source)->properties;return self;
}
static void original_device_test(Obj self,Obj command,Obj device) {
    assert(!strcmp(command,"setDevice:"));++device_count;last_device=device;((Node *)self)->device=device;
}
typedef struct Method {const char *name,*types;Imp imp;int local;} Method;
static Method methods[]={
    {"init","@16@0:8",(Imp)original_init_test,0},
    {"initWithLayer:","@24@0:8@16",(Imp)original_clone_test,0},
    {"setDevice:","v24@0:8@16",(Imp)original_device_test,1},
    {"developerHUDProperties","@16@0:8",0,1},
    {"setDeveloperHUDProperties:","v24@0:8@16",0,1}};
static Method super_methods[]={
    {"init","@16@0:8",(Imp)original_init_test,1},
    {"initWithLayer:","@24@0:8@16",(Imp)original_clone_test,1}};
Obj class_getSuperclass(Obj cls) {assert(cls==&layer_class);return &parent_class;}
Obj class_getInstanceMethod(Obj cls,Obj selector) {
    if(cls==&parent_class) {
        for(unsigned i=0;i<2;++i)if(!strcmp(super_methods[i].name,selector))return &super_methods[i];
        return 0;
    }
    assert(cls==&layer_class);
    for(unsigned i=0;i<sizeof(methods)/sizeof(methods[0]);++i)
        if(!strcmp(methods[i].name,selector))return methods[i].local ? &methods[i] : &super_methods[i];
    return 0;
}
const char *method_getTypeEncoding(Obj method) {return ((Method *)method)->types;}
Imp method_getImplementation(Obj method) {return ((Method *)method)->imp;}
Imp method_setImplementation(Obj method,Imp imp) {
    Method *m=method;assert(m->local && m!=&super_methods[0] && m!=&super_methods[1]);Imp old=m->imp;m->imp=imp;return old;
}
Bool class_addMethod(Obj cls,Obj selector,Imp imp,const char *types) {
    assert(cls==&layer_class);
    Method *m=0;for(unsigned i=0;i<sizeof(methods)/sizeof(methods[0]);++i)if(!strcmp(methods[i].name,selector))m=&methods[i];
    assert(m && same(m->types,types));
    if(m->local || fail_add)return 0;
    m->imp=imp;m->local=1;return 1;
}
int main(void) {
    install_hud_suppression();assert(log_count==1);
    assert(methods[0].local && methods[1].local);
    assert(original_init==(Imp)original_init_test && original_clone==(Imp)original_clone_test && original_device==(Imp)original_device_test);
    Node *source=node(6),*p=node(5);p->mode=string("default");p->logging=string("default");p->extra=string("position stays");source->properties=p;
    Node *clone=node(6);reenter=1;
    assert(layer_clone(clone,sel("initWithLayer:"),source)==clone);
    assert(clone_count==1 && last_clone_source==source && apply_count==1);
    Node *cp=clone->properties;assert(cp!=p && !strcmp(str(p->mode),"default") && !strcmp(str(p->logging),"default"));
    assert(!strcmp(str(cp->mode),"disabled") && !strcmp(str(cp->logging),"disabled") && cp->extra==p->extra);
    assert(!clone->guard && release_count==1 && log_count==2);
    suppress_hud(clone);assert(apply_count==1 && release_count==1); /* idempotent */
    Node *empty=node(6),*replacement=node(6);init_result=replacement;
    assert(layer_init(empty,sel("init"))==replacement);
    assert(init_count==1 && !empty->properties && replacement->properties && apply_count==2);
    init_result=0;assert(layer_init(empty,sel("init"))==0);assert(apply_count==2);
    Node *device_layer=node(6),*device=node(7);layer_device(device_layer,sel("setDevice:"),device);
    assert(device_count==1 && last_device==device && device_layer->device==device && apply_count==3);
    Node *unavailable=node(6);unavailable->api=0;suppress_hud(unavailable);assert(apply_count==3);
    Imp saved=original_device;methods[2].types="unsupported";
    assert(!hook(&layer_class,"setDevice:","v24@0:8@16",(Imp)layer_device,&original_device));assert(original_device==saved);
    methods[0].local=0;fail_add=1;
    assert(!hook(&layer_class,"init","@16@0:8",(Imp)layer_init,&original_init));
    assert(super_methods[0].imp==(Imp)original_init_test && super_methods[1].imp==(Imp)original_clone_test);
    for(unsigned i=0;i<allocation_count;++i)free(allocated[i]);
    puts("PASS: original initializer result, copy source preservation, device chaining, dictionary preservation, re-entry guard, idempotence, unavailable API, wrong ABI and failed class-local method addition");
    return 0;
}
