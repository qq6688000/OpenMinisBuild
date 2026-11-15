/* Execute the production parser on bounded synthetic signature layouts. */
#include "NativeBuildMachOCore.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
static void le(unsigned char *p, uint32_t n) { for(int i=0;i<4;i++)p[i]=(unsigned char)(n>>(8*i)); }
static void be(unsigned char *p, uint32_t n) { for(int i=0;i<4;i++)p[i]=(unsigned char)(n>>(24-8*i)); }
static NBMachOInfo parse(unsigned char *b, size_t n) { NBMachOInfo r; NBMachOParse(b,n,&r); assert(r.valid); return r; }
int main(void) {
    unsigned char b[128]={0};
    le(b,0xfeedfacf); le(b+4,0x100000c); le(b+12,2); le(b+16,1); le(b+20,16);
    le(b+32,0x1d); le(b+36,16); le(b+40,48); le(b+44,80);
    unsigned char *s=b+48;
    be(s,0xfade0cc0); be(s+4,72); be(s+8,2);
    be(s+12,0); be(s+16,28); be(s+20,5); be(s+24,60);
    be(s+28,0xfade0c02); be(s+32,32); be(s+60,0xfade7171); be(s+64,12);
    NBMachOInfo r=parse(b,sizeof(b));
    assert(r.has_code_signature && r.signature_size==80 && r.signature_blobs==2 && r.code_directory_size==32);
    be(s+16,73); r=parse(b,sizeof(b)); assert(r.signature_blobs==0 && r.code_directory_size==0);
    be(s+16,28); be(s+4,81); r=parse(b,sizeof(b)); assert(r.signature_blobs==0);
    be(s+4,72); be(s+8,9); r=parse(b,sizeof(b)); assert(r.signature_blobs==0);
    be(s+8,2); be(s+64,13); r=parse(b,sizeof(b)); assert(r.signature_blobs==0);
    be(s+64,12); be(s+28,0xfade7171); r=parse(b,sizeof(b)); assert(r.signature_blobs==2 && r.code_directory_size==0);
    puts("PASS production parser: CodeDirectory differs from SuperBlob/padding; truncated indexes/offsets/lengths do not report valid layout");
    return 0;
}
