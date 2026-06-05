#include <stdio.h>
#include "pico/stdlib.h"
#include "encoders.h"
#include "buttons.h"
#include "adc_inputs.h"
#include "crc8.h"

/* ── LED GPIO assignments ────────────────────────────────── */
#define LED_GREEN  16   
#define LED_RED    17   

/* ── Timing constants ────────────────────────────────────── */
#define POLL_MS      1      
#define PACKET_MS   10      
#define BLINK_MS   500      

/* ── Auto-calibration & Gestures ─────────────────────────── */
#define SETTLE_MS      200
#define CALIB_SAMPLES   50
#define RECAL_MASK     ((1u << 5) | (1u << 6))
#define RECAL_HOLD_MS  1000

/* ── Fine/Coarse Multipliers ─────────────────────────────── */
#define MULT_ZOOM_FINE      1
#define MULT_ZOOM_COARSE   10
#define MULT_ITER_FINE      1
#define MULT_ITER_COARSE   10

/* ── Packet format ───────────────────────────────────────── */
/*
 * NEW Wire format (Pots removed):
 * FSCP,<seq>,<btn_hex>,<zoom_d>,<iter_d>,<jx>,<jy>,<crc>\n
 */
#define PAYLOAD_BUF 64   

/* ── Main ────────────────────────────────────────────────── */

int main(void) {
    stdio_init_all();

    encoders_init();
    buttons_init();
    adc_inputs_init();

    gpio_init(LED_GREEN); gpio_set_dir(LED_GREEN, GPIO_OUT); gpio_put(LED_GREEN, 0);
    gpio_init(LED_RED);   gpio_set_dir(LED_RED,   GPIO_OUT); gpio_put(LED_RED,   0);

    /* Power-up joystick calibration */
    sleep_ms(SETTLE_MS);
    for (int i = 0; i < CALIB_SAMPLES; i++) {
        adc_inputs_sample();
        sleep_ms(POLL_MS);
    }
    adc_joy_calibrate();

    /* Timing state */
    absolute_time_t next_poll   = make_timeout_time_ms(POLL_MS);
    absolute_time_t next_packet = make_timeout_time_ms(PACKET_MS);
    absolute_time_t next_blink  = make_timeout_time_ms(BLINK_MS);

    uint16_t seq       = 0;
    bool     heartbeat = false;
    uint32_t recal_held_ms = 0;

    /* Fine/Coarse State Tracking */
    bool zoom_coarse = false;
    bool iter_coarse = false;
    uint16_t prev_btn = 0; 

    while (true) {
        absolute_time_t now = get_absolute_time();

        /* ─ 1 kHz: poll buttons and sample ADC ─ */
        if (absolute_time_diff_us(now, next_poll) <= 0) {
            buttons_poll();
            adc_inputs_sample();
            next_poll = delayed_by_ms(next_poll, POLL_MS);

            uint16_t btn_now = buttons_get_state();
            if ((btn_now & RECAL_MASK) == RECAL_MASK) {
                recal_held_ms += POLL_MS;
                if (recal_held_ms == RECAL_HOLD_MS) {
                    adc_joy_calibrate();
                    gpio_put(LED_RED, 1);
                }
            } else {
                recal_held_ms = 0;
                gpio_put(LED_RED, 0);
            }
        }

        /* ─ 2 Hz: heartbeat LED ─ */
        if (absolute_time_diff_us(now, next_blink) <= 0) {
            heartbeat = !heartbeat;
            gpio_put(LED_GREEN, heartbeat);
            next_blink = delayed_by_ms(next_blink, BLINK_MS);
        }

        /* ─ 100 Hz: build and emit packet ─ */
        if (absolute_time_diff_us(now, next_packet) <= 0) {
            
            uint16_t btn = buttons_get_state();
            
            /* Edge Detection: Find buttons that were JUST pressed this cycle */
            uint16_t btn_pressed = btn & ~prev_btn;
            prev_btn = btn;

            /* Toggle coarse modes if the encoder switches (Bits 6 and 7) were just clicked */
            if (btn_pressed & (1u << 6)) zoom_coarse = !zoom_coarse;
            if (btn_pressed & (1u << 7)) iter_coarse = !iter_coarse;

            /* Grab raw detents and apply the current active multiplier */
            int32_t zoom_raw = encoders_take_delta(0);
            int32_t iter_raw = encoders_take_delta(1);
            
            int32_t zoom_d = zoom_raw * (zoom_coarse ? MULT_ZOOM_COARSE : MULT_ZOOM_FINE);
            int32_t iter_d = iter_raw * (iter_coarse ? MULT_ITER_COARSE : MULT_ITER_FINE);

            int16_t jx = adc_joy_x();
            int16_t jy = adc_joy_y();

            /* Build the shortened payload */
            char payload[PAYLOAD_BUF];
            int  n = snprintf(payload, sizeof(payload),
                "TDT,%u,%04X,%+ld,%+ld,%d,%d",
                (unsigned)seq,
                (unsigned)btn,
                (long)zoom_d,
                (long)iter_d,
                (int)jx,
                (int)jy);

            uint8_t crc = crc8_ccitt((const uint8_t *)payload, (size_t)n);

            /* Emit full line */
            printf("%s,%02X\n", payload, (unsigned)crc);

            seq++;
            next_packet = delayed_by_ms(next_packet, PACKET_MS);
        }

        /* Brief yield */
        sleep_us(50);
    }

    return 0;
}