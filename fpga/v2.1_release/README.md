# v2.1 Release Instructions

In order to rebuild this vivado project, we have provided the relevant files and the instructions on building our v2.1 project design below:

**Please note that this design requires Vivado 2023.2**

The notebook PS used for this release can be found in `Mandelbros/notebooks/fractalscope_v2.1.ipynb`

### Instructions

1. Clone this repository using the following commands:

```
git clone --no-checkout https://github.com/an-thony350/Mandelbros.git
cd Mandelbros
git sparse-checkout init --cone
git sparse-checkout set fpga/v2.1_release
git checkout main
git submodule update --init --recursive fpga/v2.1_release/ext/vivado-library
```
**Please note the repository path**

2. Open Vivado 2023.2
3. In the Tcl Console enter the command :
`cd <repository path>/Mandelbros/fpga/v2.1_release`
4. Enter the command `source build_project.tcl`

### Changes

- Updated colour palette - allowing for an actual "palette" through a memory file giving a gradient of colours
- Use of a tile scheduler instead of a pixel scheduler, allowing us to render in 32x16 tiles rather than pixels and do multiple renders. This is giving us a much faster percieved latency being reduced by 82.6% relative to v2 (~ 5.7x speedup compared to v2, ~8.2x relative to v1.1)
- Fixed double buffer in PS removing issues with screen tearing - should allow for a smoother transition between images
- Added "dirty rectangles", i.e. tiles where UI would be are no longer calculated as they become redundant - reduced latency by ~ 1.1%
- Maxed out DSP usage by increasing number of cores to 23 - helped increase WNS by allowing for more paths for signals from tile_scheduler -> iter_core_array
- progressive rendering - when first image is shown, a continuation of calculations to make image more refined is done to allow for greater resolution
- pixel_scheduler and associative blocks made redundant