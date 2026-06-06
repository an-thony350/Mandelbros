`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
//
// Design Name: Pixel Write Engine
// Module Name: pixel_write_engine
// Project Name: FractalScope
// Target Devices: PYNQ-Z1
// Tool Versions: Vivado 2023.2
//
// Description:
//   v2.0 direct framebuffer writer. Accepts coloured pixels carrying an absolute
//   framebuffer pixel index and writes them to DDR through a simple AXI4 master.
//
// Notes:
//   - One outstanding single-beat AXI write at a time.
//   - 32-bit framebuffer word: {8'h00, R, B, G}.
//   - DATA_W is intentionally kept at 32 for this first debug-friendly version.
//////////////////////////////////////////////////////////////////////////////////

module pixel_write_engine #(
    parameter int ADDR_W       = 32,
    parameter int DATA_W       = 32,
    parameter int SEQ_W        = 20,
    parameter int X_RES        = 1280,
    parameter int Y_RES        = 720,
    parameter int FRAME_PIXELS = X_RES * Y_RES
)(
    input  logic clk,
    input  logic rst_n,

    input  logic              start,
    input  logic              enable,
    input  logic              soft_reset,
    input  logic [ADDR_W-1:0] framebuffer_base,

    input  logic             in_valid,
    output logic             in_ready,
    input  logic [SEQ_W-1:0] in_pixel_index,
    input  logic [7:0]       in_r,
    input  logic [7:0]       in_g,
    input  logic [7:0]       in_b,

    output logic        busy,
    output logic        done,
    output logic        idle,
    output logic        error,
    output logic [31:0] pixels_accepted,
    output logic [31:0] pixels_written,
    output logic [31:0] write_errors,

    output logic [ADDR_W-1:0]     m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,

    output logic [DATA_W-1:0]     m_axi_wdata,
    output logic [(DATA_W/8)-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,

    input  logic [1:0]            m_axi_bresp,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    input  logic [3:0]            in_scale
);

    localparam logic [1:0] AXI_BURST_INCR = 2'b01;
    localparam logic [2:0] AXI_SIZE_4B    = 3'b010;
    localparam logic [1:0] AXI_RESP_OKAY  = 2'b00;
    localparam logic [31:0] FRAME_PIXELS_32 = FRAME_PIXELS;
    localparam logic [31:0] SKIPPED_PIXELS = 2 * (352 * 160); // UI blocks
    localparam logic [31:0] ACTIVE_PIXELS = FRAME_PIXELS_32 - SKIPPED_PIXELS;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_AW,
        ST_W,
        ST_B
    } state_t;

    state_t state_q;
    logic frame_active_q;
    logic reset_pending_q;

    // Block drawing registers
    logic [SEQ_W-1:0] latched_pixel_index;
    logic [3:0] dx; 
    logic [3:0] dy; 
    logic [DATA_W-1:0] pixel_word_q;
    logic [31:0]    target_pixels;
    always_comb begin
        case(in_scale)
            4'd8:   target_pixels = ACTIVE_PIXELS >> 6;
            4'd4:   target_pixels = ACTIVE_PIXELS >> 4;
            4'd2:   target_pixels = ACTIVE_PIXELS >> 2;
            default: target_pixels = ACTIVE_PIXELS;
            endcase
        end

    assign busy = frame_active_q || (state_q != ST_IDLE);
    assign idle = !frame_active_q && (state_q == ST_IDLE) && !reset_pending_q;
    
    assign in_ready = frame_active_q && enable && !reset_pending_q && (state_q == ST_IDLE) && (pixels_accepted < target_pixels);

    assign m_axi_awaddr  = framebuffer_base + ((latched_pixel_index + (dy * X_RES)) << 2);
    assign m_axi_awlen   = in_scale - 8'd1;
    assign m_axi_awsize  = AXI_SIZE_4B;
    assign m_axi_awburst = AXI_BURST_INCR;
    assign m_axi_awvalid = (state_q == ST_AW);

    assign m_axi_wdata  = pixel_word_q;
    assign m_axi_wstrb  = {(DATA_W/8){1'b1}};
    assign m_axi_wlast  = (dx == in_scale - 8'd1);
    assign m_axi_wvalid = (state_q == ST_W);

    assign m_axi_bready = (state_q == ST_B);

    always_ff @(posedge clk) begin
        if (!rst_n || ((soft_reset || reset_pending_q) && state_q == ST_IDLE)) begin
            state_q         <= ST_IDLE;
            frame_active_q  <= 1'b0;
            reset_pending_q <= soft_reset;
            latched_pixel_index <= '0;
            pixel_word_q    <= '0;
            done            <= 1'b0;
            error           <= 1'b0;
            pixels_accepted <= 32'd0;
            pixels_written  <= 32'd0;
            write_errors    <= 32'd0;
            dx <= '0;
            dy <= '0;
        end
        else if (start && idle) begin
            state_q         <= ST_IDLE;
            frame_active_q  <= 1'b1;
            reset_pending_q <= 1'b0;
            latched_pixel_index <= '0;
            pixel_word_q    <= '0;
            done            <= 1'b0;
            error           <= 1'b0;
            pixels_accepted <= 32'd0;
            pixels_written  <= 32'd0;
            write_errors    <= 32'd0;
            dx <= '0;
            dy <= '0;
        end
        else begin
            if (soft_reset) reset_pending_q <= 1'b1;

            case (state_q)
                ST_IDLE: begin
                    if (in_valid && in_ready) begin
                        latched_pixel_index <= in_pixel_index;
                        pixel_word_q <= {8'h00, in_r, in_g, in_b};
                        pixels_accepted <= pixels_accepted + 32'd1;
                        dx <= '0;
                        dy <= '0;
                        state_q <= ST_AW; // Fire Address Write
                    end
                end

                ST_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        state_q <= ST_W; // Fire Data Burst
                    end
                end

                ST_W: begin
                    if (m_axi_wvalid && m_axi_wready) begin
                        pixels_written <= pixels_written + 32'd1;
                        if (m_axi_wlast) begin
                            state_q <= ST_B; // End of row burst, wait for response
                        end else begin
                            dx <= dx + 1'b1;
                        end
                    end
                end

                ST_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        if (m_axi_bresp != AXI_RESP_OKAY) begin
                            error        <= 1'b1;
                            write_errors <= write_errors + 32'd1;
                        end

                        if (dy == in_scale - 8'd1) begin
                            if ((pixels_written) >= FRAME_PIXELS_32) begin
                                done           <= 1'b1;
                                frame_active_q <= 1'b0;
                            end
                            state_q <= ST_IDLE; // Accept next core pixel
                        end else begin
                            dy <= dy + 1'b1;
                            dx <= '0;
                            state_q <= ST_AW;
                        end
                    end
                end
            endcase
        end
    end
endmodule