// Bit-exact ref
// Renders the Mandelbrot set into an iteration-count buffer using either
// IEEE double or a configurable Q(n).(frac) fixed-point representation.


#ifndef FIXED_MANDELBROT_H
#define FIXED_MANDELBROT_H

#include <stdint.h>

// Wide enough for any product of two values up to ~Q4.60.
typedef __int128 fx_t;

// Convert IEEE double to Q-format with `frac` fractional bits.
// Uses ldexp so values stay correct for frac > 52. 
fx_t d2fx(double x, int frac);

// Multiply two Q-format values, keeping the format. 
fx_t fmul(fx_t a, fx_t b, int frac);

// Iterate z = z^2 + c starting from z = 0.
// Returns the first iteration index at which |z|^2 > 4, or max_iter if the orbit never escapes.
int iter_fx(fx_t cr, fx_t ci, int frac, int max_iter);

int iter_double(double cr, double ci, int max_iter);

void render_image(int32_t *out,
                  double center_r, double center_i, double zoom,
                  int width, int height, int max_iter, int frac);

#endif 