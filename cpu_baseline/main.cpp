#include "set_calculation.cpp"
#include <chrono>
#include <thread>

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

    auto Start_Mandelbrot_NT = std::chrono::high_resolution_clock::now();
    std::cout << "Starting non-threaded time..." << std::endl;

    // temporary loop - pixel calculatons will occur here - theading possible
    
    
    for(int i = 0; i < ROW_NUM; i++){
        for(int j = 0; j < COL_NUM; j++){
            int Mandelbrot_iter = Mandelbrot_calculation(i/ROW_NUM,j/COL_NUM,256);
        }
    }

    std::cout << "Non-Threaded loop done. \nStarting threaded implemenation... \n";

    auto End_Mandelbrot_NT = std::chrono::high_resolution_clock::now();

    //Threading implementation
    // Look at this later (cleanup)


    std::thread first (Threaded_Mandel_iter,0,159);
    std::thread second (Threaded_Mandel_iter,160,319);
    std::thread third (Threaded_Mandel_iter,320,479);
    std::thread fourth (Threaded_Mandel_iter,480,639);
    std::thread fifth (Threaded_Mandel_iter,640,799);
    std::thread sixth (Threaded_Mandel_iter,800,959);
    std::thread seventh (Threaded_Mandel_iter,960,1119);
    std::thread eighth (Threaded_Mandel_iter,1120,1280);

    first.join();
    second.join();
    third.join();
    fourth.join();
    fifth.join();
    sixth.join();
    seventh.join();
    eighth.join();

    std::cout << "All threads joined... \n";

    auto End_Mandelbrot_T = std::chrono::high_resolution_clock::now();

    //Timing calculations
    
    auto Mandelbrot_Time_NT = std::chrono::duration<double>(End_Mandelbrot_NT - Start_Mandelbrot_NT);
    auto Mandelbrot_Time_T = std::chrono::duration<double>(End_Mandelbrot_T - End_Mandelbrot_NT);
    double multiple = (Mandelbrot_Time_T.count() > Mandelbrot_Time_NT.count()) ? Mandelbrot_Time_T.count()/Mandelbrot_Time_NT.count() : Mandelbrot_Time_NT.count()/Mandelbrot_Time_T.count();
    
    std::cout << "Both Loops Complete! \n";
    std::cout << "Time for non-threaded approach: " << Mandelbrot_Time_NT.count() << "s \n";
    std::cout << "Time for threaded approach: " << Mandelbrot_Time_T.count() << "s \n";

    std::cout << ((Mandelbrot_Time_T.count() < Mandelbrot_Time_NT.count()) ? "Threaded approach has a " : "Non Threaded approach has a ") << multiple << "x speedup \n";
}