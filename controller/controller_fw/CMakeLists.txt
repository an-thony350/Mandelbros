# == DO NOT EDIT THE FOLLOWING LINES for the Raspberry Pi Pico VS Code Extension to work ==
if(WIN32)
    set(USERHOME $ENV{USERPROFILE})
else()
    set(USERHOME $ENV{HOME})
endif()
set(sdkVersion 2.2.0)
set(toolchainVersion 14_2_Rel1)
set(picotoolVersion 2.2.0-a4)
set(picoVscode ${USERHOME}/.pico-sdk/cmake/pico-vscode.cmake)
if (EXISTS ${picoVscode})
    include(${picoVscode})
endif()
# ====================================================================================
set(PICO_BOARD pico CACHE STRING "Board type")

cmake_minimum_required(VERSION 3.13)
include(pico_sdk_import.cmake)
project(fractalscope_controller C CXX ASM)
set(CMAKE_C_STANDARD 11)
pico_sdk_init()

add_executable(controller
    src/main.c
    src/encoders.c
    src/buttons.c
    src/adc_inputs.c
    src/crc8.c
)

pico_enable_stdio_usb(controller 1)   # USB CDC for the packet stream
pico_enable_stdio_uart(controller 0)  # don't waste GPIO 0/1 on UART debug
target_link_libraries(controller pico_stdlib hardware_adc hardware_irq)
pico_add_extra_outputs(controller)