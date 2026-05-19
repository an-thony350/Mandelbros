`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: The Mandelbros
// Engineer: Denzil Erza-Essien
// 
// Create Date: 19.05.2026 12:42:19
// Design Name: Pixel Scheduler
// Module Name: pix_gen
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: TBD
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module pixel_generator#(
    parameter int W             = 26,
    parameter int SEQ_W         = 16,
    parameter int ITER_W        = 16,
    parameter int MODE_W        = 3
)(
    // timing inputs
    input logic                 clk,
    input logic                 rst,
    input logic                 in_ready,

    // logic inputs
    input logic signed [W-1:0] in_c_r,
    input logic signed [W-1:0] in_c_i,
    input logic signed [W-1:0] in_z0_r,
    input logic signed [W-1:0] in_z0_i,
    input logic [ITER_W-1:0]   in_max_iter,
    input logic [MODE_W-1:0]   in_mode,
    input logic [SEQ_W-1:0]    in_seq,
    

    // logic outputs

    output logic signed [W-1:0] out_c_r,
    output logic signed [W-1:0] out_c_i,
    output logic signed [W-1:0] out_z0_r,
    output logic signed [W-1:0] out_z0_i,
    output logic [ITER_W-1:0]   out_max_iter,
    output logic [MODE_W-1:0]   out_mode,
    output logic [SEQ_W-1:0]    out_seq,
    output logic                out_valid


);

// clock logic for determining next pixel value

always_ff @(posedge clk) begin

    if(rst) begin
        out_c_r <= 0;
        out_c_i <= 0;
        out_z0_r <= 0;
        out_z0_i <= 0;
        out_max_iter <= 0;
        out_mode <= 0;
        out_seq <= 0;
        out_valid <= 0;
    end
    else if(in_ready) begin
        out_c_r <= in_c_r;
        out_c_i <= in_c_i;
        out_z0_r <= in_z0_r;
        out_z0_i <= in_z0_i;
        out_max_iter <= in_max_iter;
        out_mode <= in_mode;
        out_seq <= in_seq;
        out_valid <= 1'b1;
    end
    else out_valid <= 0;
end

endmodule

