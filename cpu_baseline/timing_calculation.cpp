#include "definitions.hpp"
#include "set_calculation.cpp"

double average(std::vector<double> v){
    double ans = 0;
    for(int i = 0; i < v.size(); i++){
        ans += v[i]/v.size();
    }
    return ans;
}


double timing(int choice){
    std::vector<double> timing_doubles;
    for(int loop_count = 0; loop_count < TOTAL_LOOPS; loop_count++){

        auto Start_Time  = std::chrono::high_resolution_clock::now();

        for(int row_loop = 0; row_loop < ROW_NUM; row_loop++){
            for(int col_loop = 0; col_loop < COL_NUM; col_loop++){
                // function w/ integer choice
            }
        }
        auto End_Time = std::chrono::high_resolution_clock::now();

        auto Time = std::chrono::duration<double>(End_Time - Start_Time);
        timing_doubles.push_back(Time.count());
    }
    return average(timing_doubles);


}