#include "definitions.hpp"
#include "functions.cpp"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// global variable for thread implemention

int NUM_THREADS;

// Standard test

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

// Threaded tests - could also use for 1 thread but slower on average

double threaded_timing(){

    std::vector<double> timing_doubles;
    
    for(int loop_count = 0; loop_count < TOTAL_LOOPS; loop_count++){
        std::vector<std::thread> threads;

        std::cout << "Starting loop: " << loop_count + 1 << std::endl;

        auto Start_Time  = std::chrono::high_resolution_clock::now();
        for(int thread_count = 0; thread_count < NUM_THREADS; thread_count++){
        
            int start_row = thread_count*(ROW_NUM/NUM_THREADS);
            int end_row = (thread_count == NUM_THREADS - 1) ? ROW_NUM : start_row + ROW_NUM/NUM_THREADS; // used for an uneven distribution of row loops - can be removed w/ assumption
            threads.push_back(std::thread(Call_Calc, start_row, end_row)); // synchronisation needed here to check properly - CHECK THIS, MAY NOT BE AN ISSUE
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

double sim_choice(){

    std::cout << "\n";
    std::cout << "Choose the test you want to run: \n";
    std::cout << "0: Baseline test - No threading\n";
    std::cout << "1: Threaded test\n";

    int chosen;
    std::cin >> chosen;

    if(chosen == 0){
        std::cout << "Baseline test chosen...\n";
        std::cout << "\n";
        return non_threaded_timing();
    }
    else if(chosen == 1){
        std::cout << "Threaded test chosen...\n";
        std::cout << "\n";
        std::cout << "Choose the number of threads: \n";
        int thread_num;
        std::cin >> thread_num;
        std::cout << thread_num << " threads chosen...\n";
        std::cout << "\n";
        NUM_THREADS = thread_num;
        return threaded_timing();
    }
    else{
        std::cout << "Error, invalid option chosen, please choose a valid input." << std::endl;
        std::cout << "\n";
        return sim_choice();
    }
    
}




int main(){
    choose_set();
    std::cout << set_lookup() << " set chosen... \n";
    double time = sim_choice();

    std::cout << "Average time for " << set_lookup() << " set: " << time << " seconds.\n";
}