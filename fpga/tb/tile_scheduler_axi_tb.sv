`timescale 1ns / 1ps
`default_nettype none

module tile_scheduler_axi_tb;


    parameter integer NUM_CORES = 4;
    parameter integer W         = 26;
    parameter integer INDEX_W   = 20;
    parameter integer ITER_W    = 16;
    parameter integer MODE_W    = 3;
    parameter integer X_RES     = 64;  // Scaled down
    parameter integer Y_RES     = 32;  // Scaled down
    parameter integer C_S_AXI_DATA_WIDTH = 32;
    parameter integer C_S_AXI_ADDR_WIDTH = 5;

 
    logic S_AXI_ACLK;
    logic S_AXI_ARESETN;

    // AXI Write Address Channel
    logic [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR;
    logic [2:0]                    S_AXI_AWPROT;
    logic                          S_AXI_AWVALID;
    logic                          S_AXI_AWREADY;

    // AXI Write Data Channel
    logic [C_S_AXI_DATA_WIDTH-1:0] S_AXI_WDATA;
    logic [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB;
    logic                          S_AXI_WVALID;
    logic                          S_AXI_WREADY;

    // AXI Write Response Channel
    logic [1:0]                    S_AXI_BRESP;
    logic                          S_AXI_BVALID;
    logic                          S_AXI_BREADY;

    // AXI Read Address Channel (Unused in this test but wired)
    logic [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR;
    logic [2:0]                    S_AXI_ARPROT;
    logic                          S_AXI_ARVALID;
    logic                          S_AXI_ARREADY;

    // AXI Read Data Channel
    logic [C_S_AXI_DATA_WIDTH-1:0] S_AXI_RDATA;
    logic [1:0]                    S_AXI_RRESP;
    logic                          S_AXI_RVALID;
    logic                          S_AXI_RREADY;

    // Core outputs
    logic [NUM_CORES-1:0]          in_ready;
    logic [NUM_CORES-1:0]          in_valid;
    logic                          last_pixel;
    logic                          render_rst_n_out;
    logic signed [(W*NUM_CORES)-1:0] c_r;
    logic signed [(W*NUM_CORES)-1:0] c_i;
    logic signed [(W*NUM_CORES)-1:0] z0_r;
    logic signed [(W*NUM_CORES)-1:0] z0_i;
    logic [(ITER_W*NUM_CORES)-1:0]   out_max_iter;
    logic [(MODE_W*NUM_CORES)-1:0]   out_mode;
    logic [(INDEX_W*NUM_CORES)-1:0]  out_pixel_index;

    tile_scheduler_AXI #(
        .NUM_CORES(NUM_CORES),
        .W(W),
        .INDEX_W(INDEX_W),
        .ITER_W(ITER_W),
        .MODE_W(MODE_W),
        .X_RES(X_RES),
        .Y_RES(Y_RES),
        .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
    ) dut (
        .S_AXI_ACLK(S_AXI_ACLK),
        .S_AXI_ARESETN(S_AXI_ARESETN),
        .S_AXI_AWADDR(S_AXI_AWADDR),
        .S_AXI_AWPROT(S_AXI_AWPROT),
        .S_AXI_AWVALID(S_AXI_AWVALID),
        .S_AXI_AWREADY(S_AXI_AWREADY),
        .S_AXI_WDATA(S_AXI_WDATA),
        .S_AXI_WSTRB(S_AXI_WSTRB),
        .S_AXI_WVALID(S_AXI_WVALID),
        .S_AXI_WREADY(S_AXI_WREADY),
        .S_AXI_BRESP(S_AXI_BRESP),
        .S_AXI_BVALID(S_AXI_BVALID),
        .S_AXI_BREADY(S_AXI_BREADY),
        .S_AXI_ARADDR(S_AXI_ARADDR),
        .S_AXI_ARPROT(S_AXI_ARPROT),
        .S_AXI_ARVALID(S_AXI_ARVALID),
        .S_AXI_ARREADY(S_AXI_ARREADY),
        .S_AXI_RDATA(S_AXI_RDATA),
        .S_AXI_RRESP(S_AXI_RRESP),
        .S_AXI_RVALID(S_AXI_RVALID),
        .S_AXI_RREADY(S_AXI_RREADY),
        
        .in_ready(in_ready),
        .in_valid(in_valid),
        .last_pixel(last_pixel),
        .render_rst_n_out(render_rst_n_out),
        .c_r(c_r),
        .c_i(c_i),
        .z0_r(z0_r),
        .z0_i(z0_i),
        .out_max_iter(out_max_iter),
        .out_mode(out_mode),
        .out_pixel_index(out_pixel_index)
    );


    initial begin
        S_AXI_ACLK = 0;
        forever #5 S_AXI_ACLK = ~S_AXI_ACLK;
    end


    task axi_write(input logic [C_S_AXI_ADDR_WIDTH-1:0] addr, input logic [C_S_AXI_DATA_WIDTH-1:0] data);
        begin
            @(posedge S_AXI_ACLK);
            S_AXI_AWADDR  <= addr;
            S_AXI_AWVALID <= 1'b1;
            S_AXI_WDATA   <= data;
            S_AXI_WVALID  <= 1'b1;
            S_AXI_WSTRB   <= 4'b1111; // Write all 4 bytes
            S_AXI_BREADY  <= 1'b1;

            // Wait for both address and data to be accepted by the slave
            fork
                begin
                    wait(S_AXI_AWREADY);
                    @(posedge S_AXI_ACLK);
                    S_AXI_AWVALID <= 1'b0;
                end
                begin
                    wait(S_AXI_WREADY);
                    @(posedge S_AXI_ACLK);
                    S_AXI_WVALID <= 1'b0;
                end
            join
            
            // Wait for write response
            wait(S_AXI_BVALID);
            @(posedge S_AXI_ACLK);
            S_AXI_BREADY <= 1'b0;
        end
    endtask


    initial begin
        // Initialize Signals
        S_AXI_ARESETN = 0;
        S_AXI_AWADDR  = 0;
        S_AXI_AWPROT  = 0;
        S_AXI_AWVALID = 0;
        S_AXI_WDATA   = 0;
        S_AXI_WSTRB   = 0;
        S_AXI_WVALID  = 0;
        S_AXI_BREADY  = 0;
        S_AXI_ARADDR  = 0;
        S_AXI_ARPROT  = 0;
        S_AXI_ARVALID = 0;
        S_AXI_RREADY  = 0;
        
        in_ready = '0;

        // Apply Global Reset
        #20;
        S_AXI_ARESETN = 1;
        #20;

        $display("--- Programming AXI Registers ---");
        
        // reg0: x_jump (0x00)
        axi_write(5'h00, 32'd100);  
        
        // reg1: y_jump (0x04)
        axi_write(5'h04, 32'd1000); 
        
        // reg2: x_min (0x08)
        axi_write(5'h08, 32'd0);
        
        // reg3: y_min (0x0C)
        axi_write(5'h0C, 32'd0);
        
        // reg4: jul_c_r (0x10)
        axi_write(5'h10, 32'h000_AAAA);
        
        // reg5: jul_c_i (0x14)
        axi_write(5'h14, 32'h000_BBBB);
        
        // reg6: in_max_iter [15:0] and in_mode [18:16] (0x18)
        // Mode 0, Max Iter 64 -> Value is just 64
        axi_write(5'h18, 32'd64);

        $display("--- Starting Renderer ---");
        // All cores are ready
        in_ready = 4'b1111;
        
        // reg7: software_run (0x1C) - Write 1 to bit 0 to start!
        axi_write(5'h1C, 32'd1);

        // Wait a sufficient amount of time for the frame to finish
        // (X_RES=64, Y_RES=32 is 2048 pixels. At 1 pixel/clock, that's ~20us)
        #25000;
        
        $display("========================================");
        $display("TEST FINISHED");
        $display("========================================");
        $finish;
    end


    integer active_core;
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN && render_rst_n_out && (|in_valid)) begin
            active_core = -1;
            for (int i = 0; i < NUM_CORES; i++) begin
                if (in_valid[i]) begin
                    active_core = i;
                    break;
                end
            end
            
            if (active_core != -1) begin
                logic signed [W-1:0]       core_c_r;
                logic signed [W-1:0]       core_c_i;
                logic [INDEX_W-1:0]        core_idx;
                
                core_c_r = c_r[(active_core*W) +: W];
                core_c_i = c_i[(active_core*W) +: W];
                core_idx = out_pixel_index[(active_core*INDEX_W) +: INDEX_W];

                $display("Time: %0t | Core: %0d | AbsIdx: %0d | Math: c_r=%0d, c_i=%0d", 
                          $time, active_core, core_idx, core_c_r, core_c_i);
            end
        end
    end

endmodule