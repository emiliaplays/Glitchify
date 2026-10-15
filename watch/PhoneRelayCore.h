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
typedef struct { double weight, sum[2]; } GRResampler;

static inline bool gr_write(GRRing *ring, int16_t value) {
    unsigned head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    unsigned tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if (head - tail >= GR_CAPACITY) return false;
    ring->samples[head % GR_CAPACITY] = value;
    atomic_store_explicit(&ring->head, head + 1, memory_order_release);
    return true;
}
// Publish an entire stereo frame together. Overflow cannot swap left and right.
static inline bool gr_write_stereo(GRRing *ring, int16_t left, int16_t right) {
    unsigned head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    unsigned tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if (head - tail > GR_CAPACITY - 2) return false;
    ring->samples[head % GR_CAPACITY] = left;
    ring->samples[(head + 1) % GR_CAPACITY] = right;
    atomic_store_explicit(&ring->head, head + 2, memory_order_release);
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
// Watch: 24 kHz downmixed mono. PC: 48 kHz stereo with channels kept separate.
// At 48 kHz, the PC path only converts sample representation, without resampling.
// Other input rates use a bounded box resampler; this is not a mastering filter.
// Caller has already validated the entire buffer with gp_measure.
static inline unsigned gr_convert(GRRing *ring, GRResampler *state, GPFormat f,
                                  const GPBuffer *buffers, unsigned frames, bool stereo) {
    if (f.rate < 24000 || f.rate > 192000 || !frames || frames > 8192) return 0;
    double width = f.rate / (stereo ? 48000.0 : 24000.0);
    unsigned dropped = 0;
    for (unsigned frame = 0; frame < frames; ++frame) {
        double values[2] = {gr_sample(f, buffers, frame, 0), 0};
        values[1] = f.channels == 2 ? gr_sample(f, buffers, frame, 1) : values[0];
        if (!stereo) values[0] = (values[0] + values[1]) * 0.5;
        double remaining = 1;
        while (remaining > 1e-9) {
            double take = fmin(remaining, width - state->weight);
            state->sum[0] += values[0] * take;
            state->sum[1] += values[1] * take;
            state->weight += take; remaining -= take;
            if (state->weight >= width - 1e-9) {
                int16_t left = (int16_t)(fmax(-1, fmin(1, state->sum[0] / width)) * 32767);
                int16_t right = (int16_t)(fmax(-1, fmin(1, state->sum[1] / width)) * 32767);
                if (stereo ? !gr_write_stereo(ring, left, right) : !gr_write(ring, left)) ++dropped;
                state->sum[0] = state->sum[1] = state->weight = 0;
            }
        }
    }
    return dropped;
}
#endif
