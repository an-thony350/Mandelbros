#include "functions.hpp"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// Main allowin for image generation & timing calculation

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


    std::string png = set_lookup() + ".png";
    
    if(!chosen_mode){
        if (stbi_write_png(png.c_str(), COL_NUM, ROW_NUM, 3, image.data(),  COL_NUM * 3)) {
            std::cout << "Success! Check your folder for the image." << std::endl;
        }
        else {
            std::cerr << "Failed to save the image." << std::endl;
        }
    }

}