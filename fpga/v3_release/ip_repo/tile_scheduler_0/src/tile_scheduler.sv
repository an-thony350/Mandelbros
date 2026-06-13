`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
// 
// Create Date: 04.06.2026
// Design Name: Tile Scheduler
// Module Name: tile_scheduler
// Project Name: FractalScope
// Target Devices: PYNQ-Z1
// Tool Versions: Vivado 2023.2
// Description: Sends a tile-based dispatch of pixels which have not been scheduled for pure raster-order
//              but rather depend on their pixel id
// 
// Dependencies: None
//
// Additional Comments: None
////////////////////////////////////////////////////////////////////////////////// 

module tile_scheduler#(
    parameter int NUM_CORES = 16,
    parameter int W         = 26,
    parameter int INDEX_W   = 21,
    parameter int ITER_W    = 16,
    parameter int MODE_W    = 3,
    parameter int X_RES     = 1280,
    parameter int Y_RES     = 720,
    parameter int TILE_W    = 32,
    parameter int TILE_H    = 16
)(
    input logic clk,
    input logic rst_n,

    // Parameters for pixel coordinate generation
    input logic signed [W-1:0] x_jump,
    input logic signed [W-1:0] y_jump,
    input logic signed [W-1:0] x_min,
    input logic signed [W-1:0] y_min,
    output logic               last_pixel,
    input logic        [3:0]   in_scale,

    // Parameters for Julia set (ignored for Mandelbrot)
    input logic signed [W-1:0] jul_c_r,
    input logic signed [W-1:0] jul_c_i,
    input logic [ITER_W-1:0]   in_max_iter,
    input logic [MODE_W-1:0]   in_mode,

    // Outputs to cores
    input  logic [NUM_CORES-1:0] in_ready,
    output logic [NUM_CORES-1:0] in_valid,

    // Pixel data outputs to cores
    output logic signed [(W*NUM_CORES)-1:0] c_r,
    output logic signed [(W*NUM_CORES)-1:0] c_i,
    output logic signed [(W*NUM_CORES)-1:0] z0_r,
    output logic signed [(W*NUM_CORES)-1:0] z0_i,
    output logic [(ITER_W*NUM_CORES)-1:0]   out_max_iter,
    output logic [(MODE_W*NUM_CORES)-1:0]   out_mode,
    output logic [(INDEX_W*NUM_CORES)-1:0]  out_pixel_index,
    
    output logic                            out_fill_valid,
    output logic [INDEX_W-2:0]              out_fill_index, // Note that index width is 1 higher as the top bit represents an is_perimeter flag
    output logic [ITER_W-1:0]               out_fill_iter,
    output logic                            out_fill_escaped,
    
    // Input from Iter_Core
    input  logic                            iter_in_valid,
    input  logic [ITER_W-1:0]               iter_in_iter,
    input  logic                            iter_in_is_perimeter,
    input  logic                            iter_in_escaped,
    input  logic                            iter_in_ready,
    
    // Input from Colour palette
    input  logic                            cp_in_fill_ready
);


    // Local parameters for internal calculations
    localparam int CORE_IDX_W = (NUM_CORES <= 1) ? 1 : $clog2(NUM_CORES);
    localparam int X_W        = (X_RES <= 1) ? 1 : $clog2(X_RES);
    localparam int Y_W        = (Y_RES <= 1) ? 1 : $clog2(Y_RES);
    localparam int SKIP_W     =  352; // chosen pixel width of ui
    localparam int SKIP_H     =  160; // chosen pixel height of ui

    localparam logic [MODE_W-1:0] MODE_JULIA = 3'd1; 

    // Internal signals
    logic [CORE_IDX_W-1:0] chosen_core;
    logic                  available_core;
    logic                  dispatch;
    logic                  frame_done;

    logic signed [W-1:0] cur_c_r;
    logic signed [W-1:0] cur_c_i;

    logic signed [W-1:0] pixel_c_r;
    logic signed [W-1:0] pixel_c_i;
    logic signed [W-1:0] pixel_z0_r;
    logic signed [W-1:0] pixel_z0_i;

    logic [X_W-1:0]      x;
    logic [Y_W-1:0]      y;
    logic [4:0]          x_tile; // Chosen to be 32 as it divides 1280 exactly into 40 tiles across
    logic [3:0]          y_tile; // Chosen to be 16 as it divides 720 exactly into 45 tiles
    logic [INDEX_W-1:0]  pixel_index;
    logic [X_W-1:0]      next_x;
    logic [Y_W-1:0]      next_y;
    
    logic               eval_is_uniform;
    logic               eval_done;
    logic               is_perimeter_pixel;
    logic               is_perimeter_flag;
    logic [ITER_W-1:0]  eval_latched_iter;
    logic               eval_latched_escaped;
    logic               out_fill_ready;

    logic [X_W-1:0]     draw_abs_x;
    logic [Y_W-1:0]     draw_abs_y;
    logic [X_W-1:0]     math_abs_x;
    logic [Y_W-1:0]     math_abs_y;
    
    logic [3:0]         half_scale;
    assign half_scale = in_scale >> 1;
    
    // State enumerator for tile state - Used for MS
    typedef enum {PERIMETER, EVALUATION, INTERIOR, FILL, NEXT_TILE} ms_state_t;
    
    ms_state_t tile_state;

    // combinational perimeter logic
    assign is_perimeter_pixel = (x_tile == 0) || (x_tile == TILE_W - in_scale) || (y_tile == 0) || (y_tile == TILE_H - in_scale);
    assign is_perimeter_flag  = (tile_state == PERIMETER);
    assign out_fill_ready     = !out_fill_valid || cp_in_fill_ready;
    
    // abs pixels and math coord combinational logic

    assign draw_abs_x = x + x_tile;
    assign draw_abs_y = y + y_tile;

    assign pixel_index = (draw_abs_y*X_RES) + draw_abs_x;

    assign math_abs_x = draw_abs_x + half_scale;
    assign math_abs_y = draw_abs_y + half_scale;

    assign cur_c_r = x_min + ($signed({1'b0, math_abs_x}) * x_jump);
    assign cur_c_i = y_min + ($signed({1'b0, math_abs_y}) * y_jump);
    
        
    // tile evaluation for MS
    tile_evaluator #(
        .ITER_W(ITER_W),
        .TILE_W(4)
    ) ms_evaluator(
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(iter_in_valid),
        .in_is_perimeter(iter_in_is_perimeter),
        .in_iter(iter_in_iter),
        .in_escaped(iter_in_escaped),
        .in_ready(iter_in_ready),
        .in_tile_id('0),
        .in_scale(in_scale),
        .out_tile_is_uniform(eval_is_uniform),
        .out_eval_done(eval_done),
        .out_eval_iter(eval_latched_iter),
        .out_eval_escaped(eval_latched_escaped)
    );
    
    always_comb begin
        if(x == X_RES - 32) begin
            next_x = 0;
            next_y = y + 16;
        end
        else begin
            next_x = x + 32;
            next_y = y;
        end
        
        // Dirty rectangle skip logic
        if(next_y < SKIP_H) begin
            if(next_x < SKIP_W) begin
                next_x = SKIP_W;
            end
            else if(next_x >= X_RES - SKIP_W) begin
                next_y = next_y + 16;
                if(next_y < SKIP_H) begin
                    next_x = SKIP_W;
                end 
                else begin
                    next_x = 0;
                end
            end    
        end 
    end
    
    
    
    // Core selection logic: Find the first available core
    assign available_core = |in_ready;
    assign dispatch       = rst_n && available_core && !frame_done;

    assign last_pixel = dispatch && (x == X_RES-1) && (y == Y_RES-1);

    always_comb begin
        chosen_core = '0;

        for (int i = 0; i < NUM_CORES; i++) begin
            if (in_ready[i]) begin
                chosen_core = CORE_IDX_W'(i);
            end
        end
    end

    // Pixel parameter assignment based on mode
    always_comb begin
        if (in_mode == MODE_JULIA) begin
            pixel_c_r  = jul_c_r;
            pixel_c_i  = jul_c_i;
            pixel_z0_r = cur_c_r;
            pixel_z0_i = cur_c_i;
        end
        else begin
            pixel_c_r  = cur_c_r;
            pixel_c_i  = cur_c_i;
            pixel_z0_r = '0;
            pixel_z0_i = '0;
        end
    end

    // Dispatch pixel parameters to the chosen core
    generate
        for (genvar gi = 0; gi < NUM_CORES; gi++) begin : core_parse

            assign c_r[(gi*W) +: W]               = pixel_c_r;
            assign c_i[(gi*W) +: W]               = pixel_c_i;
            assign z0_r[(gi*W) +: W]              = pixel_z0_r;
            assign z0_i[(gi*W) +: W]              = pixel_z0_i;
            assign out_max_iter[(gi*ITER_W) +: ITER_W] = in_max_iter;
            assign out_mode[(gi*MODE_W) +: MODE_W]     = in_mode;
            assign out_pixel_index[(gi*INDEX_W) +: INDEX_W]        = {is_perimeter_flag, pixel_index[19:0]};

            assign in_valid[gi] = dispatch && (chosen_core == gi) && ((tile_state == PERIMETER && is_perimeter_pixel) || (tile_state == INTERIOR && !is_perimeter_pixel));
        end
    endgenerate


    // Tile & Pixel tracker - also updated pixel index
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            tile_state  <= PERIMETER;
            x           <= SKIP_W;
            y           <= '0;
            x_tile      <= '0;
            y_tile      <= '0;
            frame_done  <= 1'b0;
        end
        else begin
            
            case(tile_state)
            
            PERIMETER: begin
                if(dispatch || !is_perimeter_pixel) begin
                    
                    if(x_tile == TILE_W - in_scale) begin
                        x_tile <= 0;
                        if(y_tile == TILE_H - in_scale) begin
                            y_tile <= 0;
                            tile_state <= EVALUATION;
                        end
                        else y_tile <= y_tile + in_scale;
                    end    
                    else x_tile <= x_tile + in_scale; 
                end
            end
            
            EVALUATION: begin
                if(eval_done) begin
                    if(eval_is_uniform) tile_state <= FILL;
                    else tile_state <= INTERIOR;
                end 
            end
            
            FILL: begin

                if(out_fill_ready || is_perimeter_pixel) begin 
                    if(x_tile == TILE_W - in_scale) begin
                            x_tile <= 0;
                            if(y_tile == TILE_H - in_scale) begin
                                y_tile <= 0;
                                tile_state <= NEXT_TILE;
                            end
                            else y_tile <= y_tile + in_scale;
                        end    
                        else x_tile <= x_tile + in_scale;
                end
            end
            
            INTERIOR: begin
                if(dispatch || is_perimeter_pixel) begin
                    
                    if(x_tile == TILE_W - in_scale) begin
                        x_tile <= 0;
                        if(y_tile == TILE_H - in_scale) begin
                            y_tile <= 0;
                            tile_state <= NEXT_TILE;
                        end
                        else y_tile <= y_tile + in_scale;
                    end    
                    else x_tile <= x_tile + in_scale; 
                end
            end
            
            NEXT_TILE: begin
                if(x == X_RES-32 && y == Y_RES-16) begin
                    frame_done <= 1'b1;
                end
                else begin
                    x          <= next_x;   
                    y          <= next_y; 
                    tile_state <= PERIMETER;
                end
            end                    
        endcase                             
    end
end

// 1-stage pipeline for MS fill - removes WNS issues

always_ff @(posedge clk) begin
    if (!rst_n) begin
        out_fill_valid   <= 1'b0;
        out_fill_index   <= '0;
        out_fill_iter    <= '0;
        out_fill_escaped <= 1'b0;
    end else begin
        if (out_fill_ready) begin
            out_fill_valid <= (tile_state == FILL) && !is_perimeter_pixel;
            
            out_fill_index   <= pixel_index[19:0];
            out_fill_iter    <= eval_latched_iter;
            out_fill_escaped <= eval_latched_escaped;
        end
    end
end


endmodule
