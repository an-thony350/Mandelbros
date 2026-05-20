#include "encoders.h"
#include "hardware/gpio.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"

#define ENC0_A 0
#define ENC0_B 1
#define ENC1_A 3
#define ENC1_B 4

// State transition table.
// Index = (prev_state << 2) | curr_state.
// Value: +1 = CW step, -1 = CCW step, 0 = no change or bounce.
static const int8_t QDEC_TABLE[16] = {
     0, -1, +1,  0,
    +1,  0,  0, -1,
    -1,  0,  0, +1,
     0, +1, -1,  0,
};

static volatile int32_t accum[2] = {0, 0};
static volatile uint8_t prev_state[2] = {0, 0};

static void encoder_isr(uint gpio, uint32_t events) {
    int idx;
    uint a_pin, b_pin;
    if (gpio == ENC0_A || gpio == ENC0_B) { idx = 0; a_pin = ENC0_A; b_pin = ENC0_B; }
    else                                  { idx = 1; a_pin = ENC1_A; b_pin = ENC1_B; }

    uint8_t a = gpio_get(a_pin);
    uint8_t b = gpio_get(b_pin);
    uint8_t curr = (a << 1) | b;
    uint8_t idx_table = (prev_state[idx] << 2) | curr;
    int8_t step = QDEC_TABLE[idx_table];

    // EC11 encoders produce 4 quadrature transitions per detent.
    // Accumulate raw transitions; divide by 4 when reading (see below).
    accum[idx] += step;
    prev_state[idx] = curr;
}

void encoders_init(void) {
    const uint pins[] = {ENC0_A, ENC0_B, ENC1_A, ENC1_B};
    for (int i = 0; i < 4; i++) {
        gpio_init(pins[i]);
        gpio_set_dir(pins[i], GPIO_IN);
        gpio_pull_up(pins[i]);
    }
    prev_state[0] = (gpio_get(ENC0_A) << 1) | gpio_get(ENC0_B);
    prev_state[1] = (gpio_get(ENC1_A) << 1) | gpio_get(ENC1_B);

    gpio_set_irq_enabled_with_callback(ENC0_A,
        GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true, &encoder_isr);
    gpio_set_irq_enabled(ENC0_B, GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true);
    gpio_set_irq_enabled(ENC1_A, GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true);
    gpio_set_irq_enabled(ENC1_B, GPIO_IRQ_EDGE_RISE | GPIO_IRQ_EDGE_FALL, true);
}

int32_t encoders_take_delta(int idx) {
    uint32_t save = save_and_disable_interrupts();
    int32_t v = accum[idx];
    accum[idx] = 0;
    restore_interrupts(save);
    // EC11 = 4 transitions per detent. Report detents, not quarter-steps.
    return v / 4;
}