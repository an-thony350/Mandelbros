// 5-stage pipelined fixed-point fractal iteration core.
// Computes either Tricorn, Burning Ship, Mandelbrot, or Julia iterations based on the mode field
// Iteration terminates when |z|^2 > 4 (escape) or iter == max_iter (in set).

`default_nettype none

module iter_core #(
    parameter int W       = 26,    
    parameter int FRAC    = 22,    
    parameter int SEQ_W   = 16,    
    parameter int ITER_W  = 16,    
    parameter int MODE_W  = 3,     
    parameter logic [W-1:0] ESCAPE_THRESH_Q422 = 26'sh100_0000  
) (
    input  logic                 clk,
    input  logic                 rst_n,

    // input handshake (from scheduler) 
    output logic                 in_ready,
    input  logic                 in_valid,
    input  logic signed [W-1:0]  in_c_r,
    input  logic signed [W-1:0]  in_c_i,
    input  logic signed [W-1:0]  in_z0_r,
    input  logic signed [W-1:0]  in_z0_i,
    input  logic [ITER_W-1:0]    in_max_iter,
    input  logic [MODE_W-1:0]    in_mode,
    input  logic [SEQ_W-1:0]     in_seq,

    // output handshake (to reorder buffer) 
    input  logic                 out_ready,
    output logic                 out_valid,
    output logic [SEQ_W-1:0]     out_seq,
    output logic [ITER_W-1:0]    out_iter,
    output logic signed [W-1:0]  out_z_r,
    output logic signed [W-1:0]  out_z_i,
    output logic                 out_escaped,
    output logic                 out_overflow
);

    // Mode enum (must match what the scheduler / regfile produces)

    localparam logic [MODE_W-1:0] MODE_MANDEL  = 3'd0;
    localparam logic [MODE_W-1:0] MODE_JULIA   = 3'd1;
    localparam logic [MODE_W-1:0] MODE_BURNING = 3'd2;
    localparam logic [MODE_W-1:0] MODE_TRICORN = 3'd3;

    // Slot payload carried through the pipeline

    typedef struct packed {
        logic                  valid;     // 0 = bubble
        logic [SEQ_W-1:0]      seq;
        logic [MODE_W-1:0]     mode;
        logic [ITER_W-1:0]     max_iter;
        logic [ITER_W-1:0]     iter;      // iterations completed so far
        logic signed [W-1:0]   c_r;
        logic signed [W-1:0]   c_i;
        logic signed [W-1:0]   z_r;
        logic signed [W-1:0]   z_i;
        logic                  overflow;  // sticky over this pixel's life
    } slot_t;

    // Pipeline registers: slot[0] = stage 0 input, ..., slot[4] = stage 4
    slot_t s0_r, s1_r, s2_r, s3_r, s4_r;

    // STAGE 1 : apply mode transform to z, prepare multiplier operands