# v3 Release Instructions

In order to rebuild this vivado project, we have provided the relevant files and the instructions on building our v3 project design below:

**Please note that this design requires Vivado 2023.2**



### Instructions

1. Clone this repository using the following commands:

```
git clone --no-checkout https://github.com/an-thony350/Mandelbros.git
cd Mandelbros
git sparse-checkout init --cone
git sparse-checkout set releases/v3_release
git checkout main
git submodule update --init --recursive releases/v3_release/ext/vivado-library
```
**Please note the repository path**

2. Open Vivado 2023.2
3. In the Tcl Console enter the command :
`cd <repository path>/Mandelbros/releases/v3_release`
4. Enter the command `source build_project.tcl`

### Changes

- Updated colour palette to allow for variable colour palettes representing the same fractal.
- Added periodicity checking in iter_core to allow a faster escape for iterations which which are longer, increasing the max iterations in the tests on the notebook exponentially improve the throughput relative to previous versions
- Implemented the Mariani-Silver algorithm to reduce time to calculate rectangles which all had equal iteration escape values (and thus the same colour) - this was first tested without progresive rendering reducing latency by ~10x (note progressive rendering is re-added for a smoother look)
- Maxed out cores to 23
- Completely redesigned pixel write engine to allow for a burst of pixels to be sent rather than 1 every clock cycle - helped ensure MS algorithm is as effective as possible - v1 engine made redundant