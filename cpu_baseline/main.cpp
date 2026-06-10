#include "functions.hpp"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// to be worked on

int main(){
    choose_mode();
    choose_set();
    std::cout << set_lookup() << " set chosen... \n";

    if(chosen_mode){
        double time = sim_choice();
        std::cout << "Average time for " << set_lookup() << " set calculation: " << time << std::endl;
    }
    else{
        std::this_thread::sleep_for(std::chrono::seconds(1));

        std::cout << "Generating image..." << std::endl;

        Generate_Image();
    }

    auto Start_png_gen = std::chrono::high_resolution_clock::now();

    std::string png = set_lookup() + ".png";
    
    if (stbi_write_png(png.c_str(), COL_NUM, ROW_NUM, 3, image.data(),  COL_NUM * 3)) {
        std::cout << "Success! Check your folder for the image." << std::endl;
    }
    else {
        std::cerr << "Failed to save the image." << std::endl;
    }

    auto End_png_gen = std::chrono::high_resolution_clock::now();

    auto Png_Time = std::chrono::duration<double>(End_png_gen - Start_png_gen);
    if(chosen_mode){
        std::cout << "Time to produce png image: " << Png_Time.count() << std::endl;
    }
}