#include "definitions.hpp"


int chosen_set;
double  z_real, z_imaginary;
std::vector<std::pair<std::pair<double,double>, int>> map;
std::vector<unsigned char> image(ROW_NUM * COL_NUM * 3);


                   
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

void palette(int iter, unsigned char& r, unsigned char& g, unsigned char& b){
    if(iter == ITER_NUM){
        r = 0; 
        g = 0; 
        b = 0;
    }
    else{
        double gradient = (double)iter / (double)ITER_NUM;

        r = (unsigned char)(9* (1-gradient)* gradient * gradient * gradient * 255);
        g = (unsigned char)(15 * (1-gradient) * (1-gradient) * gradient * gradient * 255);
        b = (unsigned char)(8.5 * (1-gradient) * (1-gradient) * (1-gradient) * gradient * 255);
    }
}

double average(std::vector<double> v){
    double ans = 0;
    for(int i = 0; i < v.size(); i++){
        ans += v[i]/v.size();
    }
    return ans;
}

void Call_Calc(int start_row, int end_row){

    for(int row = start_row; row < end_row; row++){

        double c_im = (row - ROW_NUM / 2.0) * 4.0 / ROW_NUM;

        for(int col = 0; col < COL_NUM; col++){

            double c_re = (col - COL_NUM / 2.0) * 4.0 / COL_NUM;

            Chosen_Function(c_re, c_im, z_real, z_imaginary); // maybe change what ths returns
            
            unsigned char r, g, b;
            
            int iter = map.back().second;
            
            palette(iter, r, g, b);

            int index = (row * COL_NUM + col) * 3;
            image[index + 0] = r;
            image[index + 1] = g;
            image[index + 2] = b;
        }
    }
}

