#ifndef GLITCHIFY_PHONE_CONTROL_PROTOCOL_H
#define GLITCHIFY_PHONE_CONTROL_PROTOCOL_H
#include <stddef.h>
#include <string.h>
#include <stdbool.h>
#include <ctype.h>
typedef enum { GCReject, GCStatus, GCPlay, GCPause, GCNext, GCPrevious } GCRequest;
static inline GCRequest gc_request(const void *raw, size_t size, const char *token) {
    if (!raw || !token || strlen(token) != 64 || size < 4 || size > 4096) return GCReject;
    const unsigned char *p = raw;
    for (size_t i = 0; i < size; ++i) if (p[i] < 32 && p[i] != '\r' && p[i] != '\n') return GCReject;
    if (memcmp(p + size - 4, "\r\n\r\n", 4)) return GCReject;
    char text[4097]; memcpy(text, raw, size); text[size] = 0;
    char *end = strstr(text, "\r\n"); if (!end) return GCReject; *end = 0;
    GCRequest route = GCReject;
    if (!strcmp(text, "GET /status HTTP/1.1")) route = GCStatus;
    if (!strcmp(text, "POST /play HTTP/1.1")) route = GCPlay;
    if (!strcmp(text, "POST /pause HTTP/1.1")) route = GCPause;
    if (!strcmp(text, "POST /next HTTP/1.1")) route = GCNext;
    if (!strcmp(text, "POST /previous HTTP/1.1")) route = GCPrevious;
    if (!route) return GCReject;
    bool authorized = false, lengthSeen = false;
    char *line = end + 2;
    while (*line && strncmp(line, "\r\n", 2)) {
        end = strstr(line, "\r\n"); if (!end) return GCReject; *end = 0;
        char *colon = strchr(line, ':'); if (!colon || colon == line) return GCReject;
        *colon = 0;
        for (char *n = line; *n; ++n) {
            if (!isalnum((unsigned char)*n) && *n != '-') return GCReject;
            *n = (char)tolower((unsigned char)*n);
        }
        char *value = colon + 1; while (*value == ' ') ++value;
        if (!strcmp(line, "transfer-encoding")) return GCReject;
        if (!strcmp(line, "content-length")) {
            if (lengthSeen || strcmp(value, "0")) return GCReject;
            lengthSeen = true;
        }
        if (!strcmp(line, "authorization")) {
            if (authorized || strlen(value) != 71 || memcmp(value, "Bearer ", 7)) return GCReject;
            unsigned different = 0;
            for (unsigned i = 0; i < 64; ++i) different |= (unsigned char)value[i+7] ^ (unsigned char)token[i];
            if (different) return GCReject;
            authorized = true;
        }
        line = end + 2;
    }
    // Exactly one empty terminal line; never accept an appended body/request.
    return authorized && (size_t)(line - text) == size - 2 ? route : GCReject;
}
#endif
