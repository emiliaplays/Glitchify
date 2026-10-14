#ifndef GLITCHIFY_PHONE_RELAY_CORE_H
#define GLITCHIFY_PHONE_RELAY_CORE_H
#include "PhonePCMCore.h"
#include <stdatomic.h>

// One render producer and one network consumer. No allocation, locks or I/O.
#define GR_CAPACITY 65536u
typedef struct {
    atomic_uint head, tail;
    int16_t samples[GR_CAPACITY];
} GRRing;
typedef struct { double weight, sum; } GRResampler;

static inline bool gr_write(GRRing *ring, int16_t value) {
    unsigned head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    unsigned tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if (head - tail >= GR_CAPACITY) return false;
    ring->samples[head % GR_CAPACITY] = value;
    atomic_store_explicit(&ring->head, head + 1, memory_order_release);
    return true;
}
static inline unsigned gr_read(GRRing *ring, int16_t *out, unsigned maximum) {
    unsigned tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    unsigned head = atomic_load_explicit(&ring->head, memory_order_acquire);
    unsigned count = head - tail;
    if (count > maximum) count = maximum;
    for (unsigned i = 0; i < count; ++i) out[i] = ring->samples[(tail + i) % GR_CAPACITY];
    atomic_store_explicit(&ring->tail, tail + count, memory_order_release);
    return count;
}
static inline void gr_discard(GRRing *ring) { // consumer only
    unsigned head = atomic_load_explicit(&ring->head, memory_order_acquire);
    atomic_store_explicit(&ring->tail, head, memory_order_release);
}
// Recover from a delayed network consumer without blocking the render thread.
// Only the consumer moves tail; retaining recent samples bounds live latency.
static inline unsigned gr_trim(GRRing *ring, unsigned retain) {
    unsigned tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    unsigned head = atomic_load_explicit(&ring->head, memory_order_acquire);
    unsigned count = head - tail;
    unsigned skipped = count > retain ? count - retain : 0;
    if (skipped) atomic_store_explicit(&ring->tail, tail + skipped, memory_order_release);
    return skipped;
}
static inline float gr_sample(GPFormat f, const GPBuffer *buffers, unsigned frame, unsigned channel) {
    const unsigned char *p = buffers[f.planar ? channel : 0].data;
    unsigned index = f.planar ? frame : frame * f.channels + channel;
    if (f.floating) { float value; memcpy(&value, p + index * 4, 4); return value; }
    uint16_t bits = p[index * 2] | ((uint16_t)p[index * 2 + 1] << 8);
    return (float)(bits < 32768 ? bits : (int)bits - 65536) / 32768;
}
// Bounded box-filter downsampling to 24 kHz mono; preview quality, not hi-fi.
// Caller has already validated the entire buffer with gp_measure.
static inline unsigned gr_convert(GRRing *ring, GRResampler *state, GPFormat f,
                                  const GPBuffer *buffers, unsigned frames) {
    if (f.rate < 24000 || f.rate > 192000 || !frames || frames > 8192) return 0;
    double width = f.rate / 24000.0;
    unsigned dropped = 0;
    for (unsigned frame = 0; frame < frames; ++frame) {
        double value = 0;
        for (unsigned c = 0; c < f.channels; ++c) value += gr_sample(f, buffers, frame, c);
        value /= f.channels;
        double remaining = 1;
        while (remaining > 1e-9) {
            double take = fmin(remaining, width - state->weight);
            state->sum += value * take; state->weight += take; remaining -= take;
            if (state->weight >= width - 1e-9) {
                double sample = fmax(-1, fmin(1, state->sum / width));
                if (!gr_write(ring, (int16_t)(sample * 32767))) ++dropped;
                state->sum = 0; state->weight = 0;
            }
        }
    }
    return dropped;
}
#endif
