`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 19.05.2026 17:48:00
// Design Name: 
// Module Name: 
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module perf_counters#(
    parameter ITER_W = 16
)(

    input logic              clk,
    input logic              rst,
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
    if(rst) begin
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

            tmp_frame_cycles <= 0;
            tmp_total_iters <= 0;
            tmp_pixels_escaped <= 0;
            tmp_pixels_hit_max <= 0;
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
