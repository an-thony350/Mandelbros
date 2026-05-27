#include "definitions.hpp"
#include "set_calculation.cpp"
#include "timing_calculation.cpp"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"


void palette(int iter, unsigned char& r, unsigned char& g, unsigned char& b){
    if(iter == ITER_NUM){
        r = 0; 
        g = 0; 
        b = 0;
    }
    else{
        double gradient = iter / ITER_NUM;

        r = (9* (1-gradient)* gradient * gradient * gradient * 255);
        g = (15 * (1-gradient) * (1-gradient) * gradient * gradient * 255);
        b = (8.5 * (1-gradient) * (1-gradient) * (1-gradient) * gradient * 255);
    }
}

int main(){
    choose_set();
    std::cout << "Set chosen, now running timing tests: \n";
    double time = non_threaded_timing();



    std::vector<unsigned char> image(ROW_NUM * COL_NUM * 3);

    std::cout << "Mandelbrot image generating: \n";

    for(int i = 0; i < map.size(); i++){
        unsigned char r,g,b;
        palette(map[i].second, r, g, b);
        image.push_back(r);
        image.push_back(r);
        image.push_back(r);
    }

    std::cout << "Saving Image now... \n";

    if (stbi_write_png("mandelbrot.png", ROW_NUM, COL_NUM, 3, image.data(), ROW_NUM * 3)) {
        std::cout << "Success! Check your folder for the image." << std::endl;
    } else {
        std::cerr << "Failed to save the image." << std::endl;
    }
}