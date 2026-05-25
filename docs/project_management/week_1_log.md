# Week 1 Log

## EIE Team

### FPGA Acceleration

We started on work for the first FPGA pipeline over this week. We did a large amount of the RTL work and brainstorming on Tuesday, before picking it back up on Saturday/Sunday. We are currently at the stage of testing the hardware through Jupyter notebooks to hopefully get some stuff displayed this week. 

#### RTL

Below is a diagram showing the structure of the RTL

```mermaid
flowchart LR

    %% External interfaces

    PS["PYNQ / ARM PS<br/>AXI-Lite master<br/><br/>Inputs to RTL:<br/>s00_axi_aclk<br/>s00_axi_aresetn<br/>s00_axi_awaddr<br/>s00_axi_awprot<br/>s00_axi_awvalid<br/>s00_axi_wdata<br/>s00_axi_wstrb<br/>s00_axi_wvalid<br/>s00_axi_bready<br/>s00_axi_araddr<br/>s00_axi_arprot<br/>s00_axi_arvalid<br/>s00_axi_rready<br/><br/>Outputs from RTL:<br/>s00_axi_awready<br/>s00_axi_wready<br/>s00_axi_bresp<br/>s00_axi_bvalid<br/>s00_axi_arready<br/>s00_axi_rdata<br/>s00_axi_rresp<br/>s00_axi_rvalid"]

    VIDEO["AXI4-Stream Video / DMA / HDMI path<br/><br/>Inputs to RTL:<br/>out_stream_tready<br/><br/>Outputs from RTL:<br/>out_stream_tdata[31:0]<br/>out_stream_tkeep[3:0]<br/>out_stream_tlast<br/>out_stream_tvalid<br/>out_stream_tuser[0]"]

    %% AXI config and pixel scheduler

    subgraph CTRL["AXI-Lite Control + Pixel Scheduling"]
        AXI["pixel_scheduler_top<br/>pixel_scheduler_AXI<br/><br/>AXI-Lite registers:<br/>slv_reg0 = x_jump[25:0]<br/>slv_reg1 = y_jump[25:0]<br/>slv_reg2 = x_min[25:0]<br/>slv_reg3 = y_min[25:0]<br/>slv_reg4 = jul_c_r[25:0]<br/>slv_reg5 = jul_c_i[25:0]<br/>slv_reg6[15:0] = in_max_iter<br/>slv_reg6[18:16] = in_mode<br/>slv_reg7[0] = software_start"]

        SCHED["pixel_scheduler<br/><br/>Inputs:<br/>clk<br/>rst<br/>x_jump[W-1:0]<br/>y_jump[W-1:0]<br/>x_min[W-1:0]<br/>y_min[W-1:0]<br/>jul_c_r[W-1:0]<br/>jul_c_i[W-1:0]<br/>in_max_iter[ITER_W-1:0]<br/>in_mode[MODE_W-1:0]<br/>in_ready[NUM_CORES-1:0]<br/><br/>Outputs:<br/>last_pixel<br/>in_valid[NUM_CORES-1:0]<br/>c_r[W*NUM_CORES-1:0]<br/>c_i[W*NUM_CORES-1:0]<br/>z0_r[W*NUM_CORES-1:0]<br/>z0_i[W*NUM_CORES-1:0]<br/>out_max_iter[ITER_W*NUM_CORES-1:0]<br/>out_mode[MODE_W*NUM_CORES-1:0]<br/>out_seq[SEQ_W*NUM_CORES-1:0]"]
    end

    PS -->|"AXI-Lite write/read channels"| AXI
    AXI -->|"configuration registers"| SCHED

    %% Compute core array

    subgraph CORE_ARRAY["iter_core_array"]
        ARRAY_IN["iter_core_array top I/O<br/><br/>Inputs:<br/>clk<br/>rst_n<br/>in_valid[NUM_CORES-1:0]<br/>c_r[W*NUM_CORES-1:0]<br/>c_i[W*NUM_CORES-1:0]<br/>z0_r[W*NUM_CORES-1:0]<br/>z0_i[W*NUM_CORES-1:0]<br/>in_max_iter[ITER_W*NUM_CORES-1:0]<br/>in_mode[MODE_W*NUM_CORES-1:0]<br/>in_seq[SEQ_W*NUM_CORES-1:0]<br/>out_ready<br/><br/>Outputs:<br/>in_ready[NUM_CORES-1:0]<br/>out_valid<br/>out_seq[SEQ_W-1:0]<br/>out_iter[ITER_W-1:0]<br/>out_z_r[W-1:0]<br/>out_z_i[W-1:0]<br/>out_escaped<br/>out_overflow"]

        CORES["NUM_CORES × iter_core<br/><br/>Per-core inputs:<br/>clk<br/>rst_n<br/>in_valid<br/>in_c_r[W-1:0]<br/>in_c_i[W-1:0]<br/>in_z0_r[W-1:0]<br/>in_z0_i[W-1:0]<br/>in_max_iter[ITER_W-1:0]<br/>in_mode[MODE_W-1:0]<br/>in_seq[SEQ_W-1:0]<br/>out_ready<br/><br/>Per-core outputs:<br/>in_ready<br/>out_valid<br/>out_seq[SEQ_W-1:0]<br/>out_iter[ITER_W-1:0]<br/>out_z_r[W-1:0]<br/>out_z_i[W-1:0]<br/>out_escaped<br/>out_overflow<br/><br/>Internal pipeline:<br/>s0 mode transform<br/>s1 operand register<br/>s2 DSP M products<br/>s3 DSP P products<br/>s4 rounding/overflow<br/>s5 z_new and |z|² sums<br/>s6 escape/max_iter/eject"]

        SKID["NUM_CORES × skid_buffer_m<br/><br/>Inputs:<br/>clk<br/>rst<br/>in_valid<br/>in_ready<br/>in_data[TOTAL_W-1:0]<br/><br/>Outputs:<br/>out_valid<br/>out_ready<br/>out_data[TOTAL_W-1:0]<br/><br/>Packed data contains:<br/>seq<br/>iter<br/>z_r<br/>z_i<br/>escaped<br/>overflow"]

        ARB["result_arbiter<br/><br/>Inputs:<br/>clk<br/>rst<br/>core_out_valid[NUM_CORES-1:0]<br/>core_out_seq[SEQ_W*NUM_CORES-1:0]<br/>core_out_iter[ITER_W*NUM_CORES-1:0]<br/>core_out_z_r[W*NUM_CORES-1:0]<br/>core_out_z_i[W*NUM_CORES-1:0]<br/>core_out_escaped[NUM_CORES-1:0]<br/>core_out_overflow[NUM_CORES-1:0]<br/>rob_in_ready<br/><br/>Outputs:<br/>core_out_ready[NUM_CORES-1:0]<br/>rob_in_valid<br/>rob_in_iter_count[ITER_W-1:0]<br/>rob_in_seq_num[SEQ_W-1:0]<br/>rob_in_z_r[W-1:0]<br/>rob_in_z_i[W-1:0]<br/>rob_in_escaped<br/>rob_in_overflow"]
    end

    SCHED -->|"per-core input streams:<br/>in_valid, c_r, c_i, z0_r, z0_i,<br/>max_iter, mode, seq"| ARRAY_IN
    ARRAY_IN -->|"unpacked per-core inputs"| CORES
    CORES -->|"raw completed core results"| SKID
    SKID -->|"skidded per-core result streams"| ARB
    ARB -->|"selected single result stream"| ARRAY_IN
    ARRAY_IN -->|"in_ready[NUM_CORES-1:0]"| SCHED

    %% Reorder buffer

    ROB["reorder_buffer<br/><br/>Inputs:<br/>clk<br/>rst<br/>palette_ready<br/>in_iter_count[ITER_W-1:0]<br/>in_seq_num[SEQ_W-1:0]<br/>in_z_r[W-1:0]<br/>in_z_i[W-1:0]<br/>in_escaped<br/>in_overflow<br/>in_valid<br/><br/>Outputs:<br/>out_ready<br/>out_iter_count[ITER_W-1:0]<br/>out_seq_num[SEQ_W-1:0]<br/>out_z_r[W-1:0]<br/>out_z_i[W-1:0]<br/>out_escaped<br/>out_overflow<br/>out_valid<br/>out_sof<br/>out_eol<br/>out_hit_max<br/><br/>Role:<br/>stores out-of-order results by seq_num<br/>emits ordered pixels starting at exp_seq_num"]

    ARRAY_IN -->|"out_valid, out_seq, out_iter,<br/>out_z_r, out_z_i, out_escaped, out_overflow"| ROB
    ROB -->|"out_ready / rob_in_ready"| ARRAY_IN

    %% Colour palette

    PAL["colour_palette<br/><br/>Inputs:<br/>clk<br/>rst<br/>in_valid<br/>in_iter_count[ITER_W-1:0]<br/>in_seq_num[SEQ_W-1:0]<br/>in_z_r[W-1:0]<br/>in_z_i[W-1:0]<br/>in_escaped<br/>in_overflow<br/>out_ready<br/><br/>Outputs:<br/>palette_ready<br/>out_valid<br/>out_seq_num[SEQ_W-1:0]<br/>out_r[7:0]<br/>out_g[7:0]<br/>out_b[7:0]<br/><br/>Colour rules:<br/>overflow -> magenta<br/>not escaped -> black<br/>escaped -> iteration-based RGB"]

    ROB -->|"ordered pixel stream:<br/>valid, iter_count, seq_num,<br/>z_r, z_i, escaped, overflow"| PAL
    PAL -->|"palette_ready"| ROB

    %% Packer / video stream

    PACK["packer<br/><br/>Inputs:<br/>aclk<br/>aresetn<br/>r[7:0]<br/>g[7:0]<br/>b[7:0]<br/>eol<br/>valid<br/>sof<br/>out_stream_tready<br/><br/>Outputs:<br/>in_stream_ready<br/>out_stream_tdata[31:0]<br/>out_stream_tkeep[3:0]<br/>out_stream_tlast<br/>out_stream_tvalid<br/>out_stream_tuser[0]<br/><br/>Role:<br/>packs RGB pixels into AXI4-Stream video words"]

    PAL -->|"out_r, out_g, out_b, out_valid"| PACK
    ROB -->|"out_sof, out_eol"| PACK
    PACK -->|"in_stream_ready / out_ready"| PAL
    PACK -->|"AXI4-Stream video"| VIDEO

    %% Performance counters

    PERF["perf_counters<br/><br/>Inputs:<br/>clk<br/>rst<br/>stream_valid<br/>stream_ready<br/>sof_pulse<br/>pixel_iter[ITER_W-1:0]<br/>pixel_escaped<br/>pixel_hit_max<br/><br/>Outputs to AXI-Lite/readback:<br/>snap_frame_cycles[31:0]<br/>snap_total_iters[63:0]<br/>snap_pixels_escaped[31:0]<br/>snap_pixels_hit_max[31:0]"]

    ROB -->|"stream_valid = out_valid<br/>pixel_iter = out_iter_count<br/>pixel_escaped = out_escaped<br/>pixel_hit_max = out_hit_max<br/>sof_pulse = out_sof"| PERF
    PAL -->|"stream_ready = palette_ready"| PERF
    PERF -. "performance snapshots to AXI-Lite register/readback path" .-> AXI

```

