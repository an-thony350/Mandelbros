#include "fixed_mandelbrot.h"

#include <math.h>
#include <stddef.h>

fx_t d2fx(double x, int frac) {
    return (fx_t)(x * ldexp(1.0, frac));
}

fx_t fmul(fx_t a, fx_t b, int frac) {
    return (a * b) >> frac;
}

int iter_fx(fx_t cr, fx_t ci, int frac, int max_iter) {
    fx_t zr = 0, zi = 0;
    fx_t four = (fx_t)4 << frac;
    for (int i = 0; i < max_iter; i++) {
        fx_t zr2 = fmul(zr, zr, frac);
        fx_t zi2 = fmul(zi, zi, frac);
        if (zr2 + zi2 > four) return i;
        fx_t zri = fmul(zr, zi, frac);
        zi = (zri << 1) + ci;
        zr = zr2 - zi2 + cr;
    }
    return max_iter;
}

int iter_double(double cr, double ci, int max_iter) {
    double zr = 0.0, zi = 0.0;
    for (int i = 0; i < max_iter; i++) {
        double zr2 = zr * zr;
        double zi2 = zi * zi;
        if (zr2 + zi2 > 4.0) return i;
        double zri = zr * zi;
        zi = 2.0 * zri + ci;
        zr = zr2 - zi2 + cr;
    }
    return max_iter;
}

void render_image(int32_t *out,
                  double center_r, double center_i, double zoom,
                  int width, int height, int max_iter, int frac) {
    double view_w = 4.0 / zoom;
    double view_h = view_w * (double)height / (double)width;
    double x_min = center_r - view_w * 0.5;
    double y_min = center_i - view_h * 0.5;
    double dx = view_w / (double)width;
    double dy = view_h / (double)height;

    if (frac <= 0) {
        for (int py = 0; py < height; py++) {
            double ci = y_min + (double)py * dy;
            for (int px = 0; px < width; px++) {
                double cr = x_min + (double)px * dx;
                out[(size_t)py * width + px] = iter_double(cr, ci, max_iter);
            }
        }
    } else {
        for (int py = 0; py < height; py++) {
            double ci_d = y_min + (double)py * dy;
            fx_t ci = d2fx(ci_d, frac);
            for (int px = 0; px < width; px++) {
                double cr_d = x_min + (double)px * dx;
                fx_t cr = d2fx(cr_d, frac);
                out[(size_t)py * width + px] = iter_fx(cr, ci, frac, max_iter);
            }
        }
    }
}