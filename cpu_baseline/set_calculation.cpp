#include "definitions.hpp"

int chosen_set;
double  z_real, z_imaginary;
std::vector<std::pair<std::pair<double,double>, int>> map;

                   
std::pair<std::pair<double,double>, int>  Mandelbrot_calculation(double c_re, double c_im, int size){
    
    // Initial z values & iteration value
    double z_re = 0.0;
    double z_im = 0.0;
    int i = 0;

    // Mandelbrot Calc - Continues until instability is determined if less than size
    while((i < size) && ((z_re*z_re) + (z_im*z_im) <= 4)){
        
        double tmp_z_re = z_re;
        double tmp_z_im = z_im;

        z_re = (tmp_z_re*tmp_z_re) - (tmp_z_im*tmp_z_im) + c_re;
        z_im = 2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return { {c_re, c_im}, i};
}

int Julia_calculation(double c_re, double c_im, double z_re, double z_im, int size){

    // Initial values
    int i = 0;

    // Julia Calc

    while((i<size) && ((z_re*z_re) + (z_im*z_im) <= 4)){

        double tmp_z_re = z_re;
        double tmp_z_im = z_im; 

        z_re = (tmp_z_re*tmp_z_re) - (tmp_z_im*tmp_z_im) + c_re;
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

    while((i < size) && ((z_re*z_re) + (z_im*z_im) <= 4)){
        
        double tmp_z_re = std::abs(z_re);
        double tmp_z_im = std::abs(z_im);

        z_re = (tmp_z_re*tmp_z_re) - (tmp_z_im*tmp_z_im) + c_re;
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

    while((i < size) && ((z_re*z_re) + (z_im*z_im) <= 4)){
        
        double tmp_z_re = z_re;
        double tmp_z_im = -1*z_im;

        z_re = (tmp_z_re*tmp_z_re) - (tmp_z_im*tmp_z_im) + c_re;
        z_im = 2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return i;
}

/* 
May not be needed
void determine_range( currently left as this but will be changed later ){
    // Currently under assumption that calc occurs with range of +/- 2 on graphs

    row_start = -1*(ROW_NUM/4);
    row_end = ROW_NUM/4;
    col_start = COL_NUM/4;
    col_end = -1*(COL_NUM/4);
}
*/

void choose_set(){
    std::cout << "Choose which set to represent: \n";
    std::cout << "Mandelbrot: 0\n";
    std::cout << "Julia: 1\n";
    std::cout << "Burning Ship: 2\n";
    std::cout << "Tricorn: 3\n";
    std::cin >> chosen_set;

    if(chosen_set == 1){
        std::cout << "Choose the real value of c: \n";
        std::cin >> z_real;
        std::cout << "Choose the imaginary value of c: \n";
        std::cin >> z_imaginary;
    }
    return;
}

void Chosen_Function(double c_re, double c_im, double z_re, double z_im){
    switch(chosen_set){

    case Mandelbrot:
        map.push_back(Mandelbrot_calculation(c_re, c_im, ITER_NUM));
        break;
    case Julia:
        Julia_calculation(z_re, z_im, c_re, c_im, ITER_NUM); //swapped here for ease
        break;
    case Burning_Ship:
        Burning_Ship_calculation(c_re, c_im, ITER_NUM);
        break;
    case Tricorn:
        Tricorn_calculation(c_re, c_im, ITER_NUM);
        break;
    default:
         std::cout<<"Error incorrect input \n";
         return;
    }
}