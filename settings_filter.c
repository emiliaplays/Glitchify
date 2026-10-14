/* App-local settings cleanup for the requested stock UI. No feature/pass spoofing. */
typedef unsigned char U8;
typedef unsigned int U32;
typedef unsigned long long U64;
typedef unsigned long UPtr;
typedef void *Obj;
typedef void (*Imp)(void);
typedef struct {U32 magic,cpu,subtype,filetype,ncmds,sizeofcmds,flags,reserved;} Header;
typedef struct {U32 cmd,size;} Command;
typedef struct {U32 cmd,size;char name[16];U64 vmaddr,vmsize,fileoff,filesize;int maxprot,initprot;U32 nsects,flags;} Segment;
static const U8 expected_uuid[16]={0xd4,0xc7,0x5c,0x03,0xb9,0x0b,0x32,0x9d,0x83,0xb9,0x60,0xd7,0x68,0xcc,0x43,0xaa};
static int same(const char *a,const char *b){if(!a||!b)return 0;while(*a&&*a==*b){++a;++b;}return *a==*b;}
static const char *const disabled_keys[]={
 "spotifyglass.redesign","spotifyglass.navbar","spotifyglass.player","spotifyglass.playerBackdrop",
 "spotifyglass.albumBackdrop","spotifyglass.playlistBackdrop","spotifyglass.homeGradient",
 "spotifyglass.artistPhotoFade","spotifyglass.lyricsCard","spotifyglass.amoled"
};
static int disabled_key(const char *key){for(U32 i=0;i<10;++i)if(same(key,disabled_keys[i]))return 1;return 0;}
/* Only exact root entries: free Lyrics, Haptics, artwork and providers are retained. */
static const char *const omitted_titles[]={"Get Plus","Part of Plus","Workshop","Sing","Audio effects","Spatial voice","AutoMix","Listening stats","Appearance","Tab bar","Labs","All flags"};
static int omitted_title(const char *title){for(U32 i=0;i<sizeof(omitted_titles)/sizeof(omitted_titles[0]);++i)if(same(title,omitted_titles[i]))return 1;return 0;}
static int outer_shape(int is_array,UPtr sections){return is_array&&sections<=256;}
static int inner_shape(int is_array,UPtr rows,UPtr total){return is_array&&rows<=2048&&total<=4096-rows;}
static int omit_policy(int plus,int cleanup,int disabled,int title,int account,int dependent,int feature_page){
    return disabled || title || account || dependent || (!cleanup && (plus || feature_page));
}
static int valid_image(const Header *h){
    if(!h||h->magic!=0xfeedfacf||h->cpu!=0x100000c||h->subtype||h->filetype!=6||h->ncmds>256||h->sizeofcmds>65536)return 0;
    const U8 *p=(const U8 *)h+32,*end=p+h->sizeofcmds;U32 uuid=0,identity=0,covered=0;
    const U64 addresses[]={0x153070,0x4791f8,0x47a518};
    const char install[]="/Library/MobileSubstrate/DynamicLibraries/spotifyglass.dylib";
    for(U32 i=0;i<h->ncmds;++i){
        if((UPtr)(end-p)<8)return 0;
        const Command *c=(const Command *)p;if(c->size<8||c->size%8||c->size>(UPtr)(end-p))return 0;
        if(c->cmd==0x1b&&c->size==24){uuid=1;for(U32 j=0;j<16;++j)if(p[8+j]!=expected_uuid[j])uuid=0;}
        if(c->cmd==0xd&&c->size>=24){U32 off=*(const U32 *)(p+8);if(off>=24&&off<c->size){U32 j=0;while(j<sizeof(install)&&off+j<c->size&&p[off+j]==(U8)install[j])++j;identity=j==sizeof(install);}}
        if(c->cmd==0x19&&c->size>=72){
            const Segment *s=(const Segment *)p;if(s->nsects>(c->size-72)/80)return 0;
            if(s->initprot&1)for(U32 j=0;j<3;++j)if(s->vmsize>=32&&addresses[j]>=s->vmaddr&&addresses[j]-s->vmaddr<=s->vmsize-32&&(j!=0||(s->initprot&4)))covered|=1u<<j;
        }
        p+=c->size;
    }
    return p==end&&uuid&&identity&&covered==7;
}

