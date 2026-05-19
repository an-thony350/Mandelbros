`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: The Mandelbros
// Engineer: Denzil Erza-Essien
// 
// Create Date: 19.05.2026 12:43:35
// Design Name: 
// Module Name: pix_gen_tb
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: pixel_generator.sv
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module pix_generator_tb;

localparam int W = 26;
localparam int SEQ_W = 16;
localparam int ITER_W = 16;
localparam int MODE_W = 3;
parameter clock_div = 10;

reg   clk = 0; 
reg   rst;
reg   in_ready;
  
reg   signed [W-1:0] in_c_r;
reg   signed [W-1:0] in_c_i;
reg   signed [W-1:0] in_z0_r;
reg   signed [W-1:0] in_z0_i;
reg   [ITER_W-1:0]   in_max_iter;
reg   [MODE_W-1:0]   in_mode;
reg   [SEQ_W-1:0]    in_seq;
    
wire signed [W-1:0] out_c_r;
wire signed [W-1:0] out_c_i;
wire signed [W-1:0] out_z0_r;
wire signed [W-1:0] out_z0_i;
wire [ITER_W-1:0]   out_max_iter;
wire [MODE_W-1:0]   out_mode;
wire [SEQ_W-1:0]    out_seq;
wire                out_valid;

pixel_generator pixel_generator(
    .clk(clk),           
    .rst(rst),            
    .in_ready(in_ready),   
    .in_c_r(in_c_r),
    .in_c_i(in_c_i),
    .in_z0_r(in_z0_r),
    .in_z0_i(in_z0_i),
    .in_max_iter(in_max_iter),
    .in_mode(in_mode),
    .in_seq(in_seq),
    .out_c_r(out_c_r),
    .out_c_i(out_c_i),
    .out_z0_r(out_z0_r),
    .out_z0_i(out_z0_i),
    .out_max_iter(out_max_iter),
    .out_mode(out_mode),
    .out_seq(out_seq),
    .out_valid(out_valid)
);
    
always #(clock_div) clk = ~clk;

initial begin
    // Initialize control signals
    rst = 1;
    in_ready = 0;
    
    // Initialize data inputs
    in_c_r = 0; 
    in_c_i = 0; 
    in_z0_r = 0; 
    in_z0_i = 0;
    in_max_iter = 0; 
    in_mode = 0; 
    in_seq = 0;

    #25; // Hold reset for a couple of clock cycles
    rst = 0;
    
    @(posedge clk);
    #1;
    in_c_r = 26'd100;
    in_c_i = 26'd50;
    in_z0_r = 26'd25;
    in_z0_i = 26'd75;
    in_max_iter = 16'd20;
    in_mode = 3'd1;
    in_seq = 16'd80;
    in_ready = 1;

    @(posedge out_valid);
    #50;
    $finish;
end

endmodule