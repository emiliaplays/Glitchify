#include "PhonePCMCore.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    GPFormat f = {48000, 2, 32, 4, true, true};
    float left[] = {0, .25f, -.5f, 0}, right[] = {0, 0, 0, .125f};
    GPBuffer b[] = {{left, sizeof(left), 1}, {right, sizeof(right), 1}};
    uint32_t peak = 0;
    assert(gp_measure(f, b, 2, 4, &peak) && peak == 500000);
    assert(!gp_measure(f, b, 1, 4, &peak));
    assert(!gp_measure(f, b, 2, 5, &peak));
    assert(!gp_measure(f, b, 2, 8193, &peak));
    assert(!gp_measure(f, b, 2, 0, &peak));
    b[1].data = NULL; assert(!gp_measure(f, b, 2, 4, &peak)); b[1].data = right;
    left[0] = NAN; assert(!gp_measure(f, b, 2, 4, &peak));
    left[0] = INFINITY; assert(!gp_measure(f, b, 2, 4, &peak));
    left[0] = 17; assert(!gp_measure(f, b, 2, 4, &peak)); left[0] = 0;
    GPFormat invalid = f; invalid.bytesPerFrame = 8; assert(!gp_valid_format(invalid));
    invalid = f; invalid.rate = NAN; assert(!gp_valid_format(invalid));
    invalid = f; invalid.channels = 3; assert(!gp_valid_format(invalid));
    invalid = f; invalid.bits = 24; assert(!gp_valid_format(invalid));
    GPFormat integer = {44100, 2, 16, 4, false, false};
    unsigned char pcm[] = {0, 0, 0, 0x80, 0xff, 0x7f, 0, 0};
    GPBuffer interleaved = {pcm, sizeof(pcm), 2};
    assert(gp_measure(integer, &interleaved, 1, 2, &peak) && peak == 1000000);
    assert(!gp_measure(integer, &interleaved, 1, 3, &peak));
    interleaved.channels = 1; assert(!gp_measure(integer, &interleaved, 1, 2, &peak));
    puts("PCM format, topology, finite-sample and bounds checks passed.");
    return 0;
}
