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
// Description: Banked BRAM-backed colour palette for converting iteration counts to RGB
//
// Notes:
//   - palette_scale maps iter_count across one 1024-entry palette bank.
//   - palette_select chooses one of 8 contiguous 1024-entry banks.
//   - Palette changes take effect immediately for subsequently accepted pixels.
//   - A scale value of zero falls back to direct-index behaviour.
//   - The scaling stage adds one extra cycle of latency, but valid/ready
//     preserves metadata alignment.
//////////////////////////////////////////////////////////////////////////////////

module colour_palette #(
    parameter int W                  = 26,
    parameter int ITER_W             = 16,
    parameter int SEQ_W              = 20,
    parameter int PALETTE_BITS       = 10,
    parameter int PALETTE_SEL_BITS   = 3,
    parameter int PALETTE_SCALE_W    = 32,
    parameter int PALETTE_SCALE_FRAC = 16
)(
    input logic clk,
    input logic rst_n,

    // Control
    input  logic [PALETTE_SCALE_W-1:0]  palette_scale,
    input  logic [PALETTE_SEL_BITS-1:0] palette_select,

    // Input from reorder buffer / iter stream
    input  logic                in_valid,
    output logic                palette_ready,

    input  logic [ITER_W-1:0]   in_iter_count,
    input  logic [SEQ_W-1:0]    in_seq_num,
    input  logic                in_escaped,
    input  logic                in_overflow,
    input  logic                in_sof,
    input  logic                in_eol,

    // Inputs from tile_scheduler
    input  logic                tile_fill_valid,
    output logic                tile_fill_ready,
    input  logic [SEQ_W-1:0]    tile_fill_seq_num,
    input  logic [ITER_W-1:0]   tile_fill_iter_count,
    input  logic                tile_fill_escaped,

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

    localparam int PALETTE_SIZE      = 1 << PALETTE_BITS;
    localparam int NUM_PALETTES      = 1 << PALETTE_SEL_BITS;
    localparam int PALETTE_MEM_SIZE  = PALETTE_SIZE * NUM_PALETTES;
    localparam int PALETTE_ADDR_BITS = PALETTE_BITS + PALETTE_SEL_BITS;
    localparam int SCALE_PRODUCT_W   = ITER_W + PALETTE_SCALE_W;

    localparam logic [PALETTE_BITS-1:0] PALETTE_MAX_IDX = {PALETTE_BITS{1'b1}};

    (* rom_style = "block", ram_style = "block" *)
    logic [23:0] palette_mem [0:PALETTE_MEM_SIZE-1];

    // Stage 0: scaled palette address.
    logic                            idx_valid;
    logic [SEQ_W-1:0]                idx_seq_num;
    logic                            idx_escaped;
    logic                            idx_overflow;
    logic                            idx_sof;
    logic                            idx_eol;
    logic [PALETTE_ADDR_BITS-1:0]    idx_palette_addr;

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

    // Mux internal registers allowing for Mariani-Silver/tile fill.
    logic                         mux_valid;
    logic [SEQ_W-1:0]             mux_seq_num;
    logic [ITER_W-1:0]            mux_iter_count;
    logic                         mux_escaped;
    logic                         mux_overflow;
    logic                         mux_sof;
    logic                         mux_eol;

    assign mux_valid        = tile_fill_valid | in_valid;
    assign tile_fill_ready  = idx_advance;

    assign mux_seq_num      = tile_fill_valid ? tile_fill_seq_num       : in_seq_num;
    assign mux_iter_count   = tile_fill_valid ? tile_fill_iter_count    : in_iter_count;
    assign mux_escaped      = tile_fill_valid ? tile_fill_escaped       : in_escaped;
    assign mux_overflow     = tile_fill_valid ? 1'b0                    : in_overflow;
    assign mux_sof          = tile_fill_valid ? 1'b0                    : in_sof;
    assign mux_eol          = tile_fill_valid ? 1'b0                    : in_eol;

    assign out_advance = !out_valid || out_ready;
    assign rd_advance  = !rd_valid  || out_advance;
    assign idx_advance = !idx_valid || rd_advance;

    assign palette_ready = idx_advance & ~tile_fill_valid;

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

    function automatic logic [PALETTE_ADDR_BITS-1:0] palette_bank_address(
        input logic [PALETTE_SEL_BITS-1:0] palette,
        input logic [PALETTE_BITS-1:0]     idx
    );
        begin
            palette_bank_address = {palette, idx};
        end
    endfunction

    // Fallback model used if the generated .mem file is absent during simulation.
    // The project should use palette_bank_8x1024.mem for the final implementation.
    function automatic logic [23:0] palette_lookup_model(
        input logic [PALETTE_SEL_BITS-1:0] palette,
        input logic [PALETTE_BITS-1:0]     idx
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

            unique case (palette)
                3'd0: begin
                    r = t;
                    g = {t[4:0], t[7:5]};
                    b = 8'hFF - t;
                end
                3'd1: begin
                    r = t;
                    g = (t < 8'd128) ? {1'b0, t[7:1]} : t;
                    b = (t < 8'd192) ? 8'h00 : {t[5:0], 2'b00};
                end
                3'd2: begin
                    r = (t < 8'd192) ? 8'h00 : {t[5:0], 2'b00};
                    g = t;
                    b = 8'hFF;
                end
                3'd3: begin
                    r = {t[6:0], 1'b0};
                    g = {t[3:0], t[7:4]};
                    b = 8'hFF;
                end
                3'd4: begin
                    r = {t[7:2], 2'b00};
                    g = t;
                    b = 8'h80 + {1'b0, t[7:1]};
                end
                3'd5: begin
                    r = t;
                    g = t;
                    b = t;
                end
                3'd6: begin
                    r = 8'h80 + {1'b0, t[7:1]};
                    g = {t[6:0], 1'b0};
                    b = 8'hFF - {1'b0, t[7:1]};
                end
                default: begin
                    r = 8'h00;
                    g = t;
                    b = 8'h80 + {1'b0, t[7:1]};
                end
            endcase

            palette_lookup_model = {r, g, b};
        end
    endfunction

    initial begin : init_palette
        integer i;
        integer palette;
        integer idx;

        for (palette = 0; palette < NUM_PALETTES; palette = palette + 1) begin
            for (idx = 0; idx < PALETTE_SIZE; idx = idx + 1) begin
                i = (palette * PALETTE_SIZE) + idx;
                palette_mem[i] = palette_lookup_model(
                    palette[PALETTE_SEL_BITS-1:0],
                    idx[PALETTE_BITS-1:0]
                );
            end
        end

        if ((PALETTE_BITS == 10) && (PALETTE_SEL_BITS == 3)) begin
            $readmemh("palette_bank_8x1024.mem", palette_mem);
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
            idx_valid        <= 1'b0;
            idx_seq_num      <= '0;
            idx_escaped      <= 1'b0;
            idx_overflow     <= 1'b0;
            idx_sof          <= 1'b0;
            idx_eol          <= 1'b0;
            idx_palette_addr <= '0;

            rd_valid         <= 1'b0;
            rd_seq_num       <= '0;
            rd_escaped       <= 1'b0;
            rd_overflow      <= 1'b0;
            rd_sof           <= 1'b0;
            rd_eol           <= 1'b0;
            rd_rgb           <= '0;

            out_valid        <= 1'b0;
            out_seq_num      <= '0;
            out_r            <= '0;
            out_g            <= '0;
            out_b            <= '0;
            out_sof          <= 1'b0;
            out_eol          <= 1'b0;
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
                    rd_rgb      <= palette_mem[idx_palette_addr];
                end
                else begin
                    rd_sof <= 1'b0;
                    rd_eol <= 1'b0;
                end
            end

            if (idx_advance) begin
                idx_valid <= mux_valid;

                if (mux_valid) begin
                    idx_seq_num      <= mux_seq_num;
                    idx_escaped      <= mux_escaped;
                    idx_overflow     <= mux_overflow;
                    idx_sof          <= mux_sof;
                    idx_eol          <= mux_eol;
                    idx_palette_addr <= palette_bank_address(
                        palette_select,
                        scaled_palette_index(mux_iter_count, palette_scale)
                    );
                end
                else begin
                    idx_sof <= 1'b0;
                    idx_eol <= 1'b0;
                end
            end
        end
    end

endmodule
