# Week 4 Log

This week is effectively the final week before report submission. The majority of our work focused on refining our system for the report and ensuring all our final ideas were executed correctly.

## FPGA Team

### PL

On the PL side, we were able to fully complete a couple of our proposed extensions: the Mariani-Silver algorithm, progressive rendering, and periodicity checking. Unfortunately, we were unable to make scaled perturbation work as expected, but we have detailed all our attempts within the report. We believe we have produced a system that is as optimised as possible, given our 23-core parallelised design which maximises DSP utilisation.

## Software Team

### PS

On the PS side, we fully integrated our educational design with our PL fractal viewer. We moved away from our Jupyter Notebook PS, which was mainly used for testing purposes, to Python scripts running our educational section, HUD overlay, and backend for the PL.

### CPU Baseline

The CPU baseline has now been integrated into the PS, using the PYNQ board's CPU to run the baseline and output via the board's HDMI.

## Controller Team

### Summary

The main issue we faced this week was that the PCB was not going to arrive on time, which meant we had to fall back on our contingency plan — using a scrapboard instead. After ordering and receiving the scrapboard, we worked out the optimal layout so that it roughly matched the existing PCB and casing designs. We then soldered and wired the components accordingly.

The scrapboard controller's functionality was validated against the latest system release. The casing was then finalised using the scrapboard measurements and sent off for 3D printing. 

After receiving the casing, the controller was assembled and the fit of both the casing and the scrapboard was checked. That marked the completion of the final controller design.
