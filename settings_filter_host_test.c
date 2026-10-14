#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#define SETTINGS_FILTER_TEST 1
#include "settings_filter.c"
int main(int argc,char **argv){
    assert(argc==2);FILE *f=fopen(argv[1],"rb");assert(f);assert(!fseek(f,0,SEEK_END));long length=ftell(f);assert(length>0x47a550);rewind(f);
    U8 *data=malloc((size_t)length);assert(data);assert(fread(data,1,(size_t)length,f)==(size_t)length);fclose(f);
    Header *h=(Header *)data;assert(valid_image(h));U32 saved=h->subtype;h->subtype=2;assert(!valid_image(h));h->subtype=saved;
    saved=h->ncmds;h->ncmds=257;assert(!valid_image(h));h->ncmds=saved;
    U8 *p=data+32;int saw_uuid=0,saw_code=0;
    for(U32 i=0;i<h->ncmds;++i){Command *c=(Command *)p;if(c->cmd==0x1b){p[8]^=1;assert(!valid_image(h));p[8]^=1;saw_uuid=1;}if(c->cmd==0x19){Segment *s=(Segment *)p;if(s->vmaddr<=0x153070&&0x153070-s->vmaddr<s->vmsize){int old=s->initprot;s->initprot=1;assert(!valid_image(h));s->initprot=old;saw_code=1;}}p+=c->size;}
    assert(saw_uuid&&saw_code&&valid_image(h));
    for(U32 i=0;i<10;++i)assert(disabled_key(disabled_keys[i]));
    const char *free_keys[]={"spotifyglass.haptics.music","spotifyglass.haptics.music.background","spotifyglass.lyricsProviders","lyricsSource","spotifyglass.liveActivity","spotifyglass.lockScreenLyrics","spotifyglass.playerBackdrop.extra",0};
    for(U32 i=0;i<sizeof(free_keys)/sizeof(free_keys[0]);++i)assert(!disabled_key(free_keys[i]));
    for(U32 i=0;i<sizeof(omitted_titles)/sizeof(omitted_titles[0]);++i)assert(omitted_title(omitted_titles[i]));
    const char *free_titles[]={"Lyrics","Vibrations","Live Activity","Privacy & clutter","Home & Library","Albums","Artists","Player","Reset",0};
    for(U32 i=0;i<sizeof(free_titles)/sizeof(free_titles[0]);++i)assert(!omitted_title(free_titles[i]));
    assert(!omit_policy(0,0,0,0,0,0,0)); /* ordinary free row retained */
    assert(omit_policy(1,0,0,0,0,0,0)); /* paid-marked row omitted */
    assert(!omit_policy(1,1,0,0,0,0,0)); /* cleanup remains reachable */
    assert(omit_policy(0,0,0,0,0,0,1)); /* feature-page paid context */
    assert(!omit_policy(0,1,0,0,0,0,1)); /* feature-page cleanup */
    assert(omit_policy(0,0,0,0,1,0,0)); /* dynamic account label irrelevant */
    assert(omit_policy(0,0,0,0,0,1,0)); /* disabled-UI dependency */
    assert(omit_policy(0,1,1,0,0,0,0)); /* disabled toggle stays hidden */
    assert(omit_policy(0,1,0,1,0,0,1)); /* Part of Plus CTA is cleanup-marked, still omitted */
    assert(outer_shape(1,0)&&outer_shape(1,256)); /* valid empty/all-empty outer array */
    assert(!outer_shape(0,0)&&!outer_shape(1,257)); /* malformed outer returns original */
    assert(inner_shape(1,0,0)&&inner_shape(1,0,4096)); /* empty section slot preserved */
    assert(!inner_shape(0,0,0)&&!inner_shape(1,2049,0)); /* malformed/large inner returns original */
    assert(inner_shape(1,2048,2048)&&!inner_shape(1,1,4096)); /* bounded combined count */
    assert(!same("Lyrics","lyrics")&&!same(0,"Lyrics"));
    free(data);puts("PASS: real Chroma UUID/CPU/code protection guards; exact disabled-key/title policy, free-feature and cleanup preservation, CTA exception, dynamic account identity, malformed/empty/oversized section policy. Objective-C runtime not executed.");return 0;
}
