# Week 3 log

This week was for making proposed changes after the presentation, ensuring we had a full working system

## EIE Team

### PL

On the PL side, we focused on changing our system to allow for v2 releases. This included a re-evaluation of our reorder buffer, sending pixels directly to DDR memory instead of reordering them, reducing end-to-end latency and resolving issues with buffer overflow. We worked on providing a strong enough release for the final demo in the case that our personal proposed extensions were not to work

### PS

On the PS side, we included double buffering (two frame buffers) which eliminated sscreen tearing. It also allowed us to write data into a buffer while another buffer was having its information displayed by HDMI, helping reduce overall latency as well as assisting in smoother transition between displays.

### Updates to Plan/Timeline and Evaluation

Given that we are able to achieve a full release varient that we could provide in a worse-case scenario. We now are plannig to move on with challenging hardware-based extensions that can severley cut latency as well as provide a better user experience. We are also planning to fully flesh out our educational section of the project providing details to a user who may not have the context of the sets that we do.

## EE Team