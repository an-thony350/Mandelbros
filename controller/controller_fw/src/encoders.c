#include "encoders.h"
#include "hardware/gpio.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"

/* ── Pin assignments (must match §2.2 of the build guide) ── */
#define ENC0_A  0   /* GP0  – Zoom encoder, channel A */
#define ENC0_B  1   /* GP1  – Zoom encoder, channel B */
#define ENC1_A  3   /* GP3  – Iter encoder, channel A */
#define ENC1_B  4   /* GP4  – Iter encoder, channel B */

/*
 * Quadrature decode lookup table.
 *
 * Index = (prev_AB << 2) | curr_AB   (4 bits total → 16 entries).
 * Value:
 *   +1  valid clockwise step
 *   -1  valid counter-clockwise step
 *    0  no change or mechanical bounce (treat as noise)
 *
 * AB is encoded as (A << 1) | B, matching the GPIO read order.
 */
static const int8_t QDEC_TABLE[16] = {
     0, -1, +1,  0,   /* prev=00: 00→ no move, 01→CCW, 10→CW, 11→invalid */
    +1,  0,  0, -1,   /* prev=01 */
    -1,  0,  0, +1,   /* prev=10 */
     0, +1, -1,  0,   /* prev=11 */
};

/*
 * Raw quadrature transition accumulators (written in ISR, read in main loop).
 * Declared volatile; access protected with save_and_disable_interrupts().
 */
static volatile int32_t accum[2]      = {0, 0};
static volatile uint8_t prev_state[2] = {0, 0};

/* ── ISR ──────────────────────────────────────────────────── */

/*
 * Single callback for all four encoder pins.
 * The SDK routes all GPIO IRQs through one callback; we demux on `gpio`.
 */
static void encoder_isr(uint gpio, uint32_t events) {
    (void)events;   /* we re-read the pin state directly */

    int    idx;
    uint   a_pin, b_pin;

    if (gpio == ENC0_A || gpio == ENC0_B) {
        idx = 0; a_pin = ENC0_A; b_pin = ENC0_B;
    } else {
        idx = 1; a_pin = ENC1_A; b_pin = ENC1_B;
    }

    uint8_t a    = gpio_get(a_pin);
    uint8_t b    = gpio_get(b_pin);
    uint8_t curr = (a << 1) | b;

    uint8_t tbl_idx = (prev_state[idx] << 2) | curr;
    int8_t  step    = QDEC_TABLE[tbl_idx];

    /*
     * Accumulate raw transitions.
     * EC11 = 4 transitions per detent; encoders_take_delta() divides by 4
     * before returning the detent count to callers.
     */
    accum[idx]      += step;
    prev_state[idx]  = curr;
}

/* ── Public API ───────────────────────────────────────────── */

void encoders_init(void) {
    const uint pins[] = {ENC0_A, ENC0_B, ENC1_A, ENC1_B};

    for (int i = 0; i < 4; i++) {
        gpio_init(pins[i]);
        gpio_set_dir(pins[i], GPIO_IN);
        gpio_pull_up(pins[i]);
    }

    /* Seed initial state so the first ISR call has valid prev_state. */
    prev_state[0] = (uint8_t)((gpio_get(ENC0_A) << 1) | gpio_get(ENC0_B));
    prev_state[1] = (uint8_t)((gpio_get(ENC1_A) << 1) | gpio_get(ENC1_B));

    /*
     * Register the shared callback once, then enable IRQs on the
     * remaining pins without re-registering (SDK requirement).
     */
    gpio_set_irq_enabled_with_callback(ENC0_A,
        GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true, &encoder_isr);
    gpio_set_irq_enabled(ENC0_B, GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true);
    gpio_set_irq_enabled(ENC1_A, GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true);
    gpio_set_irq_enabled(ENC1_B, GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true);
}

int32_t encoders_take_delta(int idx) {
    uint32_t save = save_and_disable_interrupts();
    
    /* 1. Read the raw accumulated transitions */
    int32_t  v = accum[idx];
    
    /* 2. Calculate how many full detents (groups of 4) have occurred */
    int32_t detents = v / 4;
    
    /* 3. ONLY subtract the transitions we are actually returning.
          This leaves any incomplete 1, 2, or 3 step remainders safely in the accumulator! */
    accum[idx] -= (detents * 4);
    
    restore_interrupts(save);

    /*
     * Troubleshooting:
     * Reports 2x expected -> encoder is 2-transition type -> change the two 4s above to 2s
     * Wrong sign          -> swap ENC_A / ENC_B #defines at the top of the file
     */
    return detents;
}
