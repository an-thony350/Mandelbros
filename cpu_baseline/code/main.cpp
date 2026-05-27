#include "definitions.hpp"
#include "set_calculation.cpp"
#include "timing_calculation.cpp"


// Threaded implementation
void Threaded_Mandel_iter(int start, int end){
    for(int i = start; i < end; i++){
        for(int j = 0; j < COL_NUM; j++){
            Mandelbrot_calculation(i/ROW_NUM, j/COL_NUM, 256);
        }
    }
}

// to be worked on

int main(){
 
        for(int i = 0; i < ROW_NUM; i++){
            for(int j = 0; j < COL_NUM; j++){
                int Mandelbrot_iter = Mandelbrot_calculation(i/ROW_NUM,j/COL_NUM,256);
            }
        }


        

   // double multiple = (Mandelbrot_Avr_T < Mandelbrot_Avr_NT) ? Mandelbrot_Avr_NT/Mandelbrot_Avr_T : Mandelbrot_Avr_T/Mandelbrot_Avr_NT;

   // std::cout << ((Mandelbrot_Avr_T < Mandelbrot_Avr_NT) ? "Threaded approach has a " : "Non Threaded approach has a ") << multiple << "x speedup \n";
}