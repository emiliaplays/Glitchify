/* Keep the requested stock Spotify presentation. Load as a strong dependency
 * of BOTH Chroma and Eevee before their UI caches and lyrics hook groups initialize.
 * Never set spotifyglass.stock: that affects non-UI default-true features too.
 * No hooks, license assertions, data deletion, networking or process control.
 */
static const char *const stock_ui_keys[]={
    "spotifyglass.redesign", "spotifyglass.navbar", "spotifyglass.player",
    "spotifyglass.playerBackdrop", "spotifyglass.albumBackdrop",
    "spotifyglass.playlistBackdrop", "spotifyglass.homeGradient",
    "spotifyglass.artistPhotoFade", "spotifyglass.lyricsCard", "spotifyglass.amoled"
};
typedef void (*WriteDisabled)(void *,const char *);
static void apply_stock_ui(int spotify,void *context,WriteDisabled write_disabled) {
    if (!spotify || !context || !write_disabled) return;
    for (unsigned i=0;i<sizeof(stock_ui_keys)/sizeof(stock_ui_keys[0]);++i)
        write_disabled(context,stock_ui_keys[i]);
}
enum LyricsDecision { LYRICS_SKIP, LYRICS_PRESERVE, LYRICS_LRCLIB };
static enum LyricsDecision lyrics_policy(int spotify,int marked,int present,int number,double value) {
    if (!spotify || marked) return LYRICS_SKIP;
    return !present || (number && value==4.0) ? LYRICS_LRCLIB : LYRICS_PRESERVE;
}

