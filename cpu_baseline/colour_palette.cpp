#include "functions.cpp"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"




int main(){ 
    if (stbi_write_png("mandelbrot.png", ROW_NUM, COL_NUM, 3, image.data(), ROW_NUM * 3)) {
        std::cout << "Success! Check your folder for the image." << std::endl;
    } else {
        std::cerr << "Failed to save the image." << std::endl;
    }
}