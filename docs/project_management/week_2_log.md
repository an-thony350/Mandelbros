# Week 2 Log

The final parts of this week were dedicated to preparing for the presentation on the 1st of June

## EIE Team

### PL

We have successfully got a full working pipeline (29/05 @04:14), as well as build instructions in the repo. 

This essentially came through major debugging of the pipeline through updates of the testbenches, and interaction with the PS by adding more AXI GPIO interfaces to read signals directly. We could catch small issues with reset wiring, and verify output was currect.

As well as having a working demo on screen, we also managed to start out timing comparisons between hardware and software, although our CPU baseline design doesn't include a HDMI output and thus it could be argued that a full end-to-end design cannot be measured, we still measured our hardware latency and achieved a value of ~ 0.5s. We plan to improve this latency value through double buffering.

Now our aim is to streamline this design, and then work on further extensions. 

### CPU Baseline

This week we focused on cleanup to ensure our cpu baseline was more interactive friendly to resemble its usage as a set viewer like the implementation on our hardware v1 release.

This mainly included separating our timing and main files to ensure that indepentant shell scripts could be run to allow for user-friendly testing and viewing.

Moreover, we improved the latency of our design through the way in which squaring was done (actuall multipication of the same value twice rather than a `pow` instruction in C++).

We also added the ability to actually view the sets in png files through the `std_image_write` library. This was not the only addition we made as wealso added the ability to zoom into the sets and produce different images depending on what your center value is.

Next week, we are looking to have an actual HDMI output from the CPU baseline so that we can get more of a realistic end-to-end comparison between hardware and software

### PS

This week focused on building the UI overlay for the HDMI output. The main deliverable was `ui_renderer.py`, a HUD renderer that draws an information overlay directly onto the framebuffer using NumPy and Pillow. The overlay displays the current fractal mode, centre coordinates, zoom level, max iterations, FPS, palette name, controller status, and a crosshair that will follow the joystick position.

To allow development and testing without needing the full system running, a test script was written that loads a real fractal image as a background and feeds in a fake state object with hardcoded values. This allowed the layout, readability, and colour coding to be verified independently of the FPGA and controller. 

Testing against multiple fractal backgrounds revealed that the initial panel opacity was too low, making text unreadable over bright areas of the fractal. This was fixed by increasing the panel darkness and adding a drop shadow to all text, ensuring the overlay is legible regardless of what is rendered underneath.

...


### Updates to Plan/Timeline and Evaluation

`ui_renderer.py` is complete and tested locally. Next step is integration with the live app state so the overlay reads real values from the running system.

...

## EEE Team

### Summary
This week focused on sourcing components and beginning the breadboard build for the FractalScope controller.

### Components
- ...

### Circuit
- ...

### Next Steps
- ...