Design Decisions:

- iter_core is the main computation block, and uses a 7-stage pipeline to make the escape calculations. This was upped from a 5-stage pipeline due to Worst Negative Slack issues we were encountering. We run 16 of these cores in parallel (reduced from 32 due to LUT constraints in the PYNQ-Z1)

- The reorder_buffer is used in between the iter_core array and the colour palette to ensure that the pixels are ordered before continuing

- We implemented a very simple colour palette without any smoothing or further enhancements just yet. This is so that we can just get a basic MVP working for the presentation. 

- The packer is the same as was provided in the project brief

- We have performance counters which will be used later on to compare with the baseline.

- We included a wrapper to the iter_core block given the "array style" inputs we had implemented in our original design

- We also included a skid buffer to ensure we had correct passing of data through the cores to the arbiter without causing signals between cores to intersect eachother

#### Testbenches

Every major RTL source now has a corresponding SystemVerilog testbench. This has been especially useful because debugging in simulation is much faster than repeatedly generating and testing bitstreams on the PYNQ board.

Testbenches implemented:

- `iter_core_tb.sv` tests the main fractal iteration core. It covers Mandelbrot, Julia, Burning Ship, and Tricorn modes, as well as overflow behaviour, max-iteration cases, burst inputs, backpressure, reset during activity, and sequence-number correctness.

