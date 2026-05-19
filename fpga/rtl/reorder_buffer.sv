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
    parameter int BUFFER_SIZE = 256
)(
    input logic                clk,
    input logic                rst,
    input logic                palette_ready,

    // Inputs from iter_core
    input logic [ITER_W-1:0]  in_iter_count,
    input logic [SEQ_W-1:0]   in_seq_num,
    input logic signed [W-1:0]in_z_r,
    input logic signed [W-1:0]in_z_i,
    input logic               in_escaped,
    input logic               in_overflow,
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
    logic  [ITER_W-1:0]  in_iter_count;
    logic  [SEQ_W-1:0]   in_seq_num;
    logic signed [W-1:0] in_z_r;
    logic signed [W-1:0] in_z_i;
    logic                in_escaped;
    logic                in_overflow;
} pixel_buffer;

pixel_buffer order_buffer [BUFFER_SIZE-1:0];

// index assignment

assign wr_index =in_seq_num[BUFFER_INDEX-1:0];
assign re_index = exp_seq_num[BUFFER_INDEX-1:0];

assign out_ready = !valid[wr_index];


always_ff @(posedge clk) begin

    if(rst) begin
        exp_seq_num <= 0;
        out_valid <= 0;
        out_iter_count <= 0;
        out_seq_num    <= 0;
        out_z_r        <= 0;
        out_z_i        <= 0;
        out_escaped    <= 0;
        out_overflow   <= 0;
        for(int i = 0; i<BUFFER_SIZE; i++) valid[i] <= 0;
    end
    else begin

        // Write Path
        if(in_valid && out_ready) begin
            order_buffer[wr_index].in_iter_count <=in_iter_count;
            order_buffer[wr_index].in_seq_num <=in_seq_num;
            order_buffer[wr_index].in_z_r <=in_z_r;
            order_buffer[wr_index].in_z_i <=in_z_i;
            order_buffer[wr_index].in_escaped <=in_escaped;
            order_buffer[wr_index].in_overflow <=in_overflow;
            valid[wr_index] <= 1'b1;
        end

        // Read Path
        if(out_valid && palette_ready) begin
            valid[re_index] <= 1'b0;
            exp_seq_num     <= exp_seq_num + 1'b1;
                
                if (valid[re_index + 1'b1]) begin
                    out_valid      <= 1'b1;
                    out_iter_count <= order_buffer[re_index + 1'b1].in_iter_count;
                    out_seq_num    <= order_buffer[re_index + 1'b1].in_seq_num;
                    out_z_r        <= order_buffer[re_index + 1'b1].in_z_r;
                    out_z_i        <= order_buffer[re_index + 1'b1].in_z_i;
                    out_escaped    <= order_buffer[re_index + 1'b1].in_escaped;
                    out_overflow   <= order_buffer[re_index + 1'b1].in_overflow;
                end else begin
                    out_valid      <= 1'b0;
                end
        end
        else if(valid[re_index]) begin
            out_valid <= 1'b1;
            out_iter_count <= order_buffer[re_index].in_iter_count;
            out_seq_num <= order_buffer[re_index].in_seq_num;
            out_z_r <= order_buffer[re_index].in_z_r;
            out_z_i <= order_buffer[re_index].in_z_i;
            out_escaped <= order_buffer[re_index].in_escaped;
            out_overflow <= order_buffer[re_index].in_overflow;
            end
            else out_valid <= 1'b0;
    end          
end
            
endmodule