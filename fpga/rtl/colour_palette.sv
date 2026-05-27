`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 25.05.2026 22:20:46
// Design Name: 
// Module Name: colour_palette
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

module colour_palette #(
    parameter int W      = 26,
    parameter int ITER_W = 16,
    parameter int SEQ_W = 20,
    parameter int PALETTE_BITS = 10

)(
    input logic clk,
    input logic rst_n,

    // Input from reorder buffer
    input  logic                in_valid,
    output logic                palette_ready,

    input  logic [ITER_W-1:0]   in_iter_count,
    input  logic [SEQ_W-1:0]    in_seq_num,
    input  logic signed [W-1:0] in_z_r,
    input  logic signed [W-1:0] in_z_i,
    input  logic                in_escaped,
    input  logic                in_overflow,
    input logic                 in_sof,
    input logic                 in_eol,

    // Output to framebuffer / pixel writer
    output logic                out_valid,
    input  logic                out_ready,

    output logic [SEQ_W-1:0]    out_seq_num,
    output logic [7:0]          out_r,
    output logic [7:0]          out_g,
    output logic [7:0]          out_b,
    output logic                out_sof,
    output logic                out_eol
);

    localparam int PALETTE_SIZE = 1 << PALETTE_BITS;

    logic [PALETTE_BITS-1:0] palette_index;
    logic [23:0]             rgb_c;

    // escaped pixels use iteration count.
    // non-escaped pixels become black.
    assign palette_index = in_iter_count[PALETTE_BITS-1:0];

    assign palette_ready = !out_valid || out_ready;

    // Keep z_r/z_i deliberately available for future
    logic unused_z_inputs;
    assign unused_z_inputs = ^{in_z_r, in_z_i};

    // to replace with a real 1024-entry ROM/BRAM palette LUT or AXI-writable palette at some point

    function automatic logic [23:0] palette_lookup(
        input logic [PALETTE_BITS-1:0] idx
    );
        logic [7:0] t;
        logic [7:0] r;
        logic [7:0] g;
        logic [7:0] b;
        begin
            // Compress palette index down to 8 bits for RGB mixing.
            if (PALETTE_BITS >= 8) begin
                t = idx[PALETTE_BITS-1 -: 8];
            end
            else begin
                t = {idx, {(8-PALETTE_BITS){1'b0}}};
            end

            // Simple visually varied gradient.
            r = t;
            g = {t[4:0], t[7:5]};
            b = 8'hFF - t;

            palette_lookup = {r, g, b};
        end
    endfunction

    function automatic logic [23:0] colour_for_pixel(
        input logic [ITER_W-1:0]   iter_count,
        input logic                escaped,
        input logic                overflow
    );
        logic [PALETTE_BITS-1:0] idx;
        begin
            idx = iter_count[PALETTE_BITS-1:0];

            if (overflow) begin
                // Debug colour for arithmetic overflow.
                colour_for_pixel = 24'hFF_00_FF; // magenta
            end
            else if (!escaped) begin
                // inside set.
                colour_for_pixel = 24'h00_00_00; // black
            end
            else begin
                colour_for_pixel = palette_lookup(idx);
            end
        end
    endfunction

    always_comb begin
        rgb_c = colour_for_pixel(
            in_iter_count,
            in_escaped,
            in_overflow
        );
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_valid   <= 1'b0;
            out_seq_num <= '0;
            out_r       <= '0;
            out_g       <= '0;
            out_b       <= '0;
            out_sof     <= 1'b0;
            out_eol     <= 1'b0;
        end
        else if (palette_ready) begin
            out_valid <= in_valid;
    
            if (in_valid) begin
                out_seq_num <= in_seq_num;
                out_r       <= rgb_c[23:16];
                out_g       <= rgb_c[15:8];
                out_b       <= rgb_c[7:0];
    
                out_sof     <= in_sof;
                out_eol     <= in_eol;
            end
            else begin
                out_sof <= 1'b0;
                out_eol <= 1'b0;
            end
        end
    end

endmodule
