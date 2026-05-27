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
    parameter int SEQ_W  = 20,
    parameter int BUFFER_SIZE = 4096,
    parameter int SCREEN_W = 1280,
    parameter int MAX_ITER = 256
)(
    input logic                clk,
    input logic                rst_n,
    input logic                palette_ready,

    // Inputs from iter_core
    input logic [ITER_W-1:0]  in_iter_count,
    input logic [SEQ_W-1:0]   in_seq_num,
    input logic signed [W-1:0] in_z_r,
    input logic signed [W-1:0] in_z_i,
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
    output logic                out_valid,
    
    // Outputs to packer
    output logic                out_sof,
    output logic                out_eol,
    
    // Output to perf counter
    output logic                out_hit_max
);

// Internal signals & buffer

logic [BUFFER_SIZE-1:0] valid;
logic [BUFFER_SIZE-1:0]    next_valid;
logic [SEQ_W-1:0] exp_seq_num;

localparam BUFFER_INDEX = $clog2(BUFFER_SIZE);
logic [BUFFER_INDEX-1:0] wr_index;
logic [BUFFER_INDEX-1:0] re_index;

localparam int X_CNT_W = (SCREEN_W <= 1) ? 1 : $clog2(SCREEN_W);
logic [X_CNT_W-1:0] out_x;

logic [ITER_W-1:0]   buf_iter_count [BUFFER_SIZE-1:0];
logic [SEQ_W-1:0]    buf_seq_num    [BUFFER_SIZE-1:0];
logic signed [W-1:0] buf_z_r        [BUFFER_SIZE-1:0];
logic signed [W-1:0] buf_z_i        [BUFFER_SIZE-1:0];
logic                buf_escaped    [BUFFER_SIZE-1:0];
logic                buf_overflow   [BUFFER_SIZE-1:0];

// index assignment

assign wr_index =in_seq_num[BUFFER_INDEX-1:0];
assign re_index = exp_seq_num[BUFFER_INDEX-1:0];

assign out_ready = !valid[wr_index];


// Read Path

assign out_valid      = (valid[re_index] && (buf_seq_num[re_index] == exp_seq_num));
    
assign out_iter_count = buf_iter_count[re_index];
assign out_seq_num    = buf_seq_num[re_index];
assign out_z_r        = buf_z_r[re_index];
assign out_z_i        = buf_z_i[re_index];
assign out_escaped    = buf_escaped[re_index];
assign out_overflow   = buf_overflow[re_index];

assign out_sof        = out_valid && (out_seq_num == '0);
assign out_eol        = out_valid && (out_x == X_CNT_W'(SCREEN_W-1));
assign out_hit_max    = out_valid && !out_escaped;

  
always_comb begin
        next_valid = valid;
        
        if (out_valid && palette_ready) begin
            next_valid[re_index] = 1'b0; // Clear on read
        end
        if (in_valid && out_ready) begin
            next_valid[wr_index] = 1'b1; // Set on write (Write overrides read on same index)
        end
    end

always_ff @(posedge clk) begin

    if(!rst_n) begin
        exp_seq_num <= 0;
        out_x <= '0;
        valid <= 0;
    end
    else begin
        valid <= next_valid;

        if(out_valid && palette_ready) begin
            exp_seq_num <= exp_seq_num + 1;
            if (out_x == X_CNT_W'(SCREEN_W-1)) begin
                out_x <= '0;
            end
            else begin
                out_x <= out_x + 1'b1;
            end
        end

        // Write Path
        if(in_valid && out_ready) begin
            buf_iter_count[wr_index] <= in_iter_count;
            buf_seq_num[wr_index]    <= in_seq_num;
            buf_z_r[wr_index]        <= in_z_r;
            buf_z_i[wr_index]        <= in_z_i;
            buf_escaped[wr_index]    <= in_escaped;
            buf_overflow[wr_index]   <= in_overflow;
        end
    end       
end
            
endmodule