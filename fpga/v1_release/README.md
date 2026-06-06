# v1 Release Instructions

In order to rebuild this vivado project, we have provided the relevant files and the instructions on building our v1 project design below:

**Please note that this design requires Vivado 2023.2**

The notebook PS used for this release can be found in `Mandelbros/notebooks/2_further_fractal_displays.ipynb`

### Instructions

1. Clone this repository using the following commands:

```
git clone --no-checkout https://github.com/an-thony350/Mandelbros.git
cd Manelbros
git sparse-scheckout init --cone
git sparse-checkout set fpga/v1_release
git checkout main
git submodule update --init --recursive fpga/v1_release/ext/vivado-library
```
**Please note the repository path**

2. Open Vivado 2023.2
3. In the Tcl Console enter the command `cd <repository path>/Mandelbros/fpga/v1_release`
4. Enter the command `source build_project.tcl`
