`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
// 
// Create Date: 28.05.2026
// Design Name: Reorder Buffer
// Module Name: reorder_buffer
// Project Name: FractalScope
// Target Devices: PYNQ-Z1
// Tool Versions: Vivado 2023.2
// Description: Buffers and reorders pixel results from the iteration cores to 
//              ensure they are sent to the palette LUT in the correct sequence 
//              for display. It handles out-of-order completion of pixel computations, 
//              ensuring that the output stream to the palette is correctly ordered 
//              by pixel sequence number.
// 
// Dependencies: None
//
// Additional Comments: None
////////////////////////////////////////////////////////////////////////////////// 

module reorder_buffer#(
    parameter int W      = 26,
    parameter int ITER_W = 16,
    parameter int SEQ_W  = 16,
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

logic [ITER_W-1:0]   buf_iter_count [BUFFER_SIZE-1:0];
logic [SEQ_W-1:0]    buf_seq_num    [BUFFER_SIZE-1:0];
logic signed [W-1:0] buf_z_r        [BUFFER_SIZE-1:0];
logic signed [W-1:0] buf_z_i        [BUFFER_SIZE-1:0];
logic                buf_escaped    [BUFFER_SIZE-1:0];
logic                buf_overflow   [BUFFER_SIZE-1:0];

// index assignment

assign wr_index =in_seq_num[BUFFER_INDEX-1:0];
assign re_index = exp_seq_num[BUFFER_INDEX-1:0];

logic [BUFFER_INDEX:0] occupancy;
// The buffer is ready as long as it isn't completely full
assign out_ready = (occupancy < BUFFER_SIZE);

// Read Path

assign out_valid      = (valid[re_index] && (buf_seq_num[re_index] == exp_seq_num));
    
assign out_iter_count = buf_iter_count[re_index];
assign out_seq_num    = buf_seq_num[re_index];
assign out_z_r        = buf_z_r[re_index];
assign out_z_i        = buf_z_i[re_index];
assign out_escaped    = buf_escaped[re_index];
assign out_overflow   = buf_overflow[re_index];

assign out_sof        = (out_valid && out_seq_num == 16'd0);
assign out_hit_max    = out_valid && !out_escaped;

logic [11:0] x_cnt;

// Track the x coordinate for EOL signaling. Increment on every valid output pixel.
always_ff @(posedge clk) begin
    if (!rst_n) begin
        x_cnt <= '0;
    end else if (out_valid && palette_ready) begin
        if (x_cnt == SCREEN_W - 1)
            x_cnt <= '0;
        else
            x_cnt <= x_cnt + 1;
    end
end

assign out_eol = (x_cnt == SCREEN_W - 1);

// Next valid logic: Set on write, clear on read. Write takes priority if both happen on same cycle.  
always_comb begin
        next_valid = valid;
        
        if (out_valid && palette_ready) begin
            next_valid[re_index] = 1'b0; // Clear on read
        end
        if (in_valid && out_ready) begin
            next_valid[wr_index] = 1'b1; // Set on write (Write overrides read on same index)
        end
    end

// Sequential logic for buffer management and occupancy tracking
always_ff @(posedge clk) begin
    if(!rst_n) begin
        exp_seq_num <= 0;
        valid <= 0;
        occupancy <= 0;
    end
    else begin
        valid <= next_valid;

        if(out_valid && palette_ready) begin
            exp_seq_num <= exp_seq_num + 1;
        end

        //  Occupancy Tracking
        
        // Both write and read happen
        if ((in_valid && out_ready) && (out_valid && palette_ready)) begin
            occupancy <= occupancy; // Net zero change
        end
        // Only a write happens (pixel enters buffer)
        else if (in_valid && out_ready) begin
            occupancy <= occupancy + 1;
        end
        // Only a read happens (pixel leaves buffer)
        else if (out_valid && palette_ready) begin
            occupancy <= occupancy - 1;
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