#include "definitions.hpp"
#include "set_calculation.cpp"


double average(std::vector<double> v){
    double ans = 0;
    for(int i = 0; i < v.size(); i++){
        ans += v[i]/v.size();
    }
    return ans;
}

// Raster iteration of grid, allows for threaded approach
void Call_Calc(int start_row, int end_row){
    double tmp_row_loop, tmp_col_loop;

    for(start_row; start_row < end_row; start_row++){

        if(start_row > ROW_NUM/2) tmp_row_loop = -1*start_row;
        else if(start_row == ROW_NUM/2) tmp_row_loop = 0;
        else tmp_row_loop = start_row;

        double c_re = tmp_row_loop/ROW_NUM;

        for(int col_loop = 0; col_loop < COL_NUM; col_loop++){

            if(col_loop < COL_NUM/2) tmp_col_loop = -1*col_loop;
            else if(col_loop == COL_NUM/2) tmp_col_loop = 0;
            else tmp_col_loop = col_loop;

            double c_im = tmp_col_loop/COL_NUM;

            Chosen_Function(c_re, c_im, z_real, z_imaginary);
        }
    }
}

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
    std::vector<std::thread> threads;
    
    for(int loop_count = 0; loop_count < TOTAL_LOOPS; loop_count++){
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
    double time = threaded_timing();

    std::cout << "Average time for " << "SET" << ": " << time << " seconds.\n";

}