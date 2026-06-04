# v2 Release Instructions

In order to rebuild this vivado project, we have provided the relevant files and the instructions on building our v1 project design below:

**Please note that this design requires Vivado 2023.2**

### Instructions

1. Clone this repository using the following command: `git clone --recursive https://github.com/an-thony350/Mandelbros.git` **Please note the repository path**
2. Open Vivado 2023.2
3. In the Tcl Console enter the command `cd <repository path>/Mandelbros/fpga/v2_release`
4. Enter the command `source build_project.tcl`

### Changes

- Removal of reorder buffer, reducing LUT usage by 52.7% and increasing WNS by 1.615ns
- Replaced reordering of pixels with a write engine that writes data directly to DDR rather than reordering and then sending
- Changed colour palette to represent a dark blue setup for escaped iterations in the set
- Addition of double buffering, i.e. having two frame buffers controlled by PS so that one writes to HDMI while the PL writes into the other, reduced end-to-end latency by 32.7% (attributing to a ~ 1.5x speedup)
- Removal of packer as it became redundant due to pixel write engine
- Simplified iter core logic due to removal of reorder buffer
- Hit max no longer tracked in perf_counters