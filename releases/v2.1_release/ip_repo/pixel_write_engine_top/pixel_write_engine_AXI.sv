`timescale 1 ns / 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
//
// Design Name: Pixel Write Engine with AXI-Lite Interface
// Module Name: pixel_write_engine_AXI
// Project Name: FractalScope
// Target Devices: PYNQ-Z1
// Tool Versions: Vivado 2023.2
//
// Description:
//   AXI-Lite control/status wrapper for the v2.0 pixel_write_engine.
//   This follows the same broad style as pixel_scheduler_AXI: an AXI-Lite
//   register bank feeds the core module instantiated in the user-logic section.
//
// Register map, 32-bit words:
//   0x00 CONTROL
//        bit 0: start      write-one pulse, reads as 0
//        bit 1: enable     sticky register
//        bit 2: soft_reset write-one pulse, reads as 0
//
//   0x04 STATUS
//        bit 0: busy
//        bit 1: done
//        bit 2: error
//        bit 3: idle
//
//   0x08 FRAMEBUFFER_BASE
//   0x0C PIXELS_ACCEPTED
//   0x10 PIXELS_WRITTEN
//   0x14 WRITE_ERRORS
//   0x18 FRAME_PIXELS
//   0x1C GEOMETRY {Y_RES[15:0], X_RES[15:0]}
//
// Dependencies:
//   pixel_write_engine.sv
//////////////////////////////////////////////////////////////////////////////////

module pixel_write_engine_AXI #(
    parameter integer ADDR_W       = 32,
    parameter integer DATA_W       = 32,
    parameter integer SEQ_W        = 20,
    parameter integer X_RES        = 1280,
    parameter integer Y_RES        = 720,
    parameter integer FRAME_PIXELS = X_RES * Y_RES,

    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5,
    parameter integer C_M_AXI_ADDR_WIDTH = 32,
    parameter integer C_M_AXI_DATA_WIDTH = 32
)(
    // Pixel stream from colour_palette
    input  wire                     in_valid,
    output wire                     in_ready,
    input  wire [SEQ_W-1:0]         in_pixel_index,
    input  wire [7:0]               in_r,
    input  wire [7:0]               in_g,
    input  wire [7:0]               in_b,

    // AXI4 master write interface to DDR/SmartConnect/HP port
    output wire [C_M_AXI_ADDR_WIDTH-1:0]       M_AXI_AWADDR,
    output wire [7:0]                          M_AXI_AWLEN,
    output wire [2:0]                          M_AXI_AWSIZE,
    output wire [1:0]                          M_AXI_AWBURST,
    output wire                                M_AXI_AWVALID,
    input  wire                                M_AXI_AWREADY,

    output wire [C_M_AXI_DATA_WIDTH-1:0]       M_AXI_WDATA,
    output wire [(C_M_AXI_DATA_WIDTH/8)-1:0]   M_AXI_WSTRB,
    output wire                                M_AXI_WLAST,
    output wire                                M_AXI_WVALID,
    input  wire                                M_AXI_WREADY,

    input  wire [1:0]                          M_AXI_BRESP,
    input  wire                                M_AXI_BVALID,
    output wire                                M_AXI_BREADY,

    // AXI-Lite slave interface from PS
    input  wire                                S_AXI_ACLK,
    input  wire                                S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_AWADDR,
    input  wire [2:0]                          S_AXI_AWPROT,
    input  wire                                S_AXI_AWVALID,
    output wire                                S_AXI_AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   S_AXI_WSTRB,
    input  wire                                S_AXI_WVALID,
    output wire                                S_AXI_WREADY,
    output wire [1:0]                          S_AXI_BRESP,
    output wire                                S_AXI_BVALID,
    input  wire                                S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_ARADDR,
    input  wire [2:0]                          S_AXI_ARPROT,
    input  wire                                S_AXI_ARVALID,
    output wire                                S_AXI_ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_RDATA,
    output wire [1:0]                          S_AXI_RRESP,
    output wire                                S_AXI_RVALID,
    input  wire                                S_AXI_RREADY
);

    // AXI-Lite slave signals
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg                          axi_awready;
    reg                          axi_wready;
    reg [1:0]                    axi_bresp;
    reg                          axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
    reg                          axi_arready;
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg [1:0]                    axi_rresp;
    reg                          axi_rvalid;

    localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
    localparam integer OPT_MEM_ADDR_BITS = 2;

    localparam [2:0] REG_CONTROL          = 3'h0;
    localparam [2:0] REG_STATUS           = 3'h1;
    localparam [2:0] REG_FRAMEBUFFER_BASE = 3'h2;
    localparam [2:0] REG_PIXELS_ACCEPTED  = 3'h3;
    localparam [2:0] REG_PIXELS_WRITTEN   = 3'h4;
    localparam [2:0] REG_WRITE_ERRORS     = 3'h5;
    localparam [2:0] REG_FRAME_PIXELS     = 3'h6;
    localparam [2:0] REG_GEOMETRY         = 3'h7;

    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg0_control;
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg2_framebuffer_base;

    wire slv_reg_rden;
    wire slv_reg_wren;
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_data_out;
    integer byte_index;
    reg aw_en;

    wire [2:0] write_reg_sel;
    wire [2:0] read_reg_sel;

    reg writer_start_pulse;
    reg writer_soft_reset_pulse;

    localparam [C_S_AXI_DATA_WIDTH-1:0] FRAME_PIXELS_VALUE = FRAME_PIXELS;
    localparam [15:0] X_RES_VALUE = X_RES;
    localparam [15:0] Y_RES_VALUE = Y_RES;

    wire writer_enable;
    wire writer_busy;
    wire writer_done;
    wire writer_idle;
    wire writer_error;
    wire [31:0] writer_pixels_accepted;
    wire [31:0] writer_pixels_written;
    wire [31:0] writer_write_errors;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    assign write_reg_sel = axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB];
    assign read_reg_sel  = axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB];

    assign writer_enable = slv_reg0_control[1];

    // AXI-Lite write address ready
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_awready <= 1'b0;
            aw_en       <= 1'b1;
        end
        else begin
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
                axi_awready <= 1'b1;
                aw_en       <= 1'b0;
            end
            else if (S_AXI_BREADY && axi_bvalid) begin
                aw_en       <= 1'b1;
                axi_awready <= 1'b0;
            end
            else begin
                axi_awready <= 1'b0;
            end
        end
    end

    // AXI-Lite write address latch
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_awaddr <= '0;
        end
        else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
            axi_awaddr <= S_AXI_AWADDR;
        end
    end

    // AXI-Lite write data ready
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_wready <= 1'b0;
        end
        else begin
            if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en) begin
                axi_wready <= 1'b1;
            end
            else begin
                axi_wready <= 1'b0;
            end
        end
    end

    assign slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    // Writable registers and command pulse generation
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            slv_reg0_control          <= '0;
            slv_reg2_framebuffer_base <= '0;
            writer_start_pulse        <= 1'b0;
            writer_soft_reset_pulse   <= 1'b0;
        end
        else begin
            writer_start_pulse      <= 1'b0;
            writer_soft_reset_pulse <= 1'b0;

            if (slv_reg_wren) begin
                case (write_reg_sel)
                    REG_CONTROL: begin
                        if (S_AXI_WSTRB[0]) begin
                            writer_start_pulse      <= S_AXI_WDATA[0];
                            slv_reg0_control[1]     <= S_AXI_WDATA[1];
                            writer_soft_reset_pulse <= S_AXI_WDATA[2];
                            slv_reg0_control[7:4]   <= S_AXI_WDATA[7:4];
                        end
                    end

                    REG_FRAMEBUFFER_BASE: begin
                        for (byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index + 1) begin
                            if (S_AXI_WSTRB[byte_index]) begin
                                slv_reg2_framebuffer_base[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];
                            end
                        end
                    end

                    default: begin
                        slv_reg0_control          <= slv_reg0_control;
                        slv_reg2_framebuffer_base <= slv_reg2_framebuffer_base;
                    end
                endcase
            end
        end
    end

    // AXI-Lite write response
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b00;
        end
        else begin
            if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00;
            end
            else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // AXI-Lite read address ready
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_arready <= 1'b0;
            axi_araddr  <= '0;
        end
        else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                axi_araddr  <= S_AXI_ARADDR;
            end
            else begin
                axi_arready <= 1'b0;
            end
        end
    end

    // AXI-Lite read data valid
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b00;
        end
        else begin
            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00;
            end
            else if (axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    assign slv_reg_rden = axi_arready & S_AXI_ARVALID & ~axi_rvalid;

    // Readback mux
    always @(*) begin
        case (read_reg_sel)
            REG_CONTROL: begin
                reg_data_out = {{(C_S_AXI_DATA_WIDTH-2){1'b0}}, slv_reg0_control[1], 1'b0};
            end

            REG_STATUS: begin
                reg_data_out = {{(C_S_AXI_DATA_WIDTH-4){1'b0}}, writer_idle, writer_error, writer_done, writer_busy};
            end

            REG_FRAMEBUFFER_BASE: begin
                reg_data_out = slv_reg2_framebuffer_base;
            end

            REG_PIXELS_ACCEPTED: begin
                reg_data_out = writer_pixels_accepted;
            end

            REG_PIXELS_WRITTEN: begin
                reg_data_out = writer_pixels_written;
            end

            REG_WRITE_ERRORS: begin
                reg_data_out = writer_write_errors;
            end

            REG_FRAME_PIXELS: begin
                reg_data_out = FRAME_PIXELS_VALUE;
            end

            REG_GEOMETRY: begin
                reg_data_out = {Y_RES_VALUE, X_RES_VALUE};
            end

            default: begin
                reg_data_out = '0;
            end
        endcase
    end

    // AXI-Lite read data register
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_rdata <= '0;
        end
        else if (slv_reg_rden) begin
            axi_rdata <= reg_data_out;
        end
    end

    // User logic: direct framebuffer write engine
    pixel_write_engine #(
        .ADDR_W(C_M_AXI_ADDR_WIDTH),
        .DATA_W(C_M_AXI_DATA_WIDTH),
        .SEQ_W(SEQ_W),
        .X_RES(X_RES),
        .Y_RES(Y_RES),
        .FRAME_PIXELS(FRAME_PIXELS)
    ) pixel_write_engine_inst (
        .clk(S_AXI_ACLK),
        .rst_n(S_AXI_ARESETN),

        .start(writer_start_pulse),
        .enable(writer_enable),
        .soft_reset(writer_soft_reset_pulse),
        .framebuffer_base(slv_reg2_framebuffer_base[C_M_AXI_ADDR_WIDTH-1:0]),

        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_pixel_index(in_pixel_index),
        .in_r(in_r),
        .in_g(in_g),
        .in_b(in_b),

        .busy(writer_busy),
        .done(writer_done),
        .idle(writer_idle),
        .error(writer_error),
        .pixels_accepted(writer_pixels_accepted),
        .pixels_written(writer_pixels_written),
        .write_errors(writer_write_errors),
        .in_scale(slv_reg0_control[7:4]),

        .m_axi_awaddr(M_AXI_AWADDR),
        .m_axi_awlen(M_AXI_AWLEN),
        .m_axi_awsize(M_AXI_AWSIZE),
        .m_axi_awburst(M_AXI_AWBURST),
        .m_axi_awvalid(M_AXI_AWVALID),
        .m_axi_awready(M_AXI_AWREADY),

        .m_axi_wdata(M_AXI_WDATA),
        .m_axi_wstrb(M_AXI_WSTRB),
        .m_axi_wlast(M_AXI_WLAST),
        .m_axi_wvalid(M_AXI_WVALID),
        .m_axi_wready(M_AXI_WREADY),

        .m_axi_bresp(M_AXI_BRESP),
        .m_axi_bvalid(M_AXI_BVALID),
        .m_axi_bready(M_AXI_BREADY)
    );

endmodule
