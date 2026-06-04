`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
// 
// Create Date: 28.05.2026
// Design Name: Colour Palette
// Module Name: colour_palette
// Project Name: FractalScope
// Target Devices: PYNQ-Z1
// Tool Versions: Vivado 2023.2
// Description: BRAM-backed colour palette for converting iteration counts to RGB
//
// Notes:
//   - The internal ROM/BRAM lookup adds one cycle of latency, but the valid/ready
//     pipeline preserves metadata alignment.
//////////////////////////////////////////////////////////////////////////////////

module colour_palette #(
    parameter int W      = 26,
    parameter int ITER_W = 16,
    parameter int SEQ_W  = 20,
    parameter int PALETTE_BITS = 10
)(
    input logic clk,
    input logic rst_n,

    // Input from reorder buffer / iter stream
    input  logic                in_valid,
    output logic                palette_ready,

    input  logic [ITER_W-1:0]   in_iter_count,
    input  logic [SEQ_W-1:0]    in_seq_num,
    input  logic                in_escaped,
    input  logic                in_overflow,
    input  logic                in_sof,
    input  logic                in_eol,

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

    // combinational palette_lookup() function.
    (* rom_style = "block", ram_style = "block" *)
    logic [23:0] palette_mem [0:PALETTE_SIZE-1];

    // Stage between BRAM lookup and output register.
    logic                rd_valid;
    logic [SEQ_W-1:0]    rd_seq_num;
    logic                rd_escaped;
    logic                rd_overflow;
    logic                rd_sof;
    logic                rd_eol;
    logic [23:0]         rd_rgb;

    logic                out_advance;
    logic [23:0]         selected_rgb;

    assign out_advance = !out_valid || out_ready;

    // The pipeline has two internal slots: rd_* and out_*.
    // We can accept a new input if the rd stage is empty, or if the rd stage
    // will move forward into the output stage on this cycle.
    assign palette_ready = !rd_valid || out_advance;

    // Kept here as documentation of the exact intended palette mapping.
    // The .mem file generated for PALETTE_BITS=10 matches this function.
    function automatic logic [23:0] palette_lookup_model(
        input logic [PALETTE_BITS-1:0] idx
    );
        logic [7:0] t;
        logic [7:0] r;
        logic [7:0] g;
        logic [7:0] b;
        begin
            if (PALETTE_BITS >= 8) begin
                t = idx[PALETTE_BITS-1 -: 8];
            end
            else begin
                t = {idx, {(8-PALETTE_BITS){1'b0}}};
            end

            r = t;
            g = {t[4:0], t[7:5]};
            b = 8'hFF - t;

            palette_lookup_model = {r, g, b};
        end
    endfunction

    initial begin : init_palette
        integer i;

        // Safe fallback for simulation/synthesis if the memory file is not found
        // or if this module is used with a different PALETTE_BITS value.
        for (i = 0; i < PALETTE_SIZE; i = i + 1) begin
            palette_mem[i] = palette_lookup_model(i[PALETTE_BITS-1:0]);
        end

        // For the current FractalScope build this file should be added to the
        // Vivado project alongside this source file.
        if (PALETTE_BITS == 10) begin
            $readmemh("palette_rainbow_full_1024.mem", palette_mem);
        end
    end

    // Equivalent to the known-working combinational version:
    //   if (overflow || escaped) colour = palette(index)
    //   else colour = black
    always_comb begin
        if (rd_overflow || rd_escaped) begin
            selected_rgb = rd_rgb;
        end
        else begin
            selected_rgb = 24'h00_00_00;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_valid    <= 1'b0;
            rd_seq_num  <= '0;
            rd_escaped  <= 1'b0;
            rd_overflow <= 1'b0;
            rd_sof      <= 1'b0;
            rd_eol      <= 1'b0;
            rd_rgb      <= '0;

            out_valid   <= 1'b0;
            out_seq_num <= '0;
            out_r       <= '0;
            out_g       <= '0;
            out_b       <= '0;
            out_sof     <= 1'b0;
            out_eol     <= 1'b0;
        end
        else begin
            if (out_advance) begin
                out_valid <= rd_valid;

                if (rd_valid) begin
                    out_seq_num <= rd_seq_num;
                    out_r       <= selected_rgb[23:16];
                    out_g       <= selected_rgb[15:8];
                    out_b       <= selected_rgb[7:0];
                    out_sof     <= rd_sof;
                    out_eol     <= rd_eol;
                end
                else begin
                    out_sof <= 1'b0;
                    out_eol <= 1'b0;
                end
            end

            if (palette_ready) begin
                rd_valid <= in_valid;

                if (in_valid) begin
                    rd_seq_num  <= in_seq_num;
                    rd_escaped  <= in_escaped;
                    rd_overflow <= in_overflow;
                    rd_sof      <= in_sof;
                    rd_eol      <= in_eol;
                    rd_rgb      <= palette_mem[in_iter_count[PALETTE_BITS-1:0]];
                end
                else begin
                    rd_sof <= 1'b0;
                    rd_eol <= 1'b0;
                end
            end
        end
    end

endmodule
