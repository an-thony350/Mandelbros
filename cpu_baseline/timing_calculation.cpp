#include "definitions.hpp"
#include "set_calculation.cpp"


double average(std::vector<double> v){
    double ans = 0;
    for(int i = 0; i < v.size(); i++){
        ans += v[i]/v.size();
    }
    return ans;
}


double timing(){
    std::vector<double> timing_doubles;
    double tmp_row_loop, tmp_col_loop;
    for(int loop_count = 0; loop_count < TOTAL_LOOPS; loop_count++){
        std::cout << "Starting loop: " << loop_count + 1 << std::endl;

        auto Start_Time  = std::chrono::high_resolution_clock::now();

        for(int col_loop = 0; col_loop < COL_NUM; col_loop++){

            if(col_loop < COL_NUM/2) tmp_col_loop = -1*col_loop;
            else if(col_loop == COL_NUM/2) tmp_col_loop = 0;
            else tmp_col_loop = col_loop;
            double c_im = tmp_col_loop/COL_NUM;

            for(int row_loop = 0; row_loop < ROW_NUM; row_loop++){

                if(row_loop > ROW_NUM/2) tmp_row_loop = -1*row_loop;
                else if(row_loop == ROW_NUM/2) tmp_row_loop = 0;
                else tmp_row_loop = row_loop;

                double c_re = tmp_row_loop/ROW_NUM;

                Chosen_Function(c_re, c_im, z_real, z_imaginary);
            }
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
    int time = timing();

    std::cout << "Average time for " << "SET" << ": " << time << " seconds.\n";

}