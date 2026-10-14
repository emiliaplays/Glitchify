/* Host-only tests: load supplied ARM64 Mach-O as inert data, never execute it. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#define REVERSE_BRIDGE_TEST 1
#include "reverse_bridge.c"

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static U8 *image,*pristine;
static size_t image_size;
static int region_status,region_prot,region_count,region_invalid;
static unsigned region_calls,protect_calls,deallocate_calls,log_count;
static int protect_results[4],protect_modes[4];
static int real_state,real_track,old_state=1,old_track=1;
static unsigned alias_queries,alternate_queries;
static char logs[16][128];
static int state_object,track_object,new_state_object,new_track_object,other_object;
U32 mach_task_self_=42;

Obj objc_getClass(const char *s) {
    if (!s) return 0;
    if (!strcmp(s,"SPTPlayerState")) return real_state ? &new_state_object : 0;
    if (!strcmp(s,"SPTPlayerTrack")) return real_track ? &new_track_object : 0;
    if (!strcmp(s,"SPTPlayerStateImplementation")) { ++alias_queries; return old_state ? &state_object : 0; }
    if (!strcmp(s,"SPTPlayerTrackImplementation")) { ++alias_queries; return old_track ? &track_object : 0; }
    return !strcmp(s,"ExistingUnrelatedClass") ? &other_object : 0;
}
static Obj alternate_lookup(const char *s) { ++alternate_queries; return objc_getClass(s); }
Obj sel_registerName(const char *s) { return (Obj)s; }
Obj objc_msgSend(Obj a,Obj b) { (void)a;(void)b; return 0; }
void NSLog(Obj a,...) { (void)a; }
void _dyld_register_func_for_add_image(void (*f)(const Header *,IPtr)) { (void)f; }
void reverse_test_log(const char *s) { if (log_count<16) snprintf(logs[log_count],128,"%s",s); ++log_count; }
int mach_vm_region(U32 task,U64 *address,U64 *size,int flavor,int *info,U32 *count,U32 *object) {
    CHECK(task==42 && flavor==9); ++region_calls;
    *address=((UPtr)image+target_slot)&~(UPtr)4095;
    *size=4096;
    if (region_invalid) *address=(UPtr)image+target_slot+8;
    *count=region_count; info[0]=region_prot; *object=27;
    return region_status;
}
int mach_port_deallocate(U32 task,U32 object) { CHECK(task==42 && object==27); ++deallocate_calls; return 0; }
int vm_protect(U32 task,UPtr address,UPtr size,int maximum,int protection) {
    CHECK(task==42 && address==(UPtr)image+target_slot && size==8 && maximum==0);
    CHECK(protect_calls<4); protect_modes[protect_calls]=protection;
    return protect_results[protect_calls++];
}
static void reset(void) {
    memcpy(image,pristine,image_size);
    *(Lookup *)(image+target_slot)=alternate_lookup;
    original_lookup=objc_getClass; installed=state_logged=state_missing=0;
#if REVERSE_ENABLE_TRACK_ALIAS
    track_logged=track_missing=0;
#endif
    region_status=region_invalid=0; region_prot=1; region_count=16;
    region_calls=protect_calls=deallocate_calls=log_count=0;
    real_state=real_track=0; old_state=old_track=1;
    alias_queries=alternate_queries=0;
    memset(protect_results,0,sizeof(protect_results)); memset(logs,0,sizeof(logs));
}
static Command *command(U32 wanted) {
    U8 *p=image+32; Header *h=(Header *)image;
    for (U32 i=0;i<h->ncmds;++i) { Command *c=(Command *)p; if (c->cmd==wanted) return c; p+=c->size; }
    return 0;
}
static Segment *segment(const char *name) {
    U8 *p=image+32; Header *h=(Header *)image;
    for (U32 i=0;i<h->ncmds;++i) { Command *c=(Command *)p; if (c->cmd==0x19 && bounded_same(((Segment *)c)->name,16,name)) return (Segment *)c; p+=c->size; }
    return 0;
}
static Section *got_section(void) {
    Segment *s=segment("__DATA_CONST"); CHECK(s);
    Section *sections=(Section *)((U8 *)s+72);
    for (U32 i=0;i<s->nsects;++i) if (bounded_same(sections[i].name,16,"__got")) return sections+i;
    CHECK(0); return 0;
}
static U8 *linkedit_file_pointer(U64 offset) {
    Segment *s=segment("__LINKEDIT"); CHECK(s);
    return image+s->vmaddr+offset-s->fileoff;
}
static void reject_without_writes(void) {
    CHECK(find_slot((Header *)image,(IPtr)image)==0);
    image_added((Header *)image,(IPtr)image);
    CHECK(!installed && !region_calls && !protect_calls);
    CHECK(*(Lookup *)(image+target_slot)==alternate_lookup);
}
static void load_image(const char *path) {
    FILE *f=fopen(path,"rb"); CHECK(f); CHECK(!fseek(f,0,SEEK_END));
    long length=ftell(f); CHECK(length>0); rewind(f);
    U8 *file=malloc((size_t)length); CHECK(file); CHECK(fread(file,1,(size_t)length,f)==(size_t)length); fclose(f);
    Header *h=(Header *)file; CHECK(h->magic==0xfeedfacf && h->sizeofcmds+32<(U64)length);
    U8 *p=file+32;
    for (U32 i=0;i<h->ncmds;++i) {
        Command *c=(Command *)p; CHECK(c->size>=8 && p+c->size<=file+32+h->sizeofcmds);
        if (c->cmd==0x19) { Segment *s=(Segment *)p; CHECK(s->vmaddr+s->vmsize<128*1024*1024); if(s->vmaddr+s->vmsize>image_size) image_size=s->vmaddr+s->vmsize; }
        p+=c->size;
    }
    image=calloc(1,image_size); pristine=calloc(1,image_size); CHECK(image && pristine);
    p=file+32;
    for (U32 i=0;i<h->ncmds;++i) {
        Command *c=(Command *)p;
        if(c->cmd==0x19) { Segment *s=(Segment *)p; CHECK(s->fileoff+s->filesize<=(U64)length && s->filesize<=s->vmsize); memcpy(pristine+s->vmaddr,file+s->fileoff,s->filesize); }
        p+=c->size;
    }
    free(file); reset(); CHECK(target_slot+8<=image_size);
}
int main(int argc,char **argv) {
    CHECK(argc==2); load_image(argv[1]);
    CHECK(find_slot((Header *)image,(IPtr)image)==(Lookup *)(image+target_slot));
    CHECK(find_slot(0,0)==0);
    printf("PASS real Chroma load-command/symbol metadata and slid slot identity\n");

    ((U8 *)command(0x1b))[8]^=1; reject_without_writes(); reset();
    Command *id=command(0xd); ((U8 *)id)[*(U32 *)((U8 *)id+8)]^=1; reject_without_writes(); reset();
    ((Header *)image)->cpu=0; reject_without_writes(); reset();
    ((Header *)image)->sizeofcmds--; reject_without_writes(); reset();
    ((Command *)(image+32))->size=0; reject_without_writes(); reset();
    got_section()->addr=target_slot+8; reject_without_writes(); reset();
    DynamicSymbols *ds=(DynamicSymbols *)command(0xb); Section *got=got_section();
    U32 *indices=(U32 *)linkedit_file_pointer(ds->fields[12]);
    U64 index=(target_slot-got->addr)/8+got->reserved1;
    indices[index]=0x80000000; reject_without_writes(); reset();
    ds=(DynamicSymbols *)command(0xb); got=got_section(); indices=(U32 *)linkedit_file_pointer(ds->fields[12]);
    index=(target_slot-got->addr)/8+got->reserved1;
    Symbols *sy=(Symbols *)command(0x2); Symbol *symbol=(Symbol *)linkedit_file_pointer(sy->symoff)+indices[index];
    linkedit_file_pointer(sy->stroff)[symbol->strx+1]='X'; reject_without_writes(); reset();
    printf("PASS UUID, install-name, CPU, command-boundary, GOT and symbol rejection\n");

    CHECK(compatible_lookup("SPTPlayerState")==&state_object);
    CHECK(compatible_lookup("SPTPlayerState")==&state_object && state_logged && log_count==1);
#if REVERSE_ENABLE_TRACK_ALIAS
    CHECK(compatible_lookup("SPTPlayerTrack")==&track_object);
#else
    CHECK(compatible_lookup("SPTPlayerTrack")==0);
#endif
    unsigned before=alias_queries;
    CHECK(compatible_lookup("SPTPlayerStateOther")==0 && compatible_lookup("sptplayerstate")==0);
    CHECK(compatible_lookup("ExistingUnrelatedClass")==&other_object && compatible_lookup(0)==0);
    CHECK(alias_queries==before);
    real_state=real_track=1;
    CHECK(compatible_lookup("SPTPlayerState")==&new_state_object);
    CHECK(compatible_lookup("SPTPlayerTrack")==&new_track_object && alias_queries==before);
    reset(); old_state=old_track=0;
    CHECK(compatible_lookup("SPTPlayerState")==0 && state_missing);
#if REVERSE_ENABLE_TRACK_ALIAS
    CHECK(compatible_lookup("SPTPlayerTrack")==0 && track_missing);
#endif
    printf("PASS exact-name aliases, missing fallback, logging once and real-class preference\n");

    reset(); U8 *snapshot=malloc(image_size); CHECK(snapshot); memcpy(snapshot,image,image_size);
    image_added((Header *)image,(IPtr)image);
    CHECK(installed && original_lookup==alternate_lookup && *(Lookup *)(image+target_slot)==compatible_lookup);
    CHECK(region_calls==1 && deallocate_calls==1 && protect_calls==2 && protect_modes[0]==19 && protect_modes[1]==1);
    CHECK(!memcmp(snapshot,image,target_slot) && !memcmp(snapshot+target_slot+8,image+target_slot+8,image_size-target_slot-8));
    CHECK(compatible_lookup("SPTPlayerState")==&state_object && alternate_queries==2);
    image_added((Header *)image,(IPtr)image); CHECK(protect_calls==2);
    free(snapshot);
    reset(); *(Lookup *)(image+target_slot)=0; image_added((Header *)image,(IPtr)image); CHECK(!installed && !protect_calls);
    reset(); *(Lookup *)(image+target_slot)=compatible_lookup; image_added((Header *)image,(IPtr)image); CHECK(!installed && !protect_calls);
    printf("PASS only one import slot changes, captured lookup forwards, install is idempotent\n");

    for (int mode=0;mode<5;++mode) {
        reset();
        if(mode==0)region_status=1;
        if(mode==1)region_prot=5;
        if(mode==2)region_prot=0;
        if(mode==3)region_count=1;
        if(mode==4)region_invalid=1;
        image_added((Header *)image,(IPtr)image);
        CHECK(!installed && !protect_calls && *(Lookup *)(image+target_slot)==alternate_lookup && deallocate_calls==1);
    }
    reset(); protect_results[0]=1; image_added((Header *)image,(IPtr)image);
    CHECK(!installed && protect_calls==1 && *(Lookup *)(image+target_slot)==alternate_lookup);
    reset(); protect_results[1]=1; image_added((Header *)image,(IPtr)image);
    CHECK(!installed && protect_calls==3 && *(Lookup *)(image+target_slot)==alternate_lookup);
    CHECK(strstr(logs[0],"rolled back"));
    reset(); protect_results[1]=protect_results[2]=1; image_added((Header *)image,(IPtr)image);
    CHECK(!installed && protect_calls==3 && *(Lookup *)(image+target_slot)==alternate_lookup);
    CHECK(log_count==2 && strstr(logs[0],"protection restore failed") && strstr(logs[1],"rolled back"));
    printf("PASS invalid/protected mappings, write denial and protection-restore rollback\n");
    printf("PASS %u assertions; no ARM64 code executed; track_alias=%d\n",checks,REVERSE_ENABLE_TRACK_ALIAS);
    free(image); free(pristine); return 0;
}
