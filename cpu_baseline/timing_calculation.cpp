#include "definitions.hpp"
#include "functions.cpp"



double non_threaded_timing(){

    std::vector<double> timing_doubles;

    for(int loop_count = 0; loop_count < TOTAL_LOOPS; loop_count++){

        std::cout << "Starting loop: " << loop_count + 1 << std::endl;

        auto Start_Time  = std::chrono::high_resolution_clock::now();

        Call_Calc(0, ROW_NUM);

        auto End_Time = std::chrono::high_resolution_clock::now();

        auto Time = std::chrono::duration<double>(End_Time - Start_Time);
        timing_doubles.push_back(Time.count());
    }

    return average(timing_doubles);
}

double threaded_timing(){

    std::vector<double> timing_doubles;
    
    for(int loop_count = 0; loop_count < TOTAL_LOOPS; loop_count++){
        std::vector<std::thread> threads;

        std::cout << "Starting loop: " << loop_count + 1 << std::endl;

        auto Start_Time  = std::chrono::high_resolution_clock::now();
        for(int thread_count = 0; thread_count < NUM_THREADS; thread_count++){
        
            int start_row = thread_count*(ROW_NUM/NUM_THREADS);
            int end_row = (thread_count == NUM_THREADS - 1) ? ROW_NUM : start_row + ROW_NUM/NUM_THREADS; // used for an uneven distribution of row loops - can be removed w/ assumption
            threads.push_back(std::thread(Call_Calc, start_row, end_row)); // synchronisation needed here to check properly
        }

        for(int thread_num = 0; thread_num < NUM_THREADS; thread_num++){
            threads[thread_num].join();
        }
        auto End_Time = std::chrono::high_resolution_clock::now();

        auto Time = std::chrono::duration<double>(End_Time - Start_Time);
        timing_doubles.push_back(Time.count());
    }
    return average(timing_doubles);
}




int main(){
    choose_set();
    std::cout << "Set chosen, now running timing tests: \n";
    double time = non_threaded_timing();

    std::cout << "Average time for " << "SET" << ": " << time << " seconds.\n";

    if (stbi_write_png("mandelbrot.png", COL_NUM, ROW_NUM, 3, image.data(),  COL_NUM * 3)) {
        std::cout << "Success! Check your folder for the image." << std::endl;
    } else {
        std::cerr << "Failed to save the image." << std::endl;
    }
}