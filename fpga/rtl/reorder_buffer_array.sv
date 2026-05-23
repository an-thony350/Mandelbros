`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 22.05.2026 15:49:43
// Design Name: 
// Module Name: reorder_buffer_array
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


module reorder_buffer_array#(
    parameter int NUM_CORES = 32,
    parameter int W      = 26,
    parameter int ITER_W = 16,
    parameter int SEQ_W  = 20,
    parameter int BUFFER_SIZE = 4096
)(
    input logic     clk,
    input logic     rst,
    input logic  [NUM_CORES-1:0]            palette_ready,
    
    input logic [(ITER_W*NUM_CORES)-1:0]    in_iter_count,
    input logic [(SEQ_W*NUM_CORES)-1:0]     in_seq_num,
    input logic signed [(W*NUM_CORES)-1:0]  in_z_r,
    input logic signed [(W*NUM_CORES)-1:0]  in_z_i,
    input logic        [NUM_CORES-1:0]      in_escaped,
    input logic        [NUM_CORES-1:0]      in_overflow,
    input logic        [NUM_CORES-1:0]      in_valid,
    
    output logic    [NUM_CORES-1:0]         out_ready,
    
    output logic  [(ITER_W*NUM_CORES)-1:0] out_iter_count,
    output logic  [(SEQ_W*NUM_CORES)-1:0]  out_seq_num,
    output logic signed[(W*NUM_CORES)-1:0] out_z_r,
    output logic signed[(W*NUM_CORES)-1:0] out_z_i,
    output logic [NUM_CORES-1:0]           out_escaped,
    output logic [NUM_CORES-1:0]           out_overflow,
    output logic [NUM_CORES-1:0]           out_valid          
    );
    
    
    generate
        for(genvar i = 0; i < NUM_CORES; i++) begin : buffer_gen
        
            reorder_buffer#(
                .W(W),
                .ITER_W(ITER_W),
                .SEQ_W(SEQ_W),
                .BUFFER_SIZE(BUFFER_SIZE)
            ) single_buffer (
                .clk(clk),
                .rst(rst),
                .palette_ready(palette_ready[i]),
                
                .in_iter_count( in_iter_count[(i*ITER_W) +: ITER_W] ),
                .in_seq_num( in_seq_num[(i*SEQ_W) +: SEQ_W] ),
                .in_z_r( in_z_r[(i*W) +: W] ),
                .in_z_i( in_z_i[(i*W) +: W] ),
                .in_escaped(in_escaped[i]),
                .in_overflow(in_overflow[i]),
                .in_valid(in_valid[i]),
                
                .out_ready(out_ready[i]),
                
                .out_iter_count( out_iter_count[ (i*ITER_W) +: ITER_W]),
                .out_seq_num( out_seq_num[(i*SEQ_W) +: SEQ_W] ),
                .out_z_r( out_z_r[(i*W) +: W] ),
                .out_z_i( out_z_i[(i*W) +: W] ),
                .out_escaped(out_escaped[i]),
                .out_overflow(out_overflow[i]),
                .out_valid(out_valid[i])
            );
            end
        endgenerate
        
endmodule
