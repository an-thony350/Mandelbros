`timescale 1 ns / 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
//
// Design Name: Pixel Write Engine Top
// Module Name: pixel_write_engine_top
// Project Name: FractalScope
// Target Devices: PYNQ-Z1
// Tool Versions: Vivado 2023.2
//
// Description:
//   Thin Vivado-facing wrapper for the v3.0 direct framebuffer writer.
//   This mirrors the existing pixel_scheduler_top style: the top-level module
//   exposes block-design friendly S00_AXI and M00_AXI ports, then instantiates
//   the AXI-Lite/register wrapper.
//
// Dependencies:
//   pixel_write_engine_AXI.sv
//   pixel_write_engine.sv
//////////////////////////////////////////////////////////////////////////////////

module pixel_write_engine_top #(
    parameter integer ADDR_W       = 32,
    parameter integer DATA_W       = 32,
    parameter integer SEQ_W        = 20,
    parameter integer X_RES        = 1280,
    parameter integer Y_RES        = 720,

    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 5,
    parameter integer C_M00_AXI_ADDR_WIDTH = 32,
    parameter integer C_M00_AXI_DATA_WIDTH = 32
)(
    // Pixel stream from colour_palette
    input  wire                                   in_valid,
    output wire                                   in_ready,
    input  wire [SEQ_W-1:0]                       in_pixel_index,
    input  wire [7:0]                             in_r,
    input  wire [7:0]                             in_g,
    input  wire [7:0]                             in_b,

    // AXI-Lite slave interface from PS
    input  wire                                   s00_axi_aclk,
    input  wire                                   s00_axi_aresetn,
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0]        s00_axi_awaddr,
    input  wire [2:0]                             s00_axi_awprot,
    input  wire                                   s00_axi_awvalid,
    output wire                                   s00_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1:0]        s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1:0]    s00_axi_wstrb,
    input  wire                                   s00_axi_wvalid,
    output wire                                   s00_axi_wready,
    output wire [1:0]                             s00_axi_bresp,
    output wire                                   s00_axi_bvalid,
    input  wire                                   s00_axi_bready,
    input  wire [C_S00_AXI_ADDR_WIDTH-1:0]        s00_axi_araddr,
    input  wire [2:0]                             s00_axi_arprot,
    input  wire                                   s00_axi_arvalid,
    output wire                                   s00_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1:0]        s00_axi_rdata,
    output wire [1:0]                             s00_axi_rresp,
    output wire                                   s00_axi_rvalid,
    input  wire                                   s00_axi_rready,

    // AXI4 master write interface to DDR/SmartConnect/HP port
    output wire [C_M00_AXI_ADDR_WIDTH-1:0]        m00_axi_awaddr,
    output wire [7:0]                             m00_axi_awlen,
    output wire [2:0]                             m00_axi_awsize,
    output wire [1:0]                             m00_axi_awburst,
    output wire [2:0]                             m00_axi_awprot,
    output wire [3:0]                             m00_axi_awcache,
    output wire                                   m00_axi_awlock,
    output wire [3:0]                             m00_axi_awqos,
    output wire                                   m00_axi_awvalid,
    input  wire                                   m00_axi_awready,

    output wire [C_M00_AXI_DATA_WIDTH-1:0]        m00_axi_wdata,
    output wire [(C_M00_AXI_DATA_WIDTH/8)-1:0]    m00_axi_wstrb,
    output wire                                   m00_axi_wlast,
    output wire                                   m00_axi_wvalid,
    input  wire                                   m00_axi_wready,

    input  wire [1:0]                             m00_axi_bresp,
    input  wire                                   m00_axi_bvalid,
    output wire                                   m00_axi_bready,

    // Unused read channel, tied off so the top can be packaged as full AXI4 if needed.
    output wire [C_M00_AXI_ADDR_WIDTH-1:0]        m00_axi_araddr,
    output wire [7:0]                             m00_axi_arlen,
    output wire [2:0]                             m00_axi_arsize,
    output wire [1:0]                             m00_axi_arburst,
    output wire [2:0]                             m00_axi_arprot,
    output wire [3:0]                             m00_axi_arcache,
    output wire                                   m00_axi_arlock,
    output wire [3:0]                             m00_axi_arqos,
    output wire                                   m00_axi_arvalid,
    input  wire                                   m00_axi_arready,

    input  wire [C_M00_AXI_DATA_WIDTH-1:0]        m00_axi_rdata,
    input  wire [1:0]                             m00_axi_rresp,
    input  wire                                   m00_axi_rlast,
    input  wire                                   m00_axi_rvalid,
    output wire                                   m00_axi_rready
);

    localparam [2:0] AXI_SIZE_4B = 3'b010;

    pixel_write_engine_AXI #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .SEQ_W(SEQ_W),
        .X_RES(X_RES),
        .Y_RES(Y_RES),
        .C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH),
        .C_M_AXI_ADDR_WIDTH(C_M00_AXI_ADDR_WIDTH),
        .C_M_AXI_DATA_WIDTH(C_M00_AXI_DATA_WIDTH)
    ) pixel_write_engine_AXI_inst (
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_pixel_index(in_pixel_index),
        .in_r(in_r),
        .in_g(in_g),
        .in_b(in_b),

        .M_AXI_AWADDR(m00_axi_awaddr),
        .M_AXI_AWLEN(m00_axi_awlen),
        .M_AXI_AWSIZE(m00_axi_awsize),
        .M_AXI_AWBURST(m00_axi_awburst),
        .M_AXI_AWVALID(m00_axi_awvalid),
        .M_AXI_AWREADY(m00_axi_awready),

        .M_AXI_WDATA(m00_axi_wdata),
        .M_AXI_WSTRB(m00_axi_wstrb),
        .M_AXI_WLAST(m00_axi_wlast),
        .M_AXI_WVALID(m00_axi_wvalid),
        .M_AXI_WREADY(m00_axi_wready),

        .M_AXI_BRESP(m00_axi_bresp),
        .M_AXI_BVALID(m00_axi_bvalid),
        .M_AXI_BREADY(m00_axi_bready),

        .S_AXI_ACLK(s00_axi_aclk),
        .S_AXI_ARESETN(s00_axi_aresetn),
        .S_AXI_AWADDR(s00_axi_awaddr),
        .S_AXI_AWPROT(s00_axi_awprot),
        .S_AXI_AWVALID(s00_axi_awvalid),
        .S_AXI_AWREADY(s00_axi_awready),
        .S_AXI_WDATA(s00_axi_wdata),
        .S_AXI_WSTRB(s00_axi_wstrb),
        .S_AXI_WVALID(s00_axi_wvalid),
        .S_AXI_WREADY(s00_axi_wready),
        .S_AXI_BRESP(s00_axi_bresp),
        .S_AXI_BVALID(s00_axi_bvalid),
        .S_AXI_BREADY(s00_axi_bready),
        .S_AXI_ARADDR(s00_axi_araddr),
        .S_AXI_ARPROT(s00_axi_arprot),
        .S_AXI_ARVALID(s00_axi_arvalid),
        .S_AXI_ARREADY(s00_axi_arready),
        .S_AXI_RDATA(s00_axi_rdata),
        .S_AXI_RRESP(s00_axi_rresp),
        .S_AXI_RVALID(s00_axi_rvalid),
        .S_AXI_RREADY(s00_axi_rready)
    );

    assign m00_axi_awprot  = 3'b000;
    assign m00_axi_awcache = 4'b0011;
    assign m00_axi_awlock  = 1'b0;
    assign m00_axi_awqos   = 4'b0000;

    assign m00_axi_araddr  = '0;
    assign m00_axi_arlen   = 8'd0;
    assign m00_axi_arsize  = AXI_SIZE_4B;
    assign m00_axi_arburst = 2'b01;
    assign m00_axi_arprot  = 3'b000;
    assign m00_axi_arcache = 4'b0011;
    assign m00_axi_arlock  = 1'b0;
    assign m00_axi_arqos   = 4'b0000;
    assign m00_axi_arvalid = 1'b0;
    assign m00_axi_rready  = 1'b0;

endmodule
