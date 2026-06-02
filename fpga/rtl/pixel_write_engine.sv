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



endmodule