#include "adc_inputs.h"
#include "pico/stdlib.h"
#include "hardware/adc.h"

/* ── Direct Joystick Pins ── */
#define ADC_PIN_X 26     /* GP26 is physical pin 31 (ADC Channel 0) */
#define ADC_CH_X  0
#define ADC_PIN_Y 27     /* GP27 is physical pin 32 (ADC Channel 1) */
#define ADC_CH_Y  1

/* ── Raw Data Storage ── */
static uint16_t raw_jx = 0;
static uint16_t raw_jy = 0;

/* ── Center Calibration Storage ── */
static int16_t center_jx = 2048;
static int16_t center_jy = 2048;

void adc_inputs_init(void) {
    adc_init();
    
    // Initialize the two ADC pins
    adc_gpio_init(ADC_PIN_X);
    adc_gpio_init(ADC_PIN_Y);
}

void adc_inputs_sample(void) {
    /* 1. Read Direct Joystick X */
    adc_select_input(ADC_CH_X);
    raw_jx = adc_read();

    /* 2. Read Direct Joystick Y */
    adc_select_input(ADC_CH_Y);
    raw_jy = adc_read();
}

void adc_joy_calibrate(void) {
    center_jx = raw_jx;
    center_jy = raw_jy;
}

int16_t adc_joy_x(void) {
    return (int16_t)raw_jx - center_jx;
}

int16_t adc_joy_y(void) {
    return (int16_t)raw_jy - center_jy;
}