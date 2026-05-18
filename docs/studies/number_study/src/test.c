// Unit tests for fixed_mandelbrot. Tests the bits that the Verilator testbench will later depend on:
#include "fixed_mandelbrot.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int g_tests   = 0;
static int g_failed  = 0;

#define CHECK(cond, fmt, ...) do {                                          \
    g_tests++;                                                              \
    if (!(cond)) {                                                          \
        g_failed++;                                                         \
        fprintf(stderr, "FAIL %s:%d  " fmt "\n",                            \
                __FILE__, __LINE__, ##__VA_ARGS__);                         \
    }                                                                       \
} while (0)

#define CHECK_EQ_INT(a, b, label) do {                                      \
    long long _a = (long long)(a), _b = (long long)(b);                     \
    CHECK(_a == _b, "%s: got %lld, expected %lld", label, _a, _b);          \
} while (0)

#define CHECK_CLOSE_INT(a, b, tol, label) do {                              \
    long long _a = (long long)(a), _b = (long long)(b), _t = (long long)(tol); \
    long long _d = _a > _b ? _a - _b : _b - _a;                             \
    CHECK(_d <= _t,                                                         \
        "%s: got %lld, expected within %lld of %lld (diff %lld)",           \
        label, _a, _t, _b, _d);                                             \
} while (0)


// d2fx / fmul 

static void test_d2fx_basic(void) {
    // 1.0 in Q4.22 is 1<<22.
    CHECK_EQ_INT((long long)d2fx(1.0, 22), 1LL << 22, "d2fx(1.0, 22)");
    CHECK_EQ_INT((long long)d2fx(0.5, 22), 1LL << 21, "d2fx(0.5, 22)");
    CHECK_EQ_INT((long long)d2fx(-1.0, 22), -(1LL << 22), "d2fx(-1.0, 22)");
    // Zero is always zero
    CHECK_EQ_INT((long long)d2fx(0.0, 22), 0LL, "d2fx(0.0, 22)");
    // High-frac doesn't overflow because we use ldexp
    CHECK_EQ_INT((long long)d2fx(1.0, 56), 1LL << 56, "d2fx(1.0, 56)");
}

static void test_fmul_basic(void) {
    int F = 22;
    fx_t half   = d2fx(0.5, F);
    fx_t quarter = d2fx(0.25, F);
    fx_t one    = d2fx(1.0, F);
    fx_t two    = d2fx(2.0, F);

    CHECK_EQ_INT((long long)fmul(half, half, F), (long long)quarter, "0.5 * 0.5");

    CHECK_EQ_INT((long long)fmul(one, half, F), (long long)half, "1 * 0.5");

    CHECK_EQ_INT((long long)fmul(two, two, F), (long long)d2fx(4.0, F), "2 * 2");

    CHECK_EQ_INT((long long)fmul(-half, half, F), -(long long)quarter, "-0.5 * 0.5");
}


// Canonical Mandelbrot points

static void test_iter_known_points(void) {
    int F = 22;
    const int MI = 256;

    // never escapes.
    CHECK_EQ_INT(iter_fx(d2fx(0.0, F), d2fx(0.0, F), F, MI), MI,
                 "c=0 should hit max_iter");

    // never escapes.
    CHECK_EQ_INT(iter_fx(d2fx(-1.0, F), d2fx(0.0, F), F, MI), MI,
                 "c=-1 should hit max_iter");

    // orbit blows up immediately
    int n = iter_fx(d2fx(2.0, F), d2fx(0.0, F), F, MI);
    CHECK(n <= 2, "c=2 should escape within 2 iterations, got %d", n);
}

static void test_iter_fx_vs_double_q32(void) {
    int F = 32;
    int MI = 512;
    int W = 32, H = 32;
    int agree = 0, total = 0;
    for (int py = 0; py < H; py++) {
        double ci = -1.25 + 2.5 * py / (H - 1);
        for (int px = 0; px < W; px++) {
            double cr = -2.0 + 3.0 * px / (W - 1);
            int a = iter_double(cr, ci, MI);
            int b = iter_fx(d2fx(cr, F), d2fx(ci, F), F, MI);
            if (a == b) agree++;
            total++;
        }
    }
    double frac = (double)agree / total;
    CHECK(frac > 0.95,
          "iter_fx(Q4.32) vs iter_double agreement was %.3f (expected > 0.95)",
          frac);
}


// render_image 

static void test_render_image_smoke(void) {
    int W = 16, H = 16, MI = 64;
    int32_t buf[16 * 16];
    render_image(buf, -0.5, 0.0, 1.0, W, H, MI, 22);
    int seen_max = 0, seen_below_max = 0;
    for (int i = 0; i < W * H; i++) {
        CHECK(buf[i] >= 0 && buf[i] <= MI, "render_image out-of-range value");
        if (buf[i] == MI) seen_max = 1;
        if (buf[i] < MI) seen_below_max = 1;
    }
    CHECK(seen_max && seen_below_max,
          "render_image overview should produce both inside (=max_iter) and outside pixels");
}


int main(void) {
    test_d2fx_basic();
    test_fmul_basic();
    test_iter_known_points();
    test_iter_fx_vs_double_q32();
    test_render_image_smoke();

    printf("%d tests, %d failed\n", g_tests, g_failed);
    return g_failed == 0 ? 0 : 1;
}