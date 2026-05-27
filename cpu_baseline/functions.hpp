#include "definitions.hpp"

// Global variables

extern int chosen_set;
extern double  z_real, z_imaginary;
extern std::vector<unsigned char> image;
extern int NUM_THREADS;
extern double zoom_factor, center_x, center_y;

// Fractal Calculation Functions

int Mandelbrot_calculation(double c_re, double c_im, int size);
int Julia_calculation(double c_re, double c_im, double z_re, double z_im, int size);
int Burning_Ship_calculation(double c_re, double c_im, int size);
int Tricorn_calculation(double c_re, double c_im, int size);

// Main Fractal Choice Functions

void choose_set();
std::string set_lookup();
int Chosen_Function(double c_re, double c_im, double z_re, double z_im);

// Colour Palette function

void palette(int iter, unsigned char& r, unsigned char& g, unsigned char& b);

// Pixel calculation

void Call_Calc(int start_row, int end_row);

// Image generation

void Generate_Image();

// Timing functions

double average(std::vector<double> v);