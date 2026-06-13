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
//   v3.0 direct framebuffer writer. Accepts coloured pixels carrying an absolute
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
    parameter int Y_RES        = 720
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
    input  logic [31:0]      frame_pixels_in,

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


    // Local Registers

    logic [ADDR_W-1:0] fifo_addr [0:15];
    logic [DATA_W-1:0] fifo_data [0:15];
    logic [3:0]        wr_ptr, rd_ptr;
    logic [4:0]        fifo_count;
    logic fifo_full, fifo_empty;

    logic [5:0] outstanding_writes;
    logic can_issue_axi;

    logic pending_aw, pending_w;

    logic b_fire, issue_fire;


    // Combinational logic configuring the AXI burst for single writes
    
    assign m_axi_awlen   = 8'd0;    
    assign m_axi_awsize  = 3'b010;  
    assign m_axi_awburst = 2'b01;  
    assign m_axi_awcache = 4'b1111;  
    assign m_axi_awprot  = 3'b000;
    assign m_axi_wstrb   = 4'hF;
    assign m_axi_wlast   = 1'b1;    


    // Combinational FIFO logic (check if FIFO ready/full)
    assign fifo_full  = (fifo_count == 5'd16);
    assign fifo_empty = (fifo_count == 5'd0);
    
    assign in_ready = !fifo_full && enable;

    // Sequential write logic for pixel data  into the FIFO buffer
    always_ff @(posedge clk) begin
        if (!rst_n || soft_reset) begin
            wr_ptr <= 0;
        end else if (in_valid && in_ready) begin
            fifo_addr[wr_ptr] <= framebuffer_base + (in_pixel_index << 2);
            fifo_data[wr_ptr] <= {8'h00, in_r, in_b, in_g};
            wr_ptr <= wr_ptr + 1;
        end
    end

    // Checks if axi burst is possible
    assign can_issue_axi = (outstanding_writes < 6'd30);

    // Sequential logic for burst of data from FIFO to AXI w & aw data
    
    always_ff @(posedge clk) begin
        if (!rst_n || soft_reset) begin
            m_axi_awvalid <= 0;
            m_axi_wvalid  <= 0;
            pending_aw    <= 0;
            pending_w     <= 0;
            rd_ptr        <= 0;
            fifo_count    <= 0;
            pixels_accepted <= 0;
        end else begin
            // Pull from FIFO if we have room on the AXI bus and aren't currently sending
            if (!fifo_empty && can_issue_axi && !pending_aw && !pending_w) begin
                m_axi_awvalid <= 1'b1;
                m_axi_awaddr  <= fifo_addr[rd_ptr];
                pending_aw    <= 1'b1;

                m_axi_wvalid  <= 1'b1;
                m_axi_wdata   <= fifo_data[rd_ptr];
                pending_w     <= 1'b1;

                rd_ptr          <= rd_ptr + 1;
                pixels_accepted <= pixels_accepted + 1;
            end
            
            if (m_axi_awready && m_axi_awvalid) begin
                m_axi_awvalid <= 1'b0;
                pending_aw    <= 1'b0;
            end
            
            if (m_axi_wready && m_axi_wvalid) begin
                m_axi_wvalid <= 1'b0;
                pending_w    <= 1'b0;
            end

            // FIFO Counter Management
            if ((in_valid && in_ready) && (!fifo_empty && can_issue_axi && !pending_aw && !pending_w))
                fifo_count <= fifo_count;
            else if (in_valid && in_ready)
                fifo_count <= fifo_count + 1;
            else if (!fifo_empty && can_issue_axi && !pending_aw && !pending_w)
                fifo_count <= fifo_count - 1;
        end
    end

    // 4. AXI RESPONSE ENGINE (B Channel)
    assign m_axi_bready = 1'b1;
    
    assign b_fire     = m_axi_bvalid && m_axi_bready;
    assign issue_fire = (!fifo_empty && can_issue_axi && !pending_aw && !pending_w);

    always_ff @(posedge clk) begin
        if (!rst_n || soft_reset || start) begin
            outstanding_writes <= 0;
            pixels_written     <= 0;
            write_errors       <= 0;
            done               <= 0;
        end else begin
            // Track outstanding requests
            if (issue_fire && !b_fire) 
                outstanding_writes <= outstanding_writes + 1;
            else if (!issue_fire && b_fire) 
                outstanding_writes <= outstanding_writes - 1;

            // Process response
            if (b_fire) begin
                pixels_written <= pixels_written + 1;
                if (m_axi_bresp != 2'b00) begin
                    write_errors <= write_errors + 1;
                end
                
                if (pixels_written + 1 == frame_pixels_in) begin
                    done <= 1'b1;
                end
            end
        end
    end

    // Status logic
    assign busy  = (pixels_accepted > 0) && !done;
    assign idle  = (pixels_accepted == 0) && !done;
    assign error = (write_errors > 0);

endmodule