// relevant libs

#include <iostream>
#include <vector>
#include <chrono>
#include <cmath>
#include <thread>

// relevant defenitions

#define ROW_NUM 1280
#define COL_NUM 720
#define TOTAL_LOOPS 5
#define ITER_NUM 256
#define NUM_THREADS 16

// Enumerator for set choice

#define Mandelbrot 0
#define Julia 1
#define Burning_Ship 2
#define Tricorn 3


// Set and variables for calculation
// May not be necessary double row_start, row_end, col_start, col_end;