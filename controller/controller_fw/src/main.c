#include <stdio.h>
#include "pico/stdlib.h"
#include "encoders.h"
#include "buttons.h"
#include "adc_inputs.h"
#include "crc8.h"

/* ── LED GPIO assignments (§2.2) ─────────────────────────── */
#define LED_GREEN  16   /* USB OK / heartbeat — 470 Ω to GND */
#define LED_RED    17   /* packet error indicator — 470 Ω to GND */

/* ── Timing constants ────────────────────────────────────── */
#define POLL_MS      1      /* buttons + ADC poll period          */
#define PACKET_MS   10      /* packet emission period (100 Hz)    */
#define BLINK_MS   500      /* heartbeat LED toggle period        */

/*
 * Auto-calibration on power-up:
 * - Wait SETTLE_MS for supply rails and joystick to reach steady state.
 * - Then run CALIB_SAMPLES × POLL_MS ms of IIR warmup before snapshotting.
 */
#define SETTLE_MS      200
#define CALIB_SAMPLES   50

/*
 * Manual recalibration gesture:
 * Hold RESET (bit 5) + ENC0_SW (bit 6) for RECAL_HOLD_MS to recalibrate.
 */
#define RECAL_MASK     ((1u << 5) | (1u << 6))
#define RECAL_HOLD_MS  1000

/* ── Packet format ───────────────────────────────────────── */
/*
 * Wire format (§5.1 of the build guide):
 *
 * FSCP,<seq>,<btn_hex>,<zoom_d>,<iter_d>,<jx>,<jy>,<knob0>,<knob1>,<crc>\n
 *
 * Fields:
 * FSCP        frame magic (drop line if absent)
 * seq         uint16, decimal, wraps 0..65535
 * btn_hex     uint16, 4-char hex, bitmask (§5.2)
 * zoom_d      int32, always printed with sign (+/-)
 * iter_d      int32, always printed with sign (+/-)
 * jx          int16, signed decimal, -2048..2047
 * jy          int16, signed decimal, -2048..2047
 * knob0       uint16, unsigned decimal, 0..4095
 * knob1       uint16, unsigned decimal, 0..4095
 * crc         uint8, 2-char hex, CRC8-CCITT over payload bytes
 *
 * Max line length ≈ 50 bytes.  At 100 Hz → 5 kB/s (≪ USB-FS budget).
 */
#define PAYLOAD_BUF 80   /* generous, actual max ~45 chars */

/* ── Main ────────────────────────────────────────────────── */

int main(void) {
    /* Bring up USB CDC (configured in CMakeLists.txt via pico_enable_stdio_usb). */
    stdio_init_all();

    /* Peripheral init. */
    encoders_init();
    buttons_init();
    adc_inputs_init();

    /* Status LEDs. */
    gpio_init(LED_GREEN); gpio_set_dir(LED_GREEN, GPIO_OUT); gpio_put(LED_GREEN, 0);
    gpio_init(LED_RED);   gpio_set_dir(LED_RED,   GPIO_OUT); gpio_put(LED_RED,   0);

    /* ── Power-up joystick calibration ── */
    sleep_ms(SETTLE_MS);
    for (int i = 0; i < CALIB_SAMPLES; i++) {
        adc_inputs_sample();
        sleep_ms(POLL_MS);
    }
    adc_joy_calibrate();

    /* ── Timing state ── */
    absolute_time_t next_poll   = make_timeout_time_ms(POLL_MS);
    absolute_time_t next_packet = make_timeout_time_ms(PACKET_MS);
    absolute_time_t next_blink  = make_timeout_time_ms(BLINK_MS);

    uint16_t seq       = 0;
    bool     heartbeat = false;

    /* Recalibration hold timer. */
    uint32_t recal_held_ms = 0;

    /* ── Main loop (Core 0 only; Core 1 unused) ── */
    while (true) {
        absolute_time_t now = get_absolute_time();

        /* ─ 1 kHz: poll buttons and sample ADC ─ */
        if (absolute_time_diff_us(now, next_poll) <= 0) {
            buttons_poll();
            adc_inputs_sample();
            next_poll = delayed_by_ms(next_poll, POLL_MS);

            /* Manual recalibration gesture: RESET + ENC0_SW held for 1 s. */
            uint16_t btn_now = buttons_get_state();
            if ((btn_now & RECAL_MASK) == RECAL_MASK) {
                recal_held_ms += POLL_MS;
                /* Only trigger the exact millisecond we hit the hold time */
                if (recal_held_ms == RECAL_HOLD_MS) {
                    adc_joy_calibrate();
                    /* Turn ON the Red LED to confirm calibration. */
                    gpio_put(LED_RED, 1);
                }
            } else {
                /* If either button is released, reset the timer and turn OFF the LED */
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
            int32_t  zoom_d = encoders_take_delta(0);
            int32_t  iter_d = encoders_take_delta(1);
            uint16_t btn    = buttons_get_state();
            int16_t  jx     = adc_joy_x();
            int16_t  jy     = adc_joy_y();
            uint16_t k0     = adc_pot0();
            uint16_t k1     = adc_pot1();

            /*
             * Build the payload portion (everything that the CRC covers).
             * The format string mirrors §5.1 exactly; both sides must agree.
             *
             * %u        seq  (decimal, wraps at 65535)
             * %04X      btn  (4-char hex, uppercase, zero-padded)
             * %+ld      zoom_d / iter_d  (always print sign)
             * %d        jx / jy  (signed decimal)
             * %u        k0 / k1  (unsigned decimal)
             */
            char payload[PAYLOAD_BUF];
            int  n = snprintf(payload, sizeof(payload),
                "FSCP,%u,%04X,%+ld,%+ld,%d,%d,%u,%u",
                (unsigned)seq,
                (unsigned)btn,
                (long)zoom_d,
                (long)iter_d,
                (int)jx,
                (int)jy,
                (unsigned)k0,
                (unsigned)k1);

            uint8_t crc = crc8_ccitt((const uint8_t *)payload, (size_t)n);

            /* Emit full line: payload + comma + 2-digit hex CRC + newline. */
            printf("%s,%02X\n", payload, (unsigned)crc);

            seq++;   /* wraps naturally at 65536 for a uint16_t, then → 0 */
            next_packet = delayed_by_ms(next_packet, PACKET_MS);
        }

        /*
         * Brief yield so TinyUSB can process its internal task queue.
         * Without this, USB throughput degrades under load.
         * 50 µs is negligible relative to our 1 ms poll tick.
         */
        sleep_us(50);
    }

    /* Unreachable. */
    return 0;
}