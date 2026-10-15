#include "PhoneRelayCore.h"
#include <assert.h>
#include <stdio.h>
#include <pthread.h>
#include <sched.h>
static GRRing threaded;
static void *produce(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < 200000; ++i) {
        while (!gr_write(&threaded, (int16_t)i)) sched_yield();
    }
    return NULL;
}
int main(void) {
    GRRing ring = {0};
    for (unsigned i = 0; i < GR_CAPACITY; ++i) assert(gr_write(&ring, (int16_t)i));
    assert(!gr_write(&ring, 1));
    int16_t out[2400];
    assert(gr_read(&ring, out, 2400) == 2400);
    for (unsigned i = 0; i < 2400; ++i) assert(out[i] == (int16_t)i);
    gr_discard(&ring); assert(gr_read(&ring, out, 1) == 0);
    // A delayed consumer resumes at recent audio, without changing the producer index.
    for (unsigned i = 0; i < 10000; ++i) assert(gr_write(&ring, (int16_t)i));
    unsigned priorHead = atomic_load(&ring.head);
    assert(gr_trim(&ring, 2400) == 7600);
    assert(atomic_load(&ring.head) == priorHead);
    assert(gr_trim(&ring, 2400) == 0);
    assert(gr_read(&ring, out, 2400) == 2400);
    for (unsigned i = 0; i < 2400; ++i) assert(out[i] == (int16_t)(7600 + i));
    // Index wrap preserves unsigned occupancy and ordering.
    atomic_store(&ring.head, UINT32_MAX - 2); atomic_store(&ring.tail, UINT32_MAX - 2);
    for (unsigned i = 0; i < 10; ++i) assert(gr_write(&ring, (int16_t)i));
    assert(gr_read(&ring, out, 20) == 10);
    for (unsigned i = 0; i < 10; ++i) assert(out[i] == (int16_t)i);
    atomic_store(&ring.head, UINT32_MAX - 2); atomic_store(&ring.tail, UINT32_MAX - 2);
    for (unsigned i = 0; i < 10; ++i) assert(gr_write(&ring, (int16_t)i));
    assert(gr_trim(&ring, 3) == 7);
    assert(gr_read(&ring, out, 20) == 3);
    assert(out[0] == 7 && out[2] == 9);
    float left[441], right[441];
    for (unsigned i = 0; i < 441; ++i) { left[i] = 0.75; right[i] = 0.25; }
    GPFormat f = {44100, 2, 32, 4, true, true};
    GPBuffer b[2] = {{left, sizeof left, 1}, {right, sizeof right, 1}};
    GRResampler state = {0};
    assert(gr_convert(&ring, &state, f, b, 441, false) == 0);
    assert(gr_read(&ring, out, 2400) == 240);
    for (unsigned i = 0; i < 240; ++i) assert(out[i] == 16383);
    // Concurrent production and consumer resynchronization preserve sample order.
    pthread_t worker;
    assert(pthread_create(&worker, NULL, produce, NULL) == 0);
    unsigned position = 0;
    while (position < 200000) {
        position += gr_trim(&threaded, 8192);
        unsigned count = gr_read(&threaded, out, 2400);
        for (unsigned i = 0; i < count; ++i) assert(out[i] == (int16_t)(position + i));
        position += count;
        if (!count) sched_yield();
    }
    assert(pthread_join(worker, NULL) == 0);
    // Fragmentation retains phase instead of resetting at callback boundaries.
    state = (GRResampler){0};
    for (unsigned i = 0; i < 441; ++i) {
        GPBuffer one[2] = {{&left[i], 4, 1}, {&right[i], 4, 1}};
        assert(gr_convert(&ring, &state, f, one, 1, false) == 0);
    }
    assert(gr_read(&ring, out, 2400) == 240);
    for (unsigned i = 0; i < 240; ++i) assert(out[i] == 16383);
    // Real 48 kHz source: duration and pitch must stay unchanged, L/R distinct.
    float stereo[960];
    for (unsigned i = 0; i < 480; ++i) {
        stereo[2*i] = 0.5f * sinf((float)(2 * 3.141592653589793 * 1000 * i / 48000));
        stereo[2*i+1] = -0.25f;
    }
    f = (GPFormat){48000, 2, 32, 8, true, false};
    GPBuffer interleaved[1] = {{stereo, sizeof stereo, 2}};
    state = (GRResampler){0};
    assert(gr_convert(&ring, &state, f, interleaved, 480, true) == 0);
    assert(gr_read(&ring, out, 2400) == 960); // exactly 10 ms, no rate drift
    unsigned crossings = 0;
    for (unsigned i = 0; i < 480; ++i) {
        assert(out[2*i] == (int16_t)(stereo[2*i] * 32767));
        assert(out[2*i+1] == -8191);
        if (i && out[2*i] > 0 && out[2*(i-1)] <= 0) ++crossings;
    }
    assert(crossings == 10); // 1 kHz, not 918.75 Hz from a 44.1/48 mix-up
    // 44.1 kHz planar source -> 48 kHz stereo; splitting callbacks retains phase.
    f = (GPFormat){44100, 2, 32, 4, true, true}; state = (GRResampler){0};
    for (unsigned i = 0; i < 441; ++i) {
        GPBuffer one[2] = {{&left[i], 4, 1}, {&right[i], 4, 1}};
        assert(gr_convert(&ring, &state, f, one, 1, true) == 0);
    }
    assert(gr_read(&ring, out, 2400) == 960);
    for (unsigned i = 0; i < 480; ++i) { assert(out[i*2] == 24575); assert(out[i*2+1] == 8191); }
    // One free sample slot is insufficient: never publish half a stereo frame.
    for (unsigned i = 0; i < GR_CAPACITY - 1; ++i) assert(gr_write(&ring, 1));
    priorHead = atomic_load(&ring.head);
    assert(!gr_write_stereo(&ring, 111, 222)); assert(atomic_load(&ring.head) == priorHead);
    gr_discard(&ring);
    // 48 -> 24 kHz Watch compatibility, two input frames per mono output frame.
    f = (GPFormat){48000, 2, 32, 8, true, false}; state = (GRResampler){0};
    assert(gr_convert(&ring, &state, f, interleaved, 480, false) == 0);
    assert(gr_read(&ring, out, 2400) == 240);
    puts("PASS: stereo separation, 48 kHz pitch/duration, fractional rate conversion, atomic stereo overflow, Watch mono compatibility");
    puts("PASS: relay occupancy, overflow, index wrap, downmix, sample rate and fragmented conversion");
    puts("PASS: concurrent producer/consumer with bounded resynchronization");
}
