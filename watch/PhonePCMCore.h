/* Bounded, read-only PCM signal measurements. No allocation or audio retention. */
#ifndef GLITCHIFY_PHONE_PCM_CORE_H
#define GLITCHIFY_PHONE_PCM_CORE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

typedef struct {
    double rate;
    uint32_t channels, bits, bytesPerFrame;
    bool floating, planar;
} GPFormat;
typedef struct { const void *data; uint32_t bytes, channels; } GPBuffer;

static inline bool gp_valid_format(GPFormat f) {
    return isfinite(f.rate) && f.rate >= 8000 && f.rate <= 192000
        && f.channels >= 1 && f.channels <= 2
        && ((f.floating && f.bits == 32) || (!f.floating && f.bits == 16))
        && f.bytesPerFrame == (f.bits / 8) * (f.planar ? 1 : f.channels);
}

/* Validate every buffer before reading. The caller must supply borrowed storage
 * valid for the callback's duration. Return false on unsupported/malformed PCM. */
static inline bool gp_measure(GPFormat f, const GPBuffer *buffers, uint32_t count,
                              uint32_t frames, uint32_t *peakMillionths) {
    if (!gp_valid_format(f) || !buffers || !peakMillionths || !frames || frames > 8192
        || count != (f.planar ? f.channels : 1)) return false;
    uint32_t channels = f.planar ? 1 : f.channels;
    uint32_t size = frames * channels * (f.bits / 8);
    for (uint32_t b = 0; b < count; ++b)
        if (!buffers[b].data || buffers[b].bytes < size || buffers[b].channels != channels) return false;
    float peak = 0;
    for (uint32_t b = 0; b < count; ++b) {
        const unsigned char *data = buffers[b].data;
        for (uint32_t i = 0; i < frames * channels; ++i) {
            float value;
            if (f.floating) {
                memcpy(&value, data + i * 4, 4);
                if (!isfinite(value) || fabsf(value) > 16) return false;
                value = fabsf(value);
            } else {
                uint16_t word = (uint16_t)data[i * 2] | ((uint16_t)data[i * 2 + 1] << 8);
                int32_t signedValue = word < 32768 ? word : (int32_t)word - 65536;
                value = (float)(signedValue < 0 ? -signedValue : signedValue) / 32768;
            }
            if (value > peak) peak = value;
        }
    }
    *peakMillionths = (uint32_t)(fminf(peak, 1) * 1000000);
    return true;
}
#endif
