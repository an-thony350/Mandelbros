`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 24.05.2026 20:29:06
// Design Name: 
// Module Name: tb_iter_core_array
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

module tb_iter_core_array();

    // -------------------------------------------------
    // Parameters matching the array
    // -------------------------------------------------
    localparam int NUM_CORES = 4; // Scaled down to 4 for easier waveform reading
    localparam int W         = 26;
    localparam int FRAC      = 22;
    localparam int SEQ_W     = 20;
    localparam int ITER_W    = 16;
    localparam int MODE_W    = 3;

    // -------------------------------------------------
    // Signals
    // -------------------------------------------------
    logic clk;
    logic rst_n;

    // Inputs to array
    logic [NUM_CORES-1:0]          in_valid;
    logic [(W*NUM_CORES)-1:0]      c_r;
    logic [(W*NUM_CORES)-1:0]      c_i;
    logic [(W*NUM_CORES)-1:0]      z0_r;
    logic [(W*NUM_CORES)-1:0]      z0_i;
    logic [(ITER_W*NUM_CORES)-1:0] in_max_iter;
    logic [(MODE_W*NUM_CORES)-1:0] in_mode;
    logic [(SEQ_W*NUM_CORES)-1:0]  in_seq;

    // Outputs from array (inbound ready)
    logic [NUM_CORES-1:0]          in_ready;

    // Downstream ROB interface
    logic               out_ready;
    logic               out_valid;
    logic [SEQ_W-1:0]   out_seq;
    logic [ITER_W-1:0]  out_iter;
    logic [W-1:0]       out_z_r;
    logic [W-1:0]       out_z_i;
    logic               out_escaped;
    logic               out_overflow;

    // -------------------------------------------------
    // DUT Instantiation
    // -------------------------------------------------
    iter_core_array #(
        .NUM_CORES(NUM_CORES),
        .W(W),
        .FRAC(FRAC),
        .SEQ_W(SEQ_W),
        .ITER_W(ITER_W),
        .MODE_W(MODE_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .c_r(c_r),
        .c_i(c_i),
        .z0_r(z0_r),
        .z0_i(z0_i),
        .in_max_iter(in_max_iter),
        .in_mode(in_mode),
        .in_seq(in_seq),
        .in_ready(in_ready),
        .out_ready(out_ready),
        .out_valid(out_valid),
        .out_seq(out_seq),
        .out_iter(out_iter),
        .out_z_r(out_z_r),
        .out_z_i(out_z_i),
        .out_escaped(out_escaped),
        .out_overflow(out_overflow)
    );

    // -------------------------------------------------
    // Clock Generation (100MHz = 10ns period)
    // -------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // -------------------------------------------------
    // Helper function: Real to Q4.22 conversion
    // -------------------------------------------------
    function logic [W-1:0] real_to_q422(real val);
        real scaled;
        scaled = val * (1 << FRAC);
        return $rtoi(scaled);
    endfunction

    // -------------------------------------------------
    // Main Test Stimulus
    // -------------------------------------------------
    initial begin
        // Initialize
        rst_n       = 0;
        in_valid    = '0;
        c_r         = '0;
        c_i         = '0;
        z0_r        = '0;
        z0_i        = '0;
        in_max_iter = '0;
        in_mode     = '0;
        in_seq      = '0;
        out_ready   = 1; // Always ready to receive results

        // Assert reset
        #20 rst_n = 1;
        #10;

        $display("--- Starting Mandelbrot Array Simulation ---");

        // -----------------------------------------------------
        // Fire Pixel 1 into Core 0: Origin (0,0)
        // Should hit max_iter without escaping
        // -----------------------------------------------------
        @(posedge clk);
        if (in_ready[0]) begin
            in_valid[0] = 1'b1;
            c_r[0 +: W] = real_to_q422(0.0);
            c_i[0 +: W] = real_to_q422(0.0);
            z0_r[0 +: W] = real_to_q422(0.0);
            z0_i[0 +: W] = real_to_q422(0.0);
            in_max_iter[0 +: ITER_W] = 16'd50; // max 50 iterations
            in_mode[0 +: MODE_W] = 3'd0;       // MODE_MANDEL
            in_seq[0 +: SEQ_W] = 20'd1001;     // arbitrary sequence ID
        end

        // -----------------------------------------------------
        // Fire Pixel 2 into Core 1: (2.0, 2.0)
        // Should escape on the very first iteration
        // -----------------------------------------------------
        @(posedge clk);
        in_valid[0] = 1'b0; // clear core 0

        if (in_ready[1]) begin
            in_valid[1] = 1'b1;
            c_r[1*W +: W] = real_to_q422(2.0);
            c_i[1*W +: W] = real_to_q422(2.0);
            z0_r[1*W +: W] = real_to_q422(0.0);
            z0_i[1*W +: W] = real_to_q422(0.0);
            in_max_iter[1*ITER_W +: ITER_W] = 16'd50;
            in_mode[1*MODE_W +: MODE_W] = 3'd0;
            in_seq[1*SEQ_W +: SEQ_W] = 20'd1002;
        end

        @(posedge clk);
        in_valid[1] = 1'b0; // clear core 1

        // Wait for results
        // Note: Core 1 will finish fast, Core 0 will take ~50 cycles
        fork
            begin
                wait(out_valid && out_seq == 20'd1002);
                $display("[%0t] Result 2 Received! Seq: %0d | Escaped: %0b | Iters: %0d", 
                         $time, out_seq, out_escaped, out_iter);
            end
            begin
                wait(out_valid && out_seq == 20'd1001);
                $display("[%0t] Result 1 Received! Seq: %0d | Escaped: %0b | Iters: %0d", 
                         $time, out_seq, out_escaped, out_iter);
            end
        join

        #50;
        $display("--- Simulation Complete ---");
        $finish;
    end

endmodule