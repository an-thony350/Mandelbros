`timescale 1 ns / 1 ps

//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
// 
// Create Date: 04.06.2026 16:11:23
// Design Name: Tile Scheduler Top
// Module Name: Tile_Scheduler_top
// Project Name: FractalScope
// Target Devices: PYNQ-Z1
// Tool Versions: Vivado 2023.2
// Description: Top-level module for the tile scheduler
// 
// Dependencies: tile_scheduler_AXI, tile_scheduler.sv
//
// Additional Comments: None
////////////////////////////////////////////////////////////////////////////////// 


	module tile_scheduler_top #
	(
		// Users to add parameters here
        parameter integer NUM_CORES = 16,
        parameter integer W         = 26,
        parameter integer INDEX_W   = 20,
        parameter integer ITER_W    = 16,
        parameter integer MODE_W    = 3,
        parameter integer X_RES     = 1280,
        parameter integer Y_RES     = 720,
        parameter integer TILE_W    = 32,
        parameter integer TILE_H    = 16,
		// User parameters ends
		// Do not modify the parameters beyond this line


		// Parameters of Axi Slave Bus Interface S00_AXI
		parameter integer C_S00_AXI_DATA_WIDTH	= 32,
		parameter integer C_S00_AXI_ADDR_WIDTH	= 5
	)
	(
		// Users to add ports here
        input wire  [NUM_CORES-1:0]     in_ready,
        output wire [NUM_CORES-1:0]     in_valid,
        output wire                     last_pixel,
        
        output wire render_rst_n_out,
        
        output wire signed [(W*NUM_CORES)-1:0]      c_r,
        output wire signed [(W*NUM_CORES)-1:0]      c_i,
        output wire signed [(W*NUM_CORES)-1:0]      z0_r,
        output wire signed [(W*NUM_CORES)-1:0]      z0_i,
        output wire [(ITER_W*NUM_CORES)-1:0]        out_max_iter,
        output wire [(MODE_W*NUM_CORES)-1:0]        out_mode,
        output wire [(INDEX_W*NUM_CORES)-1:0]       out_pixel_index,
        
        output wire                            out_fill_valid,
        output wire [INDEX_W-2:0]              out_fill_index,
        output wire [ITER_W-1:0]               out_fill_iter,
        output wire                            out_fill_escaped,
        
        input  wire                            iter_in_valid,
        input  wire [ITER_W-1:0]               iter_in_iter,
        input  wire                            iter_in_is_perimeter,
        input  wire                            iter_in_escaped,
        input  wire                            iter_in_ready,
        
        input  wire                            cp_in_fill_ready,


		// User ports ends
		// Do not modify the ports beyond this line


		// Ports of Axi Slave Bus Interface S00_AXI
		input wire  s00_axi_aclk,
		input wire  s00_axi_aresetn,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
		input wire [2 : 0] s00_axi_awprot,
		input wire  s00_axi_awvalid,
		output wire  s00_axi_awready,
		input wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
		input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
		input wire  s00_axi_wvalid,
		output wire  s00_axi_wready,
		output wire [1 : 0] s00_axi_bresp,
		output wire  s00_axi_bvalid,
		input wire  s00_axi_bready,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
		input wire [2 : 0] s00_axi_arprot,
		input wire  s00_axi_arvalid,
		output wire  s00_axi_arready,
		output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
		output wire [1 : 0] s00_axi_rresp,
		output wire  s00_axi_rvalid,
		input wire  s00_axi_rready
	);
// Instantiation of Axi Bus Interface S00_AXI
	tile_scheduler_AXI # ( 
	    .NUM_CORES(NUM_CORES),
	    .W(W),
	    .INDEX_W(INDEX_W),
	    .ITER_W(ITER_W),
	    .MODE_W(MODE_W),
	    .X_RES(X_RES),
	    .Y_RES(Y_RES),
		.C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
    ) tile_scheduler_AXI_inst (
	    .in_ready(in_ready),
        .last_pixel(last_pixel),
        .in_valid(in_valid),
        .iter_in_valid(iter_in_valid),
        .iter_in_iter(iter_in_iter),
        .iter_in_is_perimeter(iter_in_is_perimeter),
        .iter_in_escaped(iter_in_escaped),
        .iter_in_ready(iter_in_ready),
        .cp_in_fill_ready(cp_in_fill_ready),
        .render_rst_n_out(render_rst_n_out),
        .c_r(c_r),
        .c_i(c_i),
        .z0_r(z0_r),
        .z0_i(z0_i),
        .out_max_iter(out_max_iter),
        .out_mode(out_mode),
        .out_pixel_index(out_pixel_index),
        .out_fill_valid(out_fill_valid),
        .out_fill_index(out_fill_index),
        .out_fill_iter(out_fill_iter),
        .out_fill_escaped(out_fill_escaped),
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

	// Add user logic here
    
	// User logic ends

	endmodule

