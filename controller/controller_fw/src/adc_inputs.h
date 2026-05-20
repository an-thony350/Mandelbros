#ifndef ADC_INPUTS_H
#define ADC_INPUTS_H
#include <stdint.h>

void adc_inputs_init(void);
void adc_inputs_sample(void);  // call at ~1 kHz

// Joystick: signed -2048..2047 (centre-zero).
int16_t adc_joy_x(void);
int16_t adc_joy_y(void);
// Pots: unsigned 0..4095.
uint16_t adc_pot0(void);
uint16_t adc_pot1(void);

// Calibration: call when user holds RESET to recentre joystick.
void adc_joy_calibrate(void);
#endif