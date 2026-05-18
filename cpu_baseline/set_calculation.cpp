#include <iostream>
#include <cmath>

                   
int Mandelbrot_calculation(double c_re, double c_im, int size){
    
    // Initial z values & iteration value
    double z_re = 0.0;
    double z_im = 0.0;
    int i = 0;

    // Mandelbrot Calc - Continues until instability is determined if less than size
    while((i < size) && (pow(z_re, 2) + pow(z_im,2) <= 4)){
        
        double tmp_z_re = z_re;
        double tmp_z_im = z_im;

        z_re = pow(tmp_z_re,2) - pow(tmp_z_im,2) + c_re;
        z_im = 2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return i;
}

int Julia_calculation(double c_re, double c_im, double z_re, double z_im, int size){

    // Initial values
    int i = 0;

    // Julia Calc

    while((i<size) && (pow(z_re,2) + pow(z_im,2) <= 4)){

        double tmp_z_re = z_re;
        double tmp_z_im = z_im; 

        z_re = pow(tmp_z_re,2) - pow(tmp_z_im,2) + c_re;
        z_im = 2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return i;
}

int Burning_Ship_calculation(double c_re, double c_im, int size){

    // Initial values
    double z_re = 0.0;
    double z_im = 0.0;
    int i = 0;

    while((i < size) && (pow(z_re, 2) + pow(z_im,2) <= 4)){
        
        double tmp_z_re = std::abs(z_re);
        double tmp_z_im = std::abs(z_im);

        z_re = pow(tmp_z_re,2) - pow(tmp_z_im,2) + c_re;
        z_im = -2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return i;
}

int Tricorn_calculation(double c_re, double c_im, int size){

    // Initial values
    double z_re = 0.0;
    double z_im = 0.0;
    int i = 0;

    while((i < size) && (pow(z_re, 2) + pow(z_im,2) <= 4)){
        
        double tmp_z_re = z_re;
        double tmp_z_im = -1*z_im;

        z_re = pow(tmp_z_re,2) - pow(tmp_z_im,2) + c_re;
        z_im = 2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return i;
}