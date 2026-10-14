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
    assert(gr_convert(&ring, &state, f, b, 441) == 0);
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
        assert(gr_convert(&ring, &state, f, one, 1) == 0);
    }
    assert(gr_read(&ring, out, 2400) == 240);
    for (unsigned i = 0; i < 240; ++i) assert(out[i] == 16383);
    puts("PASS: relay occupancy, overflow, index wrap, downmix, sample rate and fragmented conversion");
    puts("PASS: concurrent producer/consumer with bounded resynchronization");
}
