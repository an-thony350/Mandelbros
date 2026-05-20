#ifndef BUTTONS_H
#define BUTTONS_H
#include <stdint.h>

void buttons_init(void);
void buttons_poll(void);          // call at ~1 kHz
uint16_t buttons_get_state(void); // current debounced bitmask, 1 = pressed
#endif