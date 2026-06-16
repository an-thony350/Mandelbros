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
//   - palette_scale maps iter_count across the full palette range.
//   - A scale value of zero falls back to the old direct-index behaviour.
//   - The scaling stage adds one extra cycle of latency, but valid/ready
//     preserves metadata alignment.
//////////////////////////////////////////////////////////////////////////////////

module colour_palette #(
    parameter int W                  = 26,
    parameter int ITER_W             = 16,
    parameter int SEQ_W              = 20,
    parameter int PALETTE_BITS       = 10,
    parameter int PALETTE_SCALE_W    = 32,
    parameter int PALETTE_SCALE_FRAC = 16
)(
    input logic clk,
    input logic rst_n,

    // Control
    input  logic [PALETTE_SCALE_W-1:0] palette_scale,

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

    localparam int PALETTE_SIZE    = 1 << PALETTE_BITS;
    localparam int SCALE_PRODUCT_W = ITER_W + PALETTE_SCALE_W;

    localparam logic [PALETTE_BITS-1:0] PALETTE_MAX_IDX = {PALETTE_BITS{1'b1}};

    (* rom_style = "block", ram_style = "block" *)
    logic [23:0] palette_mem [0:PALETTE_SIZE-1];

    // Stage 0: scaled palette index.
    logic                         idx_valid;
    logic [SEQ_W-1:0]             idx_seq_num;
    logic                         idx_escaped;
    logic                         idx_overflow;
    logic                         idx_sof;
    logic                         idx_eol;
    logic [PALETTE_BITS-1:0]      idx_palette_idx;

    // Stage 1: BRAM lookup result.
    logic                         rd_valid;
    logic [SEQ_W-1:0]             rd_seq_num;
    logic                         rd_escaped;
    logic                         rd_overflow;
    logic                         rd_sof;
    logic                         rd_eol;
    logic [23:0]                  rd_rgb;

    logic                         idx_advance;
    logic                         rd_advance;
    logic                         out_advance;
    logic [23:0]                  selected_rgb;

    assign out_advance = !out_valid || out_ready;
    assign rd_advance  = !rd_valid  || out_advance;
    assign idx_advance = !idx_valid || rd_advance;

    assign palette_ready = idx_advance;

    function automatic logic [PALETTE_BITS-1:0] scaled_palette_index(
        input logic [ITER_W-1:0]          iter_count,
        input logic [PALETTE_SCALE_W-1:0] scale
    );
        logic [SCALE_PRODUCT_W-1:0] product;
        logic [SCALE_PRODUCT_W-1:0] scaled;
        begin
            if (scale == '0) begin
                scaled_palette_index = iter_count[PALETTE_BITS-1:0];
            end
            else begin
                product = iter_count * scale;
                scaled  = product >> PALETTE_SCALE_FRAC;

                if (|scaled[SCALE_PRODUCT_W-1:PALETTE_BITS]) begin
                    scaled_palette_index = PALETTE_MAX_IDX;
                end
                else begin
                    scaled_palette_index = scaled[PALETTE_BITS-1:0];
                end
            end
        end
    endfunction

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

        for (i = 0; i < PALETTE_SIZE; i = i + 1) begin
            palette_mem[i] = palette_lookup_model(i[PALETTE_BITS-1:0]);
        end

        if (PALETTE_BITS == 10) begin
            $readmemh("palette_rainbow_full_1024.mem", palette_mem);
        end
    end

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
            idx_valid       <= 1'b0;
            idx_seq_num     <= '0;
            idx_escaped     <= 1'b0;
            idx_overflow    <= 1'b0;
            idx_sof         <= 1'b0;
            idx_eol         <= 1'b0;
            idx_palette_idx <= '0;

            rd_valid        <= 1'b0;
            rd_seq_num      <= '0;
            rd_escaped      <= 1'b0;
            rd_overflow     <= 1'b0;
            rd_sof          <= 1'b0;
            rd_eol          <= 1'b0;
            rd_rgb          <= '0;

            out_valid       <= 1'b0;
            out_seq_num     <= '0;
            out_r           <= '0;
            out_g           <= '0;
            out_b           <= '0;
            out_sof         <= 1'b0;
            out_eol         <= 1'b0;
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

            if (rd_advance) begin
                rd_valid <= idx_valid;

                if (idx_valid) begin
                    rd_seq_num  <= idx_seq_num;
                    rd_escaped  <= idx_escaped;
                    rd_overflow <= idx_overflow;
                    rd_sof      <= idx_sof;
                    rd_eol      <= idx_eol;
                    rd_rgb      <= palette_mem[idx_palette_idx];
                end
                else begin
                    rd_sof <= 1'b0;
                    rd_eol <= 1'b0;
                end
            end

            if (idx_advance) begin
                idx_valid <= in_valid;

                if (in_valid) begin
                    idx_seq_num     <= in_seq_num;
                    idx_escaped     <= in_escaped;
                    idx_overflow    <= in_overflow;
                    idx_sof         <= in_sof;
                    idx_eol         <= in_eol;
                    idx_palette_idx <= scaled_palette_index(in_iter_count, palette_scale);
                end
                else begin
                    idx_sof <= 1'b0;
                    idx_eol <= 1'b0;
                end
            end
        end
    end

endmodule