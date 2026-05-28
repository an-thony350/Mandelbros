`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
// 
// Create Date: 28.05.2026
// Design Name: Performance Counters
// Module Name: perf_counters
// Project Name: FractalScope
// Target Devices: PYNQ-Z1
// Tool Versions: Vivado 2023.2
// Description: Module to track performance counters for the fractal iteration process, 
//              including frame cycles, total iterations, pixels escaped, and pixels 
//              that hit the maximum iteration count. Counters are updated on each pixel 
//              processed and snapshotted at the start of each new frame.
// 
// Dependencies: None
//
// Additional Comments: None
////////////////////////////////////////////////////////////////////////////////// 

module perf_counters#(
    parameter ITER_W = 16
)(

    input logic              clk,
    input logic              rst_n,
    // inputs from reorder buffer output

    input logic              stream_valid,
    input logic              stream_ready,
    input logic              sof_pulse,
    input logic [ITER_W-1:0] pixel_iter,
    input logic              pixel_escaped,
    input logic              pixel_hit_max,

    // outputs to AXI-Lite

    output logic [31:0]     snap_frame_cycles,
    output logic [63:0]     snap_total_iters,
    output logic [31:0]     snap_pixels_escaped,
    output logic [31:0]     snap_pixels_hit_max
);

// Temporary, running counters

logic [31:0] tmp_frame_cycles;
logic [63:0] tmp_total_iters;
logic [31:0] tmp_pixels_escaped;
logic [31:0] tmp_pixels_hit_max;


always_ff @(posedge clk) begin
    if(!rst_n) begin
        tmp_frame_cycles <= 0;
        tmp_total_iters <= 0;
        tmp_pixels_escaped <= 0;
        tmp_pixels_hit_max <= 0;
        snap_frame_cycles <= 0;
        snap_total_iters <= 0;
        snap_pixels_escaped <= 0;
        snap_pixels_hit_max <= 0;
    end
    else begin
        if(sof_pulse) begin
            snap_frame_cycles   <= tmp_frame_cycles;
            snap_total_iters    <= tmp_total_iters;
            snap_pixels_escaped <= tmp_pixels_escaped;
            snap_pixels_hit_max <= tmp_pixels_hit_max;

            tmp_frame_cycles <= 1'b1;
                
            if (stream_valid && stream_ready) begin
                tmp_total_iters    <= pixel_iter;
                tmp_pixels_escaped <= pixel_escaped ? 1'b1 : '0;
                tmp_pixels_hit_max <= pixel_hit_max ? 1'b1 : '0;
            end else begin
                tmp_total_iters    <= 0;
                tmp_pixels_escaped <= 0;
                tmp_pixels_hit_max <= 0;
            end
        end
        else begin
            tmp_frame_cycles <= tmp_frame_cycles + 1'b1;

            if (stream_valid && stream_ready) begin
                tmp_total_iters <= tmp_total_iters + pixel_iter;
                    
                if (pixel_escaped) begin
                    tmp_pixels_escaped <= tmp_pixels_escaped + 1'b1;
                end
                    
                if (pixel_hit_max) begin
                    tmp_pixels_hit_max <= tmp_pixels_hit_max + 1'b1;
                end
            end
        end
    end
end

endmodule