#ifndef STOCK_UI_TEST
typedef void *Obj;
typedef unsigned char Bool;
extern Obj objc_getClass(const char *);
extern Obj sel_registerName(const char *);
extern Obj objc_msgSend(Obj,Obj);
extern void NSLog(Obj,...);
static Obj sel(const char *name) { return sel_registerName(name); }
static Obj get(Obj object,const char *selector) { return objc_msgSend(object,sel(selector)); }
static Obj string(const char *text) {
    return ((Obj(*)(Obj,Obj,const char *))objc_msgSend)(objc_getClass("NSString"),sel("stringWithUTF8String:"),text);
}
static void disable(void *context,const char *name) {
    Obj key=string(name);
    if (key) ((void(*)(Obj,Obj,Bool,Obj))objc_msgSend)((Obj)context,sel("setBool:forKey:"),0,key);
}
static int backup_originals(Obj defaults) {
    Obj backup_key=string("GlitchifyCompatibility.StockUI.OriginalPreferences.v1");
    if (!defaults || !backup_key) return 0;
    Obj existing=((Obj(*)(Obj,Obj,Obj))objc_msgSend)(defaults,sel("objectForKey:"),backup_key);
    if (existing) return 1;
    Obj original=get(objc_getClass("NSMutableDictionary"),"dictionary");
    if (!original) return 0;
    for (unsigned i=0;i<sizeof(stock_ui_keys)/sizeof(stock_ui_keys[0]);++i) {
        Obj key=string(stock_ui_keys[i]);
        if (!key) return 0;
        Obj value=((Obj(*)(Obj,Obj,Obj))objc_msgSend)(defaults,sel("objectForKey:"),key);
        /* Absent entries stay absent from the backup dictionary; an empty
         * dictionary is a valid completed backup. Explicit false is retained. */
        if (value) ((void(*)(Obj,Obj,Obj,Obj))objc_msgSend)(original,sel("setObject:forKey:"),value,key);
    }
    ((void(*)(Obj,Obj,Obj,Obj))objc_msgSend)(defaults,sel("setObject:forKey:"),original,backup_key);
    return 1;
}
static void migrate_stock_lyrics(Obj defaults) {
    Obj source_key=string("lyricsSource");
    Obj marker=string("GlitchifyCompatibility.StockLyrics.Migrated.v1");
    Obj backup_key=string("GlitchifyCompatibility.StockLyrics.OriginalPreference.v1");
    if (!defaults || !source_key || !marker || !backup_key) return;
    Obj marked=((Obj(*)(Obj,Obj,Obj))objc_msgSend)(defaults,sel("objectForKey:"),marker);
    if (marked) return;
    Obj source=((Obj(*)(Obj,Obj,Obj))objc_msgSend)(defaults,sel("objectForKey:"),source_key);
    Bool number=source && ((Bool(*)(Obj,Obj,Obj))objc_msgSend)(source,sel("isKindOfClass:"),objc_getClass("NSNumber"));
    double numeric=number ? ((double(*)(Obj,Obj))objc_msgSend)(source,sel("doubleValue")) : 0.0;
    enum LyricsDecision decision=lyrics_policy(1,0,source!=0,number,numeric);
    Obj existing=((Obj(*)(Obj,Obj,Obj))objc_msgSend)(defaults,sel("objectForKey:"),backup_key);
    if (!existing) {
        Obj backup=get(objc_getClass("NSMutableDictionary"),"dictionary");
        if (!backup) return;
        if (source) ((void(*)(Obj,Obj,Obj,Obj))objc_msgSend)(backup,sel("setObject:forKey:"),source,source_key);
        ((void(*)(Obj,Obj,Obj,Obj))objc_msgSend)(defaults,sel("setObject:forKey:"),backup,backup_key);
    }
    /* Eevee's supplied enum: genius0, lrclib1, musixmatch2, petit3, notReplaced4.
     * Unknown/malformed values and every explicit active source are preserved. */
    if (decision==LYRICS_LRCLIB)
        ((void(*)(Obj,Obj,long,Obj))objc_msgSend)(defaults,sel("setInteger:forKey:"),1,source_key);
    ((void(*)(Obj,Obj,Bool,Obj))objc_msgSend)(defaults,sel("setBool:forKey:"),1,marker);
}
__attribute__((constructor)) static void install_stock_ui(void) {
    Obj pool=get(objc_getClass("NSAutoreleasePool"),"new");
    Obj bundle=get(objc_getClass("NSBundle"),"mainBundle");
    Obj info=get(bundle,"infoDictionary");
    Obj executable=((Obj(*)(Obj,Obj,Obj))objc_msgSend)(info,sel("objectForKey:"),string("CFBundleExecutable"));
    Bool spotify=((Bool(*)(Obj,Obj,Obj))objc_msgSend)(executable,sel("isEqualToString:"),string("Spotify"));
    if (spotify) {
        Obj defaults=get(objc_getClass("NSUserDefaults"),"standardUserDefaults");
        if (backup_originals(defaults)) {
            apply_stock_ui(1,defaults,disable);
            migrate_stock_lyrics(defaults);
            NSLog(string("[GlitchifyStockUI] selected stock presentation before Chroma initialization"));
        }
    }
    ((void(*)(Obj,Obj))objc_msgSend)(pool,sel("drain"));
}
#else
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
typedef struct { unsigned writes; unsigned mask; } Capture;
static void capture(void *context,const char *key) {
    static const char *const expected[]={
        "spotifyglass.redesign", "spotifyglass.navbar", "spotifyglass.player",
        "spotifyglass.playerBackdrop", "spotifyglass.albumBackdrop",
        "spotifyglass.playlistBackdrop", "spotifyglass.homeGradient",
        "spotifyglass.artistPhotoFade", "spotifyglass.lyricsCard", "spotifyglass.amoled"
    };
    Capture *c=context;unsigned matched=0;
    assert(!strstr(key,"haptics") && !strstr(key,"Providers") && !strstr(key,"dsp") && !strstr(key,"stats"));
    assert(strcmp(key,"spotifyglass.stock") && strcmp(key,"patchType") && strcmp(key,"lyricsSource"));
    for (unsigned i=0;i<10;++i) if (!strcmp(key,expected[i])) {
        assert(!(c->mask&(1u<<i)));c->mask|=1u<<i;matched=1;
    }
    assert(matched);++c->writes;
}
int main(void) {
    Capture c={0,0};
    apply_stock_ui(0,&c,capture);assert(!c.writes);
    apply_stock_ui(1,0,capture);assert(!c.writes);
    apply_stock_ui(1,&c,0);assert(!c.writes);
    apply_stock_ui(1,&c,capture);assert(c.writes==10 && c.mask==1023);
    c=(Capture){0,0};apply_stock_ui(1,&c,capture);assert(c.writes==10 && c.mask==1023);
    assert(lyrics_policy(0,0,0,0,0)==LYRICS_SKIP);
    assert(lyrics_policy(1,1,1,1,4)==LYRICS_SKIP);
    assert(lyrics_policy(1,0,0,0,0)==LYRICS_LRCLIB);
    assert(lyrics_policy(1,0,1,1,4)==LYRICS_LRCLIB);
    for (int i=0;i<4;++i) assert(lyrics_policy(1,0,1,1,i)==LYRICS_PRESERVE);
    assert(lyrics_policy(1,0,1,0,4)==LYRICS_PRESERVE);
    assert(lyrics_policy(1,0,1,1,4.5)==LYRICS_PRESERVE);
    assert(lyrics_policy(1,0,1,1,-1)==LYRICS_PRESERVE);
    assert(lyrics_policy(1,0,1,1,NAN)==LYRICS_PRESERVE);
    assert(lyrics_policy(1,0,1,1,INFINITY)==LYRICS_PRESERVE);
    puts("PASS non-Spotify/nil guards; ten exact UI preferences only; no broad stock-default/haptics/DSP/stats writes; repeat-safe scope");
    puts("PASS one-time LyricsSource: missing/numeric4 to1; preserve0/1/2/3, unknown types, fractions, negatives, NaN/Infinity and prior migration");
}
#endif
