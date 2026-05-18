#include "set_calculation.cpp"
#include <chrono>
#include <thread>
#include <vector>

// Defined Resolution sizes
#define ROW_NUM 1280
#define COL_NUM 720


// Threaded implementation
void Threaded_Mandel_iter(int start, int end){
    for(int i = start; i < end; i++){
        for(int j = 0; j < COL_NUM; j++){
            Mandelbrot_calculation(i/ROW_NUM, j/COL_NUM, 256);
        }
    }
}

// Used for timing constraints, this could be moved elswhere as a "timing" funct.
// But currently placed here

int main(){


    // Unoptimised loop version

    auto Start_Mandelbrot_NT = std::chrono::high_resolution_clock::now();
    std::cout << "Starting non-threaded time..." << std::endl;

    
    
    for(int i = 0; i < ROW_NUM; i++){
        for(int j = 0; j < COL_NUM; j++){
            int Mandelbrot_iter = Mandelbrot_calculation(i/ROW_NUM,j/COL_NUM,256);
        }
    }

    std::cout << "Non-Threaded loop done. \nStarting threaded implemenation... \n";

    auto End_Mandelbrot_NT = std::chrono::high_resolution_clock::now();

    // Threading implementation - using 16 threads

    std::vector<std::thread> threads;
    for(int i = 0; i < 16; i++){
        threads.push_back(std::thread(Threaded_Mandel_iter,80*i, 79 + 80*i));
    }

    for(int i = 0; i < 16; i++){
        threads[i].join();
    }

    std::cout << "All threads joined... \n";

    auto End_Mandelbrot_T = std::chrono::high_resolution_clock::now();

    // Timing calculations

    auto Mandelbrot_Time_NT = std::chrono::duration<double>(End_Mandelbrot_NT - Start_Mandelbrot_NT);
    auto Mandelbrot_Time_T = std::chrono::duration<double>(End_Mandelbrot_T - End_Mandelbrot_NT);
    double multiple = (Mandelbrot_Time_T.count() > Mandelbrot_Time_NT.count()) ? Mandelbrot_Time_T.count()/Mandelbrot_Time_NT.count() : Mandelbrot_Time_NT.count()/Mandelbrot_Time_T.count();
    
    std::cout << "Both Loops Complete! \n";
    std::cout << "Time for non-threaded approach: " << Mandelbrot_Time_NT.count() << "s \n";
    std::cout << "Time for threaded approach: " << Mandelbrot_Time_T.count() << "s \n";

    std::cout << ((Mandelbrot_Time_T.count() < Mandelbrot_Time_NT.count()) ? "Threaded approach has a " : "Non Threaded approach has a ") << multiple << "x speedup \n";
}