#include "buttons.h"
#include "hardware/gpio.h"

/*
 * GPIO-to-bit mapping.
 * Index in this array = bit position in the returned bitmask.
 * Must stay in sync with §5.2 of the build guide and §2.2 pinout.
 */
static const uint8_t BTN_PINS[] = {
    6,   /* bit  0: NEXT      */
    7,   /* bit  1: BACK      */
    14,   /* bit  2: SELECT    */
    15,   /* bit  3: MODE      */
    10,  /* bit  4: PALETTE   */
    11,  /* bit  5: RESET     */
    2,   /* bit  6: ENC0_SW (zoom push) */
    5,   /* bit  7: ENC1_SW (iter push) */
    12,  /* bit  8: JOY_SW   */
};
#define NUM_BTNS ((int)(sizeof(BTN_PINS) / sizeof(BTN_PINS[0])))

/*
 * Vertical-counter debounce.
 *
 * For each button we track how many consecutive polls disagree with the
 * current recorded state.  When the disagreement streak reaches 5 (at
 * 1 kHz polling = 5 ms) we flip the recorded state and reset the counter.
 *
 * This correctly suppresses both contact bounce on press and release,
 * without adding unnecessary latency for clean presses.
 */
static uint8_t  counter[NUM_BTNS];
static uint16_t state = 0;  /* current debounced bitmask */

void buttons_init(void) {
    for (int i = 0; i < NUM_BTNS; i++) {
        gpio_init(BTN_PINS[i]);
        gpio_set_dir(BTN_PINS[i], GPIO_IN);
        gpio_pull_up(BTN_PINS[i]);
        counter[i] = 0;
    }
    state = 0;
}

void buttons_poll(void) {
    for (int i = 0; i < NUM_BTNS; i++) {
        /*
         * Buttons are active-LOW: pin reads 0 when the button is pressed
         * (pull-up + button shorts to GND).
         */
        bool pressed_raw       = !gpio_get(BTN_PINS[i]);
        bool currently_recorded = (state >> i) & 1u;

        if (pressed_raw == currently_recorded) {
            /* Raw reading agrees with recorded state → reset disagreement counter. */
            counter[i] = 0;
        } else {
            counter[i]++;
            if (counter[i] >= 5) {
                /* 5 ms of consistent disagreement → accept the new state. */
                state     ^= (uint16_t)(1u << i);
                counter[i] = 0;
            }
        }
    }
}

uint16_t buttons_get_state(void) {
    return state;
}