#ifndef SETTINGS_FILTER_TEST
extern Obj objc_getClass(const char *);
extern Obj objc_msgSend(Obj,Obj);
extern Obj sel_registerName(const char *);
extern Obj objc_retain(Obj);
extern void objc_release(Obj);
extern Obj class_getInstanceMethod(Obj,Obj);
extern Obj class_getSuperclass(Obj);
extern const char *method_getTypeEncoding(Obj);
extern Imp method_getImplementation(Obj);
extern Imp method_setImplementation(Obj,Imp);
extern U8 class_addMethod(Obj,Obj,Imp,const char *);
extern U32 _dyld_image_count(void);
extern const Header *_dyld_get_image_header(U32);
extern long _dyld_get_image_vmaddr_slide(U32);
extern char _dispatch_main_q[];
extern void dispatch_async_f(void *,void *,void (*)(void *));
extern void NSLog(Obj,...);
static Imp original_rows;
static UPtr image_slide;
static Obj row_class,array_class,string_class;
static int installed;
static Obj sel(const char *s){return sel_registerName(s);}
static Obj get(Obj x,const char *s){return objc_msgSend(x,sel(s));}
static U8 boolean(Obj x,const char *s){return ((U8(*)(Obj,Obj))objc_msgSend)(x,sel(s));}
static U8 kind(Obj value,Obj cls){return value&&cls&&((U8(*)(Obj,Obj,Obj))objc_msgSend)(value,sel("isKindOfClass:"),cls);}
static const char *text(Obj value){return kind(value,string_class)?((const char *(*)(Obj,Obj))objc_msgSend)(value,sel("UTF8String")):0;}
static UPtr count(Obj value){return ((UPtr(*)(Obj,Obj))objc_msgSend)(value,sel("count"));}
static Obj item(Obj array,UPtr index){return ((Obj(*)(Obj,Obj,UPtr))objc_msgSend)(array,sel("objectAtIndex:"),index);}
static Obj array(UPtr capacity){return ((Obj(*)(Obj,Obj,UPtr))objc_msgSend)(objc_getClass("NSMutableArray"),sel("arrayWithCapacity:"),capacity);}
static void add(Obj array_value,Obj value){((void(*)(Obj,Obj,Obj))objc_msgSend)(array_value,sel("addObject:"),value);}
static int exact_method(Obj cls,const char *name,const char *types){Obj m=class_getInstanceMethod(cls,sel(name));return m&&same(method_getTypeEncoding(m),types);}
static int dependent_ui(Obj row){
    Obj need=get(row,"needs");
    for(U32 depth=0;need&&depth<16;++depth){
        if(!kind(need,row_class))return 0;
        if(disabled_key(text(get(need,"key")))||boolean(need,"plus"))return 1;
        need=get(need,"needs");
    }
    return 0;
}
static int omit_row(Obj row,int feature_page){
    if(!kind(row,row_class))return 0;
    Obj page=get(row,"page"),action=get(row,"action");
    int account=(UPtr)page==image_slide+0x4791f8||(UPtr)action==image_slide+0x47a518;
    return omit_policy(boolean(row,"plus"),boolean(row,"cleanup"),disabled_key(text(get(row,"key"))),
        omitted_title(text(get(row,"title"))),account,dependent_ui(row),feature_page);
}
static Obj rows(Obj self,Obj command){
    Obj original=((Obj(*)(Obj,Obj))original_rows)(self,command);
    int is_array=kind(original,array_class);UPtr sections=is_array?count(original):0;
    if(!outer_shape(is_array,sections))return original;
    UPtr total=0;
    for(UPtr i=0;i<sections;++i){Obj group=item(original,i);int group_array=kind(group,array_class);UPtr n=group_array?count(group):0;if(!inner_shape(group_array,n,total))return original;total+=n;}
    /* Ownership: original remains in its caller's autorelease scope. Output and
       nested arrays are autoreleased, then retained normally by Chroma adopt:. */
    objc_retain(original);
    Obj output=array(sections);if(!output){objc_release(original);return original;}
    int changed=0,feature_page=get(self,"plusFeature")!=0;
    for(UPtr i=0;i<sections;++i){
        Obj group=item(original,i);UPtr n=count(group);Obj kept=array(n);
        if(!kept){objc_release(original);return original;}
        for(UPtr j=0;j<n;++j){Obj row=item(group,j);if(omit_row(row,feature_page)){changed=1;}else add(kept,row);}
        add(output,kept); /* Keep empty sections to preserve header/footer indexes. */
    }
    objc_release(original);
    return changed?output:original;
}
static void install(void *unused){
    (void)unused;if(installed)return;
    Obj cls=objc_getClass("SGModPage"),row=objc_getClass("SGModRow");if(!cls||!row)return;
    if(!exact_method(cls,"rowsToShow","@16@0:8")||!exact_method(cls,"plusFeature","@16@0:8"))return;
    const char *names[]={"title","key","needs","page","action","plus","cleanup"};
    const char *types[]={"@16@0:8","@16@0:8","@16@0:8","@?16@0:8","@?16@0:8","B16@0:8","B16@0:8"};
    for(U32 i=0;i<7;++i)if(!exact_method(row,names[i],types[i]))return;
    Obj method=class_getInstanceMethod(cls,sel("rowsToShow"));Imp current=method_getImplementation(method);int found=0;
    U32 n=_dyld_image_count();if(n>4096)return;
    for(U32 i=0;i<n;++i){const Header *h=_dyld_get_image_header(i);if(valid_image(h)){UPtr candidate=(UPtr)_dyld_get_image_vmaddr_slide(i);if((UPtr)current==candidate+0x153070){image_slide=candidate;found=1;break;}}}
    if(!found)return;
    row_class=row;array_class=objc_getClass("NSArray");string_class=objc_getClass("NSString");if(!array_class||!string_class)return;
    original_rows=current;
    if(!class_addMethod(cls,sel("rowsToShow"),(Imp)rows,method_getTypeEncoding(method))){
        Obj local=class_getInstanceMethod(cls,sel("rowsToShow")),parent=class_getSuperclass(cls);
        if(!local||(parent&&local==class_getInstanceMethod(parent,sel("rowsToShow")))||!same(method_getTypeEncoding(local),"@16@0:8"))return;
        original_rows=method_setImplementation(local,(Imp)rows);
    }
    installed=1;
    Obj message=((Obj(*)(Obj,Obj,const char *))objc_msgSend)(string_class,sel("stringWithUTF8String:"),"[GlitchifySettings] stock UI and unavailable paid entries filtered");
    if(message)NSLog(message);
}
__attribute__((constructor))static void start(void){
    Obj pool=get(objc_getClass("NSAutoreleasePool"),"new");
    install(0);((void(*)(Obj,Obj))objc_msgSend)(pool,sel("drain"));
    if(!installed)dispatch_async_f(_dispatch_main_q,0,install);
}
#endif
