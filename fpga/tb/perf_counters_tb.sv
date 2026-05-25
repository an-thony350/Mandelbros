`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 25.05.2026 16:51:36
// Design Name: 
// Module Name: tb_perf_counters
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


`timescale 1ns / 1ps

module tb_perf_counters();

    // ---------------------------------------------------------
    // Parameters & Signals
    // ---------------------------------------------------------
    localparam int ITER_W = 16;

    logic              clk;
    logic              rst_n;
    logic              stream_valid;
    logic              stream_ready;
    logic              sof_pulse;
    logic [ITER_W-1:0] pixel_iter;
    logic              pixel_escaped;
    logic              pixel_hit_max;

    logic [31:0]       snap_frame_cycles;
    logic [63:0]       snap_total_iters;
    logic [31:0]       snap_pixels_escaped;
    logic [31:0]       snap_pixels_hit_max;

    // ---------------------------------------------------------
    // DUT Instantiation
    // ---------------------------------------------------------
    perf_counters #(
        .ITER_W(ITER_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .stream_valid(stream_valid),
        .stream_ready(stream_ready),
        .sof_pulse(sof_pulse),
        .pixel_iter(pixel_iter),
        .pixel_escaped(pixel_escaped),
        .pixel_hit_max(pixel_hit_max),
        .snap_frame_cycles(snap_frame_cycles),
        .snap_total_iters(snap_total_iters),
        .snap_pixels_escaped(snap_pixels_escaped),
        .snap_pixels_hit_max(snap_pixels_hit_max)
    );

    // ---------------------------------------------------------
    // Clock Generation (100MHz)
    // ---------------------------------------------------------
    always #5 clk = ~clk;

    // ---------------------------------------------------------
    // Helper Task: Safely Feed a Pixel (with #1 delays)
    // ---------------------------------------------------------
    task feed_pixel(input int iter, input logic escaped, input logic hit_max, input logic is_sof);
        begin
            @(posedge clk); #1; 
            stream_valid  = 1'b1;
            stream_ready  = 1'b1; // Assume downstream (palette LUT) is ready
            sof_pulse     = is_sof;
            pixel_iter    = iter;
            pixel_escaped = escaped;
            pixel_hit_max = hit_max;

            // Hold for 1 clock cycle, then drop valid/sof
            @(posedge clk); #1;
            stream_valid  = 1'b0;
            sof_pulse     = 1'b0;
        end
    endtask

    // ---------------------------------------------------------
    // Main Stimulus
    // ---------------------------------------------------------
    initial begin
        clk           = 0;
        rst_n         = 0;
        stream_valid  = 0;
        stream_ready  = 0;
        sof_pulse     = 0;
        pixel_iter    = 0;
        pixel_escaped = 0;
        pixel_hit_max = 0;

        #20 rst_n = 1;
        #20;

        $display("--- Starting Performance Counters Test ---");

        // ==========================================
        // FRAME 1
        // ==========================================
        $display("-> Generating Frame 1...");
        
        // Pixel 0 (Start of Frame). Iter: 100, Escaped: 0, Max: 1
        feed_pixel(100, 1'b0, 1'b1, 1'b1);
        
        // Pixel 1. Iter: 45, Escaped: 1, Max: 0
        feed_pixel(45, 1'b1, 1'b0, 1'b0);

        // Pixel 2. Iter: 10, Escaped: 1, Max: 0
        feed_pixel(10, 1'b1, 1'b0, 1'b0);
        
        // Let some idle clock cycles pass to test the `frame_cycles` counter
        stream_ready = 1'b1;
        #100;

        // ==========================================
        // FRAME 2 (Triggers Snapshot)
        // ==========================================
        $display("-> Generating Frame 2 (Should trigger snapshot of Frame 1)...");
        
        // Pixel 0 of Frame 2. Iter: 256, Escaped: 0, Max: 1
        // By sending sof_pulse=1 here, the DUT should instantly push Frame 1's data to the snap outputs.
        feed_pixel(256, 1'b0, 1'b1, 1'b1);

        // Wait a cycle to let the snapshot registers securely update in simulation
        @(posedge clk); #1;

        $display("\n--- SNAPSHOT RESULTS ---");
        $display("Expected Total Iters: 155 (100+45+10)");
        $display("Actual Total Iters:   %0d", snap_total_iters);
        $display("Expected Escaped:     2");
        $display("Actual Escaped:       %0d", snap_pixels_escaped);
        $display("Expected Hit Max:     1");
        $display("Actual Hit Max:       %0d", snap_pixels_hit_max);
        $display("Frame Cycles passed:  %0d", snap_frame_cycles);
        $display("------------------------\n");

        #50;
        $finish;
    end
endmodule
