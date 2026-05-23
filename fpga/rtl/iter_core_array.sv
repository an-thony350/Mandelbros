
// Given vivado handles arrays poorly, we unpack the array in this module and pass values to iter_core

`timescale 1ns / 1ps

module iter_core_array #(
    parameter int NUM_CORES = 32,
    parameter int W         = 26,
    parameter int FRAC      = 22,
    parameter int SEQ_W     = 20,
    parameter int ITER_W    = 16,
    parameter int MODE_W    = 3,
    parameter logic [W-1:0] ESCAPE_THRESH_Q422 = 26'sh100_0000 
)(
    input  wire clk,
    input  wire rst_n,

    // Inputs from Pixel Scheduler
    input  wire [NUM_CORES-1:0]          in_valid,
    input  wire [(W*NUM_CORES)-1:0]      c_r,
    input  wire [(W*NUM_CORES)-1:0]      c_i,
    input  wire [(W*NUM_CORES)-1:0]      z0_r,
    input  wire [(W*NUM_CORES)-1:0]      z0_i,
    input  wire [(ITER_W*NUM_CORES)-1:0] in_max_iter,
    input  wire [(MODE_W*NUM_CORES)-1:0] in_mode,
    input  wire [(SEQ_W*NUM_CORES)-1:0]  in_seq,

    // Outputs back to Pixel Scheduler
    output wire [NUM_CORES-1:0]          in_ready,

    // Inputs from Reorder Buffer
    input  wire               out_ready,

    // Outputs to Reorder Buffer
    output wire               out_valid,
    output wire  [SEQ_W-1:0]  out_seq,
    output wire  [ITER_W-1:0] out_iter,
    output wire  [W-1:0]      out_z_r,
    output wire  [W-1:0]      out_z_i,
    output wire               out_escaped,
    output wire               out_overflow
);

// Internal wires for core->arbiter connection

logic [NUM_CORES-1:0] core_out_valid;
logic [NUM_CORES-1:0] core_out_ready;
logic [(SEQ_W*NUM_CORES)-1:0] core_out_seq;
logic [(ITER_W*NUM_CORES)-1:0] core_out_iter;
logic [(W*NUM_CORES)-1:0] core_out_z_r;
logic [(W*NUM_CORES)-1:0] core_out_z_i;
logic [(W*NUM_CORES)-1:0] core_out_escaped;
logic [(W*NUM_CORES)-1:0] core_out_overflow;

// iter_core blocks


    generate
        for (genvar i = 0; i < NUM_CORES; i++) begin : core_gen
            
            iter_core #(
                .W(W),
                .FRAC(FRAC),
                .SEQ_W(SEQ_W),
                .ITER_W(ITER_W),
                .MODE_W(MODE_W),
                .ESCAPE_THRESH_Q422(ESCAPE_THRESH_Q422)
            ) single_core (
                .clk(clk),
                .rst_n(rst_n),

                // Scheduler Handshake
                .in_ready   ( in_ready[i] ),
                .in_valid   ( in_valid[i] ),
                
                // Sliced Inputs
                .in_c_r     ( c_r[(i*W) +: W] ),
                .in_c_i     ( c_i[(i*W) +: W] ),
                .in_z0_r    ( z0_r[(i*W) +: W] ),
                .in_z0_i    ( z0_i[(i*W) +: W] ),
                .in_max_iter( in_max_iter[(i*ITER_W) +: ITER_W] ),
                .in_mode    ( in_mode[(i*MODE_W) +: MODE_W] ),
                .in_seq     ( in_seq[(i*SEQ_W) +: SEQ_W] ),

                // Reorder Buffer Handshake
                .out_ready  ( out_ready[i] ),
                .out_valid  ( out_valid[i] ),
                
                // Sliced Outputs
                .out_seq    ( out_seq[(i*SEQ_W) +: SEQ_W] ),
                .out_iter   ( out_iter[(i*ITER_W) +: ITER_W] ),
                .out_z_r    ( out_z_r[(i*W) +: W] ),
                .out_z_i    ( out_z_i[(i*W) +: W] ),
                .out_escaped( out_escaped[i] ),
                .out_overflow( out_overflow[i] )
            );
            
        end
    endgenerate


    result_arbiter#(
        .NUM_CORES(NUM_CORES),
        .W(W),
        .ITER_W(ITER_W),
        .SEQ_w(SEQ_W)
    ) arbiter(
        .clk(clk),
        .rst(rst),
        .core_out_valid(core_out_valid),
        .core_out_ready(core_out_ready),
        .core_out_seq(core_out_seq),
        .core_out_iter(core_out_iter),
        .core_out_z_r(core_out_z_r),
        .core_out_z_i(core_out_z_i),
        .core_out_escaped(core_out_escaped),
        .core_out_overflow(core_out_overflow),
        
        .rob_in_valid(out_valid),
        .rob_in_ready(out_ready),
        .rob_in_iter_count(out_iter_count),
        .rob_in_seq_num(out_seq),
        .rob_in_z_r(out_z_r),
        .rob_in_z_i(out_z_i),
        .rob_in_escaped(out_escaped),
        .rob_in_overflow(out_overflow)
    );

endmodule
