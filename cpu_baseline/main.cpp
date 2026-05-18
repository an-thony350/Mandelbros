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

double average(std::vector<double> v){
    double ans = 0;
    for(int i = 0; i < v.size(); i++){
        ans += v[i]/v.size();
    }
    return ans;
}

// Used for timing constraints, this could be moved elswhere as a "timing" funct.
// But currently placed here

int main(){


    std::vector<double> Mandelbrot_Times_NT, Mandelbrot_Times_T;

    for(int i = 0; i < 10; i++){

        std::cout << "Loop " << i + 1 << " started...\n";

        // Unoptimised loop version
        auto Start_Mandelbrot_NT = std::chrono::high_resolution_clock::now();
 
        for(int i = 0; i < ROW_NUM; i++){
            for(int j = 0; j < COL_NUM; j++){
                int Mandelbrot_iter = Mandelbrot_calculation(i/ROW_NUM,j/COL_NUM,256);
            }
        }

        auto End_Mandelbrot_NT = std::chrono::high_resolution_clock::now();

        // Threading implementation - using 16 threads

        std::vector<std::thread> threads;
        for(int i = 0; i < 16; i++){
            threads.push_back(std::thread(Threaded_Mandel_iter,80*i, 79 + 80*i));
        }

        for(int i = 0; i < 16; i++){
            threads[i].join();
        }

        auto End_Mandelbrot_T = std::chrono::high_resolution_clock::now();

        // Timing calculations

        auto Mandelbrot_Time_NT = std::chrono::duration<double>(End_Mandelbrot_NT - Start_Mandelbrot_NT);
        auto Mandelbrot_Time_T = std::chrono::duration<double>(End_Mandelbrot_T - End_Mandelbrot_NT);

        Mandelbrot_Times_NT.push_back(Mandelbrot_Time_NT.count());
        Mandelbrot_Times_T.push_back(Mandelbrot_Time_T.count());
    }

    double Mandelbrot_Avr_NT = average(Mandelbrot_Times_NT);
    double Mandelbrot_Avr_T = average(Mandelbrot_Times_T);


    double multiple = (Mandelbrot_Avr_T < Mandelbrot_Avr_NT) ? Mandelbrot_Avr_NT/Mandelbrot_Avr_T : Mandelbrot_Avr_T/Mandelbrot_Avr_NT;
    std::cout << "Average time for non-threaded approach: " << Mandelbrot_Avr_NT << "s \n";
    std::cout << "Average time for threaded approach: " << Mandelbrot_Avr_T << "s \n";

    std::cout << ((Mandelbrot_Avr_T < Mandelbrot_Avr_NT) ? "Threaded approach has a " : "Non Threaded approach has a ") << multiple << "x speedup \n";
}