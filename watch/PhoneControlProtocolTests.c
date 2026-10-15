#include "PhoneControlProtocol.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    const char *key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *starts[] = {"GET /status", "POST /play", "POST /pause", "POST /next", "POST /previous"};
    char request[5000];
    for (unsigned i = 0; i < 5; ++i) {
        int n = snprintf(request, sizeof request, "%s HTTP/1.1\r\nHost: glitchify.local\r\nAuthorization: Bearer %s\r\nContent-Length: 0\r\n\r\n", starts[i], key);
        assert(gc_request(request, (size_t)n, key) == (GCRequest)(i+1));
        for (int j = 0; j < n; ++j) assert(gc_request(request, (size_t)j, key) == GCReject);
        request[n++] = 'x'; assert(gc_request(request, (size_t)n, key) == GCReject);
    }
    const char *invalid[] = {"GET /next", "POST /status", "DELETE /next", "POST /anything", "POST /next?token=a"};
    for (unsigned i=0; i<5; ++i) {
        int n=snprintf(request,sizeof request,"%s HTTP/1.1\r\nAuthorization: Bearer %s\r\n\r\n",invalid[i],key);
        assert(gc_request(request,(size_t)n,key)==GCReject);
    }
    const char *extras[] = {"Content-Length: 1\r\n", "Transfer-Encoding: chunked\r\n", "Content-Length: 0\r\nContent-Length: 0\r\n", "Authorization: Bearer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n"};
    for (unsigned i=0;i<4;++i) {
        int n=snprintf(request,sizeof request,"POST /next HTTP/1.1\r\nAuthorization: Bearer %s\r\n%s\r\n",key,extras[i]);
        assert(gc_request(request,(size_t)n,key)==GCReject);
    }
    int n=snprintf(request,sizeof request,"POST /next HTTP/1.1\r\nAuthorization: Bearer %s\r\n\r\n",key);
    request[50]='b'; assert(gc_request(request,(size_t)n,key)==GCReject);
    memset(request,'x',sizeof request); assert(gc_request(request,sizeof request,key)==GCReject);
    puts("PASS: authenticated control allowlist, strict verbs, truncation, invalid token, duplicate/framing/body rejection");
}
