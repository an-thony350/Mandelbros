// Command-line wrapper around render_image. 
// Writes raw int32 row-major iteration counts so numpy.fromfile can read directly.
#include "fixed_mandelbrot.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 9) {
        fprintf(stderr,
            "Usage: %s center_r center_i zoom width height max_iter frac_bits out_file\n"
            "  frac_bits <= 0 selects double-precision reference.\n",
            argv[0]);
        return 2;
    }

    double center_r = atof(argv[1]);
    double center_i = atof(argv[2]);
    double zoom     = atof(argv[3]);
    int    width    = atoi(argv[4]);
    int    height   = atoi(argv[5]);
    int    max_it   = atoi(argv[6]);
    int    frac     = atoi(argv[7]);
    const char *out = argv[8];

    if (width <= 0 || height <= 0 || max_it <= 0) {
        fprintf(stderr, "error: width, height, max_iter must be positive\n");
        return 2;
    }

    size_t n = (size_t)width * (size_t)height;
    int32_t *buf = (int32_t *)malloc(n * sizeof(int32_t));
    if (!buf) { perror("malloc"); return 1; }

    render_image(buf, center_r, center_i, zoom, width, height, max_it, frac);

    FILE *f = fopen(out, "wb");
    if (!f) { perror("fopen"); free(buf); return 1; }
    if (fwrite(buf, sizeof(int32_t), n, f) != n) {
        perror("fwrite"); fclose(f); free(buf); return 1;
    }
    fclose(f);
    free(buf);
    return 0;
}