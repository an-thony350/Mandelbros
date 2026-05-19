`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: The Mandelbros
// Engineer: Denzil Erza-Essien
// 
// Create Date: 19.05.2026 15:09:37
// Design Name: Reorder Buffer
// Module Name: reoroder_buffer
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




module reorder_buffer#(
    parameter int W      = 26,
    parameter int ITER_W = 16,
    parameter int SEQ_W  = 16,
    parameter int BUFFER_SIZE
)(
    input logic                clk,
    input logic                rst,
    input logic                in_ready,

    // Inputs from iter_core
    input logic [ITER_W-1:0]   iter_count,
    input logic [SEQ_W-1:0]    seq_num,
    input logic signed [W-1:0] z_r,
    input logic signed [W-1:0] z_i,
    input logic                escaped,
    input logic                overflow,
    input logic                in_valid,

    // Output to iter_core
    output logic               out_ready,

    // Output to Palette LUT

    output logic [ITER_W-1:0]   out_iter_count,
    output logic [SEQ_W-1:0]    out_seq_num,
    output logic signed [W-1:0] out_z_r,
    output logic signed [W-1:0] out_z_i,
    output logic                out_escaped,
    output logic                out_overflow,
    output logic                out_valid
);

// Internal signals & buffer

logic valid [BUFFER_SIZE-1:0];
logic [SEQ_W-1:0] exp_seq_num;

localparam BUFFER_INDEX = $clog2(BUFFER_SIZE);
logic [BUFFER_INDEX-1:0] wr_index;
logic [BUFFER_INDEX-1:0] re_index;

typedef struct packed{
    logic  [ITER_W-1:0]   iter_count;
    logic  [SEQ_W-1:0]    seq_num;
    logic signed [W-1:0]  z_r;
    logic signed [W-1:0]  z_i;
    logic                 escaped;
    logic                 overflow;
} pixel_buffer;

pixel_buffer order_buffer [BUFFER_SIZE-1:0];

// index assignment

assign wr_index = seq_num[BUFFER_INDEX-1:0];
assign re_index = exp_seq_num[BUFFER_INDEX-1:0];

assign out_ready = 1;


always_ff @(posedge clk) begin

    if(rst) begin
        exp_seq_num <= 0;
        out_valid <= 0;
        for(int i = 0; i<BUFFER_SIZE; i++) valid[i] <= 0;
    end

    // Write Path
    if(in_valid) begin
        order_buffer[wr_index].iter_count <= iter_count;
        order_buffer[wr_index].seq_num <= seq_num;
        order_buffer[wr_index].z_r <= z_r;
        order_buffer[wr_index].z_i <= z_i;
        order_buffer[wr_index].escaped <= escaped;
        order_buffer[wr_index].overflow <= overflow;
        valid[wr_index] <= 1'b1;
    end

    // Read Path
    if(valid[re_index]) begin
        out_valid <= 1'b1;

        if(in_ready && out_valid) begin
            
end
            
endmodule