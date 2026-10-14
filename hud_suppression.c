/* App-local Metal Performance HUD suppression through Apple's public API.
 * Does not change rendering, haptics, preferences, environment, or v5 bridge.
 * https://developer.apple.com/documentation/xcode/customizing-metal-performance-hud
 */
typedef void *Obj;
typedef void (*Imp)(void);
typedef unsigned char Bool;
typedef unsigned long UPtr;
extern Obj objc_getClass(const char *);
extern Obj sel_registerName(const char *);
#ifdef HUD_SUPPRESSION_TEST
extern Obj hud_test_send(Obj,Obj,...);
static Obj (*hud_test_dispatch)(Obj,Obj,...)=hud_test_send;
#define objc_msgSend hud_test_dispatch
#else
extern Obj objc_msgSend(Obj,Obj);
#endif
extern Obj class_getInstanceMethod(Obj,Obj);
extern Obj class_getSuperclass(Obj);
extern const char *method_getTypeEncoding(Obj);
extern Imp method_getImplementation(Obj);
extern Imp method_setImplementation(Obj,Imp);
extern Bool class_addMethod(Obj,Obj,Imp,const char *);
extern Obj objc_getAssociatedObject(Obj,const void *);
extern void objc_setAssociatedObject(Obj,const void *,Obj,UPtr);
extern void NSLog(Obj,...);

static Imp original_init,original_clone,original_device;
static char applying_key;
static unsigned int logged_applied;

static int same(const char *a,const char *b) {
    if (!a || !b) return 0;
    while (*a && *a==*b) { ++a; ++b; }
    return *a==*b;
}
static Obj sel(const char *name) { return sel_registerName(name); }
static Obj string(const char *value) {
    return ((Obj(*)(Obj,Obj,const char *))objc_msgSend)(objc_getClass("NSString"),sel("stringWithUTF8String:"),value);
}
static Obj get(Obj value,const char *name) { return objc_msgSend(value,sel(name)); }
static void note(const char *message) {
    Obj value=string(message);
    if (value) NSLog(value);
}
static Bool responds(Obj value,Obj selector) {
    return ((Bool(*)(Obj,Obj,Obj))objc_msgSend)(value,sel("respondsToSelector:"),selector);
}
static Obj item(Obj dictionary,Obj key) {
    return ((Obj(*)(Obj,Obj,Obj))objc_msgSend)(dictionary,sel("objectForKey:"),key);
}
static Bool equal(Obj a,Obj b) {
    return a && ((Bool(*)(Obj,Obj,Obj))objc_msgSend)(a,sel("isEqual:"),b);
}

/* Every existing dictionary entry is retained, including position/configuration.
 * The association guards only re-entry on this layer while its public setter runs.
 * A copied layer gets its own dictionary; the source layer is never modified.
 */
static void suppress_hud(Obj layer) {
    if (!layer || objc_getAssociatedObject(layer,&applying_key)) return;
    Obj setter=sel("setDeveloperHUDProperties:");
    if (!responds(layer,setter) || !responds(layer,sel("developerHUDProperties"))) return;
    Obj mode=string("mode"), logging=string("logging"), disabled=string("disabled");
    if (!mode || !logging || !disabled) return;
    Obj old=get(layer,"developerHUDProperties");
    if (equal(item(old,mode),disabled) && equal(item(old,logging),disabled)) return;
    Obj properties=old ? get(old,"mutableCopy") : get(objc_getClass("NSMutableDictionary"),"new");
    if (!properties) return;
    objc_setAssociatedObject(layer,&applying_key,disabled,0); /* assign, valid during this call */
    ((void(*)(Obj,Obj,Obj,Obj))objc_msgSend)(properties,sel("setObject:forKey:"),disabled,mode);
    ((void(*)(Obj,Obj,Obj,Obj))objc_msgSend)(properties,sel("setObject:forKey:"),disabled,logging);
    ((void(*)(Obj,Obj,Obj))objc_msgSend)(layer,setter,properties);
    ((void(*)(Obj,Obj))objc_msgSend)(properties,sel("release"));
    objc_setAssociatedObject(layer,&applying_key,0,0);
    if (!__atomic_exchange_n(&logged_applied,1,__ATOMIC_RELAXED))
        note("[GlitchifyHUD] applied: app Metal HUD disabled");
}

static Obj layer_init(Obj self,Obj command) {
    Obj result=((Obj(*)(Obj,Obj))original_init)(self,command);
    suppress_hud(result);
    return result;
}
static Obj layer_clone(Obj self,Obj command,Obj source) {
    Obj result=((Obj(*)(Obj,Obj,Obj))original_clone)(self,command,source);
    suppress_hud(result);
    return result;
}
static void layer_device(Obj self,Obj command,Obj device) {
    ((void(*)(Obj,Obj,Obj))original_device)(self,command,device);
    suppress_hud(self);
}

/* Add a class-local override when the method is inherited; never mutate CALayer.
 * Existing CAMetalLayer implementations remain first in the call chain.
 */
static int hook(Obj cls,const char *name,const char *encoding,Imp replacement,Imp *original) {
    Obj selector=sel(name), method=class_getInstanceMethod(cls,selector);
    if (!method || !same(method_getTypeEncoding(method),encoding)) return 0;
    Imp current=method_getImplementation(method);
    if (!current || current==replacement) return 0;
    *original=current;
    if (!class_addMethod(cls,selector,replacement,method_getTypeEncoding(method))) {
        Obj local=class_getInstanceMethod(cls,selector),parent=class_getSuperclass(cls);
        if (!local || (parent && local==class_getInstanceMethod(parent,selector)) ||
            !same(method_getTypeEncoding(local),encoding)) return 0;
        *original=method_setImplementation(local,replacement);
    }
    return 1;
}

#ifndef HUD_SUPPRESSION_TEST
__attribute__((constructor))
#endif
static void install_hud_suppression(void) {
    Obj cls=objc_getClass("CAMetalLayer");
    if (!cls || !class_getInstanceMethod(cls,sel("developerHUDProperties")) ||
        !class_getInstanceMethod(cls,sel("setDeveloperHUDProperties:"))) {
        note("[GlitchifyHUD] skipped: public Metal HUD API unavailable");
        return;
    }
    int count=0;
    count+=hook(cls,"init","@16@0:8",(Imp)layer_init,&original_init);
    count+=hook(cls,"initWithLayer:","@24@0:8@16",(Imp)layer_clone,&original_clone);
    count+=hook(cls,"setDevice:","v24@0:8@16",(Imp)layer_device,&original_device);
    if (count==3) note("[GlitchifyHUD] installed: CAMetalLayer initialization, copy and device hooks");
    else note("[GlitchifyHUD] warning: one or more layer ABI guards skipped a hook");
}
