#ifndef ENCODERS_H
#define ENCODERS_H
#include <stdint.h>

void encoders_init(void);

// Atomically reads accumulated delta since last call and clears it.
int32_t encoders_take_delta(int encoder_idx);

#endif