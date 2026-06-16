# Week 3 log

This week was for making proposed changes after the presentation, ensuring we had a full working system

## EIE Team

### PL

On the PL side, we focused on changing our system to allow for v2 releases. This included a re-evaluation of our reorder buffer, sending pixels directly to DDR memory instead of reordering them, reducing end-to-end latency and resolving issues with buffer overflow. We worked on providing a strong enough release for the final demo in the case that our personal proposed extensions were not to work

### PS

On the PS side, we included double buffering (two frame buffers) which eliminated sscreen tearing. It also allowed us to write data into a buffer while another buffer was having its information displayed by HDMI, helping reduce overall latency as well as assisting in smoother transition between displays.

### Updates to Plan/Timeline and Evaluation

Given that we are able to achieve a full release varient that we could provide in a worse-case scenario. We now are plannig to move on with challenging hardware-based extensions that can severley cut latency as well as provide a better user experience. We are also planning to fully flesh out our educational section of the project providing details to a user who may not have the context of the sets that we do.

## Controller Team

### Summary

We had to ensure the controller worked with the PYNQ board and the v1 and v2 releases, as well as design and order the PCB, and design the casing. We wrote a cell in the jupyter notebook to interpret the serial input from the controller so that it could be used to control the system. We used a HDMI monitor for this. We initially used the v1 release to test the basics of the controller - the joystick moving, the encoders for coarse/fine zoom and iteration adjustments, and the mode button to switch between different fractals. After this was validated, we moved on to the v2 release, which was much smoother and allowed us to validate that the controller inputs worked exactly as intended. 

After this was validated, we passed the controller on to the EIE team to test and refine. The PCB design was finalised and ordered, and the casing design was completed.

### Next Steps

- Solder PCB and test.
- Order casing for 3D printing.