- `pixel_scheduler_tb.sv` checks that the scheduler generates the correct pixel coordinates, assigns sequence numbers correctly, handles frame completion, and drives the correct per-core inputs.

- `tb_iter_core_array.sv` verifies the multi-core wrapper around the individual `iter_core` instances, including result collection and ready/valid behaviour across multiple cores.

- `arbiter_tb.sv` tests the result arbiter that selects between completed outputs from multiple cores. It checks round-robin selection, backpressure handling, and that only the selected core receives `ready`.

- `reorder_buffer_tb.sv` checks that out-of-order core results are stored and emitted in the correct sequence order before being sent to the colour pipeline.

- `colour_palette_tb.sv` verifies the basic colour mapping stage, including escaped pixels, in-set pixels, overflow/debug colouring, output valid/ready behaviour, and stall handling.

- `scheduler_iter_core_tb.sv` provides an integration test between the scheduler and the iteration cores, confirming that scheduled pixels are processed correctly across multiple cores.

Overall, the testbenches now cover both individual module behaviour and larger subsystem integration. This gives us much more confidence that the compute pipeline works before moving to synthesis, implementation, and hardware testing.

### Number Precision Study

A separate number precision study was carried out to decide what fixed-point format should be used for the fractal calculations. This was important because the design needs enough precision for visually stable zooming, while still fitting efficiently on the FPGA.

