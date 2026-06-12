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
    output logic                  m_axi_bready
);

    localparam logic [1:0] AXI_BURST_INCR = 2'b01;
    localparam logic [2:0] AXI_SIZE_4B    = 3'b010;
    localparam logic [1:0] AXI_RESP_OKAY  = 2'b00;
    localparam logic [31:0] FRAME_PIXELS_32 = FRAME_PIXELS;

`ifndef SYNTHESIS
    initial begin
        if (DATA_W != 32) begin
            $error("pixel_write_engine v2.0 currently requires DATA_W == 32");
        end
        if (ADDR_W < (SEQ_W + 2)) begin
            $error("ADDR_W must be at least SEQ_W + 2 for pixel_index byte addressing");
        end
        if (FRAME_PIXELS <= 0) begin
            $error("FRAME_PIXELS must be positive");
        end
    end
`endif

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_SEND_AW_W,
        ST_WAIT_B
    } state_t;

    state_t state_q;

    logic frame_active_q;
    logic reset_pending_q;
    logic aw_done_q;
    logic w_done_q;

    logic [ADDR_W-1:0] write_addr_q;
    logic [DATA_W-1:0] pixel_word_q;

    logic aw_fire;
    logic w_fire;
    logic b_fire;

    logic [ADDR_W-1:0] pixel_index_ext;
    logic [ADDR_W-1:0] pixel_byte_offset;

    assign aw_fire = m_axi_awvalid && m_axi_awready;
    assign w_fire  = m_axi_wvalid  && m_axi_wready;
    assign b_fire  = m_axi_bvalid  && m_axi_bready;

    assign pixel_index_ext   = {{(ADDR_W-SEQ_W){1'b0}}, in_pixel_index};
    assign pixel_byte_offset = pixel_index_ext << 2;

    assign busy = frame_active_q || (state_q != ST_IDLE);
    assign idle = !frame_active_q && (state_q == ST_IDLE) && !reset_pending_q;

    assign in_ready = frame_active_q &&
                      enable &&
                      !reset_pending_q &&
                      (state_q == ST_IDLE) &&
                      (pixels_accepted < FRAME_PIXELS_32);

    assign m_axi_awaddr  = write_addr_q;
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = AXI_SIZE_4B;
    assign m_axi_awburst = AXI_BURST_INCR;
    assign m_axi_awvalid = (state_q == ST_SEND_AW_W) && !aw_done_q;

    assign m_axi_wdata  = pixel_word_q;
    assign m_axi_wstrb  = {(DATA_W/8){1'b1}};
    assign m_axi_wlast  = 1'b1;
    assign m_axi_wvalid = (state_q == ST_SEND_AW_W) && !w_done_q;

    assign m_axi_bready = (state_q == ST_WAIT_B);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q         <= ST_IDLE;
            frame_active_q  <= 1'b0;
            reset_pending_q <= 1'b0;
            aw_done_q       <= 1'b0;
            w_done_q        <= 1'b0;
            write_addr_q    <= '0;
            pixel_word_q    <= '0;
            done            <= 1'b0;
            error           <= 1'b0;
            pixels_accepted <= 32'd0;
            pixels_written  <= 32'd0;
            write_errors    <= 32'd0;
        end
        else if ((soft_reset || reset_pending_q) && (state_q == ST_IDLE)) begin
            state_q         <= ST_IDLE;
            frame_active_q  <= 1'b0;
            reset_pending_q <= 1'b0;
            aw_done_q       <= 1'b0;
            w_done_q        <= 1'b0;
            write_addr_q    <= '0;
            pixel_word_q    <= '0;
            done            <= 1'b0;
            error           <= 1'b0;
            pixels_accepted <= 32'd0;
            pixels_written  <= 32'd0;
            write_errors    <= 32'd0;
        end
        else if (start && idle) begin
            state_q         <= ST_IDLE;
            frame_active_q  <= 1'b1;
            reset_pending_q <= 1'b0;
            aw_done_q       <= 1'b0;
            w_done_q        <= 1'b0;
            write_addr_q    <= '0;
            pixel_word_q    <= '0;
            done            <= 1'b0;
            error           <= 1'b0;
            pixels_accepted <= 32'd0;
            pixels_written  <= 32'd0;
            write_errors    <= 32'd0;
        end
        else begin
            if (soft_reset) begin
                reset_pending_q <= 1'b1;
            end

            case (state_q)
                ST_IDLE: begin
                    aw_done_q <= 1'b0;
                    w_done_q  <= 1'b0;

                    if (in_valid && in_ready) begin
                        write_addr_q <= framebuffer_base + pixel_byte_offset;
                        pixel_word_q <= {8'h00, in_r, in_b, in_g};
                        pixels_accepted <= pixels_accepted + 32'd1;
                        state_q <= ST_SEND_AW_W;
                    end
                end

                ST_SEND_AW_W: begin
                    if (aw_fire) begin
                        aw_done_q <= 1'b1;
                    end

                    if (w_fire) begin
                        w_done_q <= 1'b1;
                    end

                    if ((aw_done_q || aw_fire) && (w_done_q || w_fire)) begin
                        state_q <= ST_WAIT_B;
                    end
                end

                ST_WAIT_B: begin
                    if (b_fire) begin
                        pixels_written <= pixels_written + 32'd1;

                        if (m_axi_bresp != AXI_RESP_OKAY) begin
                            error        <= 1'b1;
                            write_errors <= write_errors + 32'd1;
                        end

                        if ((pixels_written + 32'd1) >= FRAME_PIXELS_32) begin
                            done           <= 1'b1;
                            frame_active_q <= 1'b0;
                        end

                        state_q <= ST_IDLE;
                    end
                end

                default: begin
                    state_q <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
