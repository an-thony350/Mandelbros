#include <stdio.h>
#include "pico/stdlib.h"
#include "encoders.h"
#include "buttons.h"
#include "adc_inputs.h"
#include "crc8.h"

#define HEARTBEAT_LED 16
#define ERR_LED       17

int main(void) {
    stdio_init_all();  // brings up USB CDC
    encoders_init();
    buttons_init();
    adc_inputs_init();

    gpio_init(HEARTBEAT_LED); gpio_set_dir(HEARTBEAT_LED, GPIO_OUT);
    gpio_init(ERR_LED);       gpio_set_dir(ERR_LED, GPIO_OUT);

    // Auto-calibrate joystick after a brief settle.
    sleep_ms(200);
    for (int i = 0; i < 50; i++) { adc_inputs_sample(); sleep_ms(2); }
    adc_joy_calibrate();

    absolute_time_t next_poll   = make_timeout_time_ms(1);
    absolute_time_t next_packet = make_timeout_time_ms(10);
    absolute_time_t next_blink  = make_timeout_time_ms(500);
    uint16_t seq = 0;
    bool heartbeat = false;

    while (1) {
        absolute_time_t now = get_absolute_time();

        if (absolute_time_diff_us(now, next_poll) <= 0) {
            buttons_poll();
            adc_inputs_sample();
            next_poll = delayed_by_ms(next_poll, 1);
        }

        if (absolute_time_diff_us(now, next_blink) <= 0) {
            heartbeat = !heartbeat;
            gpio_put(HEARTBEAT_LED, heartbeat);
            next_blink = delayed_by_ms(next_blink, 500);
        }

        if (absolute_time_diff_us(now, next_packet) <= 0) {
            int32_t zoom_d = encoders_take_delta(0);
            int32_t iter_d = encoders_take_delta(1);
            uint16_t btn   = buttons_get_state();
            int16_t jx     = adc_joy_x();
            int16_t jy     = adc_joy_y();
            uint16_t k0    = adc_pot0();
            uint16_t k1    = adc_pot1();

            // Build payload (everything before the CRC).
            char payload[80];
            int n = snprintf(payload, sizeof(payload),
                "FSCP,%u,%04X,%+ld,%+ld,%d,%d,%u,%u",
                seq, btn, (long)zoom_d, (long)iter_d, jx, jy, k0, k1);

            uint8_t crc = crc8_ccitt((const uint8_t*)payload, (size_t)n);

            // Emit full line.
            printf("%s,%02X\n", payload, crc);
            seq++;
            next_packet = delayed_by_ms(next_packet, 10);
        }

        // Yield briefly so USB stack can run.
        sleep_us(50);
    }
}