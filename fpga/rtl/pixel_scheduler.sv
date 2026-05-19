`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: The Mandelbros
// Engineer: Denzil Erza-Essien
// 
// Create Date: 19.05.2026 14:13:19
// Design Name: Pixel Scheduler
// Module Name: Pixel_Scheduler
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

module pixel_scheduler #(
    parameter int NUM_CORES            = 32,
    parameter int W                    = 26,
    parameter int SEQ_W                = 16,
    parameter int ITER_W               = 16,
    parameter int MODE_W               = 3,
    parameter int X_RES                = 1280,
    parameter int Y_RES                = 720
)(
    input logic                        clk,
    input logic                        rst,

    // pixel input logic

    input logic  signed [W-1:0]         x_jump,
    input logic  signed [W-1:0]         y_jump,
    input logic  signed [W-1:0]         x_min, // Used for the graph of the set
    input logic  signed [W-1:0]         y_min,
    input logic                         last_pixel,

    // Julia & Selection input parameters

    input logic  signed [W-1:0]         jul_c_r,
    input logic  signed [W-1:0]         jul_c_i,
    input logic  [ITER_W-1:0]           in_max_iter,
    input logic  [MODE_W-1:0]           in_mode,


    // Core logic (i.e. outputs to core)

    input logic [NUM_CORES-1:0]         in_ready,
    output logic [NUM_CORES-1:0]        in_valid,
    output logic signed [W-1:0]         c_r  [NUM_CORES],
    output logic signed [W-1:0]         c_i  [NUM_CORES],
    output logic signed [W-1:0]         z0_r [NUM_CORES],
    output logic signed [W-1:0]         z0_i [NUM_CORES],
    output logic [ITER_W-1:0]           out_max_iter [N_CORES],
    output logic [MODE_W-1:0]           out_mode     [N_CORES],
    output logic [SEQ_W-1:0]            out_seq      [N_CORES],
   

);


// Chosen core logic

logic [$clog2(NUM_CORES)-1:0] chosen_core;
logic                         available_core;
assign available_core = |chosen_core;

// see if this can be optimised

always_comb begin
    chosen_core = 0;
    for(int i = NUM_CORES-1; i >= 0; i--) begin
        if(in_ready[i]) chosen_core = i[$clog2(NUM_CORES)-1:0];
    end
end


// Temporary pixel registers

logic signed [W-1:0]  pixel_c_r;
logic signed [W-1:0]  pixel_c_i;
logic signed [W-1:0]  pixel_z0_r,;
logic signed [W-1:0]  pixel_z0_i;
logic [$clog2(X_RES)-1:0] x;
logic [$clog2(Y_RES)-1:0] y;
logic [SEQ_W-1:0]         seq;

// Julia checking logic
// Note that we assume julia value is at 3'd1

if(in_mode == 3'd1) begin
    pixel_c_r = jul_c_r;
    pixel_c_i = jul_c_i;
    pixel_z0_r = c_r;
    pixel_z0_i = c_i;
end
else begin
    pixel_c_r = c_r;
    pixel_c_i = c_i;
    pixel_z0_r = 26'b0;
    pixel_z0_i = 26'b0;
end

// Core parsing logic

for(genvar i = 0; i < NUM_CORES; i++) begin : core_parse
    assign out_c_r[i]       =       pixel_c_r;
    assign out_c_i[i]       =       pixel_c_i;
    assign put_z0_r[i]      =       pixel_z0_r;
    assign put_z0_i[i]      =       pixel_z0_i;
    assign out_max_iter[i]  =       in_max_iter;
    assign out_mode[i]      =       in_mode;
    assign out_seq[i]       =       seq;
    assign out_valid[i]     =       available_core && (chosen_core == i[$clog2(NUM_CORES)-1:0]);
end

// Last Pixel logic

assign last_pixel = available_core && (x == X_RES-1) &&(y == Y_RES);

// Pixel gen sequential logic

always_ff @(posedge clk) begin
    if(rst) begin
        x <= 0;
        y <= 0;
        c_r <= x_min;
        c_i <= y_min;
        seq <= 16'd0;
    end
    else if(available_core) begin
        seq <= seq + 1;

        if(x == X_RES-1) begin
            x <= 0;
            c_r <= x_min;
            if(y == Y_RES-1) begin
                y <= 0;
                c_i <= y_min;
            end
            else begin
                y <= y + 1;
                c_i <= c_i + y_jump;
            end
        end
        else begin
            x <= x + 1;
            c_r <= c_r + x_jump;
        end
    end
end



endmodule
