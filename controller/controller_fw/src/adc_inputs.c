#include "adc_inputs.h"
#include "hardware/adc.h"
#include "hardware/gpio.h"

// IIR state, stored in 16.0 fixed-point (with extra fractional bits if you like).
static uint16_t filt[4] = {0};
static int16_t joy_centre_x = 2048;
static int16_t joy_centre_y = 2048;
#define DEADZONE 80   // ~4% of full scale

void adc_inputs_init(void) {
    adc_init();
    adc_gpio_init(26);  // joy X
    adc_gpio_init(27);  // joy Y
    adc_gpio_init(28);  // pot 0
    adc_gpio_init(29);  // pot 1
}

void adc_inputs_sample(void) {
    for (int ch = 0; ch < 4; ch++) {
        adc_select_input(ch);
        uint16_t raw = adc_read();   // 0..4095
        // IIR: filt = filt + (raw - filt) / 8
        filt[ch] = filt[ch] + ((int32_t)(raw - filt[ch]) >> 3);
    }
}

static int16_t apply_deadzone(int16_t v) {
    if (v > DEADZONE)  return v - DEADZONE;
    if (v < -DEADZONE) return v + DEADZONE;
    return 0;
}

int16_t adc_joy_x(void) {
    return apply_deadzone((int16_t)filt[0] - joy_centre_x);
}
int16_t adc_joy_y(void) {
    return apply_deadzone((int16_t)filt[1] - joy_centre_y);
}
uint16_t adc_pot0(void) { return filt[2]; }
uint16_t adc_pot1(void) { return filt[3]; }

void adc_joy_calibrate(void) {
    joy_centre_x = (int16_t)filt[0];
    joy_centre_y = (int16_t)filt[1];
}