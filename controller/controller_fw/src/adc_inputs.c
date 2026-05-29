#include "adc_inputs.h"
#include "pico/stdlib.h"
#include "hardware/adc.h"

/* ── Direct Joystick Pins ── */
#define ADC_PIN_X 26     /* GP26 is physical pin 31 (ADC Channel 0) */
#define ADC_CH_X  0
#define ADC_PIN_Y 27     /* GP27 is physical pin 32 (ADC Channel 1) */
#define ADC_CH_Y  1

/* ── Multiplexer Pins (For Potentiometers) ── */
#define MUX_A 18
#define MUX_B 19
#define ADC_MUX_PIN 28   /* GP28 is physical pin 34 (ADC Channel 2) */
#define ADC_MUX_CH  2

/* ── Raw Data Storage ── */
static uint16_t raw_jx = 0;
static uint16_t raw_jy = 0;
static uint16_t raw_pot0 = 0;
static uint16_t raw_pot1 = 0;

/* ── Center Calibration Storage ── */
static int16_t center_jx = 2048;
static int16_t center_jy = 2048;

void adc_inputs_init(void) {
    adc_init();
    
    // Initialize the three ADC pins
    adc_gpio_init(ADC_PIN_X);
    adc_gpio_init(ADC_PIN_Y);
    adc_gpio_init(ADC_MUX_PIN);

    // Initialize the Multiplexer digital control pins
    gpio_init(MUX_A);
    gpio_set_dir(MUX_A, GPIO_OUT);
    gpio_init(MUX_B);
    gpio_set_dir(MUX_B, GPIO_OUT);
}

void adc_inputs_sample(void) {
    /* 1. Read Direct Joystick X */
    adc_select_input(ADC_CH_X);
    raw_jx = adc_read();

    /* 2. Read Direct Joystick Y */
    adc_select_input(ADC_CH_Y);
    raw_jy = adc_read();

    /* 3. Switch ADC to the Multiplexer */
    adc_select_input(ADC_MUX_CH);

    // Assuming your potentiometers are still on Mux Channels 2 and 3
    // Read Pot 0: A=0, B=1 (Channel 2)
    gpio_put(MUX_A, 0);
    gpio_put(MUX_B, 1);
    sleep_us(5); 
    raw_pot0 = adc_read();

    // Read Pot 1: A=1, B=1 (Channel 3)
    gpio_put(MUX_A, 1);
    gpio_put(MUX_B, 1);
    sleep_us(5);
    raw_pot1 = adc_read();
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

uint16_t adc_pot0(void) {
    return raw_pot0;
}

uint16_t adc_pot1(void) {
    return raw_pot1;
}