module colour_palette #(
    parameter int W      = 26,
    parameter int ITER_W = 16,
    parameter int SEQ_W  = 20
)(
    input logic clk,
    input logic rst,

    // Input from reorder buffer
    input  logic                in_valid,
    output logic                in_ready,

    input  logic [ITER_W-1:0]   in_iter_count,
    input  logic [SEQ_W-1:0]    in_seq_num,
    input  logic signed [W-1:0] in_z_r,
    input  logic signed [W-1:0] in_z_i,
    input  logic                in_escaped,
    input  logic                in_overflow,

    // Output to framebuffer / pixel writer
    output logic                out_valid,
    input  logic                out_ready,

    output logic [SEQ_W-1:0]    out_seq_num,
    output logic [7:0]          out_r,
    output logic [7:0]          out_g,
    output logic [7:0]          out_b
);