The study compares different fixed-point formats and considers the trade-off between:

- numerical accuracy
- visual quality of the generated fractals
- DSP/LUT resource usage
- timing closure difficulty
- maximum zoom depth

From this, we chose to use a Q4.22-style representation for the main complex-number datapath. This gives 26-bit signed fixed-point values, with enough fractional precision for the current MVP while keeping the arithmetic manageable for the PYNQ-Z1.
 

More detail is available in the dedicated precision write-up: [Number Precision Study](../studies/number_format/README.md).

### CPU Baseline

In starting the CPU_baseline design, the following implementations were made:

- The formation of a naive single-threaded approach to understand a worst-case scenario.

- A multi-threaded approach to obtain the best-case cpu scenario, both with actual manual tests and a C++ `std::thread::hardware_concurrency()` insturction to obtain the optimal number of threads for latency reduction

- Functions allowing for the calculation of multiple sets mirroring those in `iter_core_tb.sv`

### PS start

Since the RTL is still not complete, we haven't started proper work on the PS side yet. We looked a little into displaying a Mandelbrot set through the PYNQ board, but not much further that that. The notebook can be seen here: [Basic Display](../../notebooks/1_basic_display.ipynb).

### Updates to Plan/Timeline and Evaluation

In terms of the RTL, the next steps for the following week are as such:

- **Have a working display** - This is a core goal that we plan to have achieved ASAP

- Timing analysis between hardware & software based designs - average speedup/ total latency calculations of our v1 design

- Cleaned up cpu_baseline - i.e. separate filing for timing analysis and actual implementation - low priority but still should be achieved

- Resource optimisation of the v1 design - crucial as this allows us to implement extension ideas without worrying about resource demand

- Extension & Presentation Planning - Interim presentations are coming up in a weeks time therfore having a plan of what we will present and how we plan to expand our base design is key

## EEE Team