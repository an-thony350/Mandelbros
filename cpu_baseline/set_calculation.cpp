#include <iostream>
#include <cmath>

                   
int Mandelbrot_calculation(double c_re, double c_im, int size){
    
    // Initial z values & iteration value
    double z_re, z_im = 0;
    int i = 0;

    // Mandelbrot Calc - Continues until instability is determined if less than size
    while((i < size) & (pow(z_re, 2) + pow(z_im,2) <= 4)){
        
        double tmp_z_re = z_re;
        double tmp_z_im = z_im;

        z_re = pow(tmp_z_re,2) - pow(tmp_z_im,2) + c_re;
        z_im = 2*(tmp_z_re+tmp_z_im) + c_im;

        i++;
    }
    return i;
}