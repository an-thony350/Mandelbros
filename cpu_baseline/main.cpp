#include "set_calculation.cpp"
#include <chrono>

// Defined Resolution sizes
#define ROW_NUM 1280
#define COL_NUM 720

// Used for timing constraints, this could be moved elswhere as a "timing" funct.
// But currently placed here

int main(){

    auto Start_Mandelbrot = std::chrono::high_resolution_clock::now();

    // temporary loop - pixel calculatons will occur here - theading possible

    for(int i = 0; i < ROW_NUM; i++){
        for(int j = 0; j < COL_NUM; j++){
            int Mandelbrot_iter = Mandelbrot_calculation(i/ROW_NUM,j/COL_NUM,256);
        }
    }

    auto End_Mandelbrot = std::chrono::high_resolution_clock::now();

    auto Mandelbrot_Time = std::chrono::duration_cast<std::chrono::seconds>(End_Mandelbrot - Start_Mandelbrot);
    
    std::cout << "Mandebrot Time: " << Mandelbrot_Time.count() << "s. \n";
}