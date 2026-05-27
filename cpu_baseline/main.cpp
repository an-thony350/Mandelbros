#include "definitions.hpp"
#include "functions.cpp"
#include "timing_calculation.cpp"




// to be worked on

int main(){
 
        for(int i = 0; i < ROW_NUM; i++){
            for(int j = 0; j < COL_NUM; j++){
                int Mandelbrot_iter = Mandelbrot_calculation(i/ROW_NUM,j/COL_NUM,256);
            }
        }


        if (stbi_write_png("Mandelbrot.png", COL_NUM, ROW_NUM, 3, image.data(),  COL_NUM * 3)) {
        std::cout << "Success! Check your folder for the image." << std::endl;
    } else {
        std::cerr << "Failed to save the image." << std::endl;
    }
        

   // double multiple = (Mandelbrot_Avr_T < Mandelbrot_Avr_NT) ? Mandelbrot_Avr_NT/Mandelbrot_Avr_T : Mandelbrot_Avr_T/Mandelbrot_Avr_NT;

   // std::cout << ((Mandelbrot_Avr_T < Mandelbrot_Avr_NT) ? "Threaded approach has a " : "Non Threaded approach has a ") << multiple << "x speedup \n";
}