#include "buttons.h"
#include "hardware/gpio.h"

// Bit -> GPIO mapping, in order of button bit index.
static const uint8_t BTN_PINS[] = {
    6,   // bit 0: NEXT
    7,   // bit 1: BACK
    8,   // bit 2: SELECT
    9,   // bit 3: MODE
    10,  // bit 4: PALETTE
    11,  // bit 5: RESET
    2,   // bit 6: Enc0 push
    5,   // bit 7: Enc1 push
    12,  // bit 8: Joystick push
    13,  // bit 9: Spare 1
    14,  // bit 10: Spare 2
};
#define NUM_BTNS (sizeof(BTN_PINS) / sizeof(BTN_PINS[0]))

// Vertical-counter debounce: each button has a 3-bit counter that requires
// 5 consistent reads at 1 kHz = 5 ms to flip state.
static uint8_t counter[NUM_BTNS];
static uint16_t state = 0;

void buttons_init(void) {
    for (int i = 0; i < NUM_BTNS; i++) {
        gpio_init(BTN_PINS[i]);
        gpio_set_dir(BTN_PINS[i], GPIO_IN);
        gpio_pull_up(BTN_PINS[i]);
        counter[i] = 0;
    }
}

void buttons_poll(void) {
    for (int i = 0; i < NUM_BTNS; i++) {
        // Buttons are active-LOW (pull-up + button to GND).
        bool pressed_raw = !gpio_get(BTN_PINS[i]);
        bool currently_recorded = (state >> i) & 1;
        if (pressed_raw == currently_recorded) {
            counter[i] = 0;  // matches current state, no change
        } else {
            counter[i]++;
            if (counter[i] >= 5) {
                state ^= (1u << i);
                counter[i] = 0;
            }
        }
    }
}

uint16_t buttons_get_state(void) { return state; }