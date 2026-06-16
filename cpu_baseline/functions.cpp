#include "definitions.hpp"
#include "functions.hpp"

// Global variables

int chosen_set;
double  z_real, z_imaginary;
std::vector<unsigned char> image(ROW_NUM * COL_NUM * 3); // The brackets here define the size of the vector
int NUM_THREADS;
double zoom_factor, center_x, center_y;
int chosen_mode;

// Fractal Calculation Functions
                   
int Mandelbrot_calculation(double c_re, double c_im, int size){ // The image for this could be improved
    
    // Initial z values & iteration value
    double z_re = 0.0;
    double z_im = 0.0;
    int i = 0;

    // Mandelbrot Calc - Continues until instability is determined if less than size
    while((i < size) && ((z_re*z_re) + (z_im*z_im) <= 4)){
        
        double tmp_z_re = z_re;
        double tmp_z_im = z_im;

        z_re = (tmp_z_re*tmp_z_re) - (tmp_z_im*tmp_z_im) + c_re;
        z_im = 2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return i;
}
int Julia_calculation(double c_re, double c_im, double z_re, double z_im, int size){

    // Initial values
    int i = 0;

    // Julia Calc

    while((i<size) && ((z_re*z_re) + (z_im*z_im) <= 4)){

        double tmp_z_re = z_re;
        double tmp_z_im = z_im; 

        z_re = (tmp_z_re*tmp_z_re) - (tmp_z_im*tmp_z_im) + c_re;
        z_im = 2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return i;
}
int Burning_Ship_calculation(double c_re, double c_im, int size){ 

    // Initial values
    double z_re = 0.0;
    double z_im = 0.0;
    int i = 0;

    while((i < size) && ((z_re*z_re) + (z_im*z_im) <= 4)){
        
        double tmp_z_re = std::abs(z_re);
        double tmp_z_im = std::abs(z_im);

        z_re = (tmp_z_re*tmp_z_re) - (tmp_z_im*tmp_z_im) + c_re;
        z_im = 2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return i;
}
int Tricorn_calculation(double c_re, double c_im, int size){

    // Initial values
    double z_re = 0.0;
    double z_im = 0.0;
    int i = 0;

    while((i < size) && ((z_re*z_re) + (z_im*z_im) <= 4)){
        
        double tmp_z_re = z_re;
        double tmp_z_im = -1*z_im;

        z_re = (tmp_z_re*tmp_z_re) - (tmp_z_im*tmp_z_im) + c_re;
        z_im = 2*(tmp_z_re*tmp_z_im) + c_im;

        i++;
    }
    return i;
}

// Main Fractal Choice Functions

void choose_mode(){
    std::cout << "Choose which mode to run: \n";
    std::cout << "Fractal Generation: 0\n";
    std::cout << "Timing Analysis: 1\n";
    std::cin  >> chosen_mode;

    if(choose_mode != 0 || choose_mode != 1){
        std::cout << "Invalid Input, please redo\n";
        return choose_mode();
    }
}

void choose_set(){
    std::cout << "Choose which set to represent: \n";
    std::cout << "Mandelbrot: 0\n";
    std::cout << "Julia: 1\n";
    std::cout << "Burning Ship: 2\n";
    std::cout << "Tricorn: 3\n";
    std::cin >> chosen_set;

    if(chosen_set == 1){
        std::cout << "Choose the real value of c: \n";
        std::cin >> z_real;
        std::cout << "Choose the imaginary value of c: \n";
        std::cin >> z_imaginary;
    }

    // check these values

    std::cout << "Choose a value for zoom\n";
    std::cout << "min = 1.0\n";
    std::cout << "max = 100\n";
    std::cin >> zoom_factor;

    std::cout << "Choose a center value for x\n";
    std::cout << "min = -2.0\n";
    std::cout << "max = 2.0\n";
    std::cin >> center_x;

    std::cout << "Choose a center value for y\n";
    std::cout << "min = -2.0\n";
    std::cout << "max = 2.0\n";
    std::cin >> center_y;

    if(zoom_factor > 100 || abs(center_x) > 2 || abs(center_y) > 2 || abs(chosen_set) > 3){
        std::cout << "Invalid Input, please redo\n";
        return choose_set();
    }

    return;
}
std::string set_lookup(){
    switch (abs(chosen_set)){
    case 0:
        return "Mandelbrot";
        break;
    case 1:
        return "Julia";
        break;
    case 2:
        return "Burning Ship";
        break;
    case 3:
        return "Tricorn";
    default:
        return "Error - No set chosen";
        break;
    }
}
int Chosen_Function(double c_re, double c_im, double z_re, double z_im){
    switch(chosen_set){

    case Mandelbrot:
        return Mandelbrot_calculation(c_re, c_im, ITER_NUM);
        break;
    case Julia:
        return Julia_calculation(z_re, z_im, c_re, c_im, ITER_NUM); //swapped here for ease
        break;
    case Burning_Ship:
        return Burning_Ship_calculation(c_re, c_im, ITER_NUM);
        break;
    case Tricorn:
        return Tricorn_calculation(c_re, c_im, ITER_NUM);
        break;
    default:
         std::cerr<<"Error incorrect input \n";
         return 0;
    }
}

// Colour Palette function - changes can be made later

void palette(int iter, unsigned char& r, unsigned char& g, unsigned char& b){
    if(iter == ITER_NUM){
        r = 0; 
        g = 0; 
        b = 0;
    }
    else{
        double gradient = (double)iter / (double)ITER_NUM;

        r = (unsigned char)(9* (1-gradient)* gradient * gradient * gradient * 255);
        g = (unsigned char)(15 * (1-gradient) * (1-gradient) * gradient * gradient * 255);
        b = (unsigned char)(8.5 * (1-gradient) * (1-gradient) * (1-gradient) * gradient * 255);
    }
}

// Pixel calculation

void Call_Calc(int start_row, int end_row){

    double scale = ASPECT_RATIO / (COL_NUM * zoom_factor);

    for(int row = start_row; row < end_row; row++){

        double c_im = center_y + (row - ROW_NUM / 2.0) * scale;

        for(int col = 0; col < COL_NUM; col++){

            double c_re = center_x + (col - COL_NUM / 2.0) * scale;

            int iter = Chosen_Function(c_re, c_im, z_real, z_imaginary);
            
            unsigned char r, g, b;
            
            
            palette(iter, r, g, b);

            int index = (row * COL_NUM + col) * 3;
            image[index + 0] = r;
            image[index + 1] = g;
            image[index + 2] = b;
        }
    }
}

// Image generation

void Generate_Image(){
    std::vector<std::thread> threads;
    for(int thread_count = 0; thread_count < MAIN_NUM_THREADS; thread_count++){

        int start_row = thread_count*(ROW_NUM/MAIN_NUM_THREADS);
        int end_row = (thread_count == MAIN_NUM_THREADS - 1) ? ROW_NUM : start_row + ROW_NUM/MAIN_NUM_THREADS; // used for an uneven distribution of row loops - can be removed w/ assumption
        threads.push_back(std::thread(Call_Calc, start_row, end_row));

    }
    
    for(int thread_num = 0; thread_num < MAIN_NUM_THREADS; thread_num++){
        threads[thread_num].join();
    }
}

// Timing functions

double average(std::vector<double> v){
    double ans = 0;
    for(int i = 0; i < v.size(); i++){
        ans += v[i]/v.size();
    }
    return ans;
}

// Standard test - single-threaded

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

// Multi-threaded tests - could also use for 1 thread but slower on average

double threaded_timing(){

    std::vector<double> timing_doubles;
    
    for(int loop_count = 0; loop_count < TOTAL_LOOPS; loop_count++){
        std::vector<std::thread> threads;

        std::cout << "Starting loop: " << loop_count + 1 << std::endl;

        auto Start_Time  = std::chrono::high_resolution_clock::now();
        for(int thread_count = 0; thread_count < NUM_THREADS; thread_count++){
        
            int start_row = thread_count*(ROW_NUM/NUM_THREADS);
            int end_row = (thread_count == NUM_THREADS - 1) ? ROW_NUM : start_row + ROW_NUM/NUM_THREADS; // used for an uneven distribution of row loops - can be removed if thread count produces equal row split
            threads.push_back(std::thread(Call_Calc, start_row, end_row)); // No Race conditions in this
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
        std::cout << thread_num << " threads chosen, starting test...\n";
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