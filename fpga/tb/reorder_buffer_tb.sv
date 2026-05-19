`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 19.05.2026 17:06:59
// Design Name: 
// Module Name: reorder_buffer_tb
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

module reorder_buffer_tb();

    // Parameters
    localparam W      = 26;
    localparam ITER_W = 16;
    localparam SEQ_W  = 16;
    localparam BUFFER_SIZE = 4096;

    // Signals
    logic                 clk;
    logic                 rst;
    
    logic                 in_valid;
    logic                 out_ready;
    logic [ITER_W-1:0]    in_iter_count;
    logic [SEQ_W-1:0]     in_seq_num;
    logic signed [W-1:0]  in_z_r;
    logic signed [W-1:0]  in_z_i;
    logic                 in_escaped;
    logic                 in_overflow;

    logic                 palette_ready;
    logic                 out_valid;
    logic [ITER_W-1:0]    out_iter_count;
    logic [SEQ_W-1:0]     out_seq_num;
    logic signed [W-1:0]  out_z_r;
    logic signed [W-1:0]  out_z_i;
    logic                 out_escaped;
    logic                 out_overflow;

    reorder_buffer #(
        .W(W),
        .ITER_W(ITER_W),
        .SEQ_W(SEQ_W),
        .BUFFER_SIZE(BUFFER_SIZE)
    ) dut (
        .clk(clk),
        .rst(rst),
        .palette_ready(palette_ready),
        .in_iter_count(in_iter_count),
        .in_seq_num(in_seq_num),
        .in_z_r(in_z_r),
        .in_z_i(in_z_i),
        .in_escaped(in_escaped),
        .in_overflow(in_overflow),
        .in_valid(in_valid),
        .out_ready(out_ready),
        .out_iter_count(out_iter_count),
        .out_seq_num(out_seq_num),
        .out_z_r(out_z_r),
        .out_z_i(out_z_i),
        .out_escaped(out_escaped),
        .out_overflow(out_overflow),
        .out_valid(out_valid)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    task send_pixel(input int seq);
        begin
            // Wait until the buffer is ready to accept data
            wait(out_ready == 1'b1);
            
            // Apply data
            in_seq_num    = seq;
            in_iter_count = seq * 10;
            in_z_r        = seq;      
            in_z_i        = -seq;     
            in_escaped    = 1'b1;
            in_overflow   = 1'b0;
            in_valid      = 1'b1;
            
            @(posedge clk);
            in_valid = 1'b0; // Pulse valid for exactly 1 cycle
        end
    endtask

    initial begin
        // Initialize inputs
        rst           = 1;
        in_valid      = 0;
        in_seq_num    = 0;
        in_iter_count = 0;
        in_z_r = 0; in_z_i = 0; in_escaped = 0; in_overflow = 0;
        
        // Hold reset
        repeat(5) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        $display("--- PHASE 1: In-Order Arrival ---");
        send_pixel(0);
        send_pixel(1);
        send_pixel(2);
        
        repeat(5) @(posedge clk);

        $display("--- PHASE 2: Out-Of-Order Arrival ---");
        // We send 6, 4, 5. Buffer must stall waiting for 3.
        send_pixel(6);
        send_pixel(4);
        send_pixel(5);
        repeat(3) @(posedge clk); 
        send_pixel(3); 
        
        repeat(10) @(posedge clk);

        $display("--- PHASE 3: Downstream Backpressure ---");
        // Send 7, 8, 9 while the receiver thread turns off 'palette_ready'
        send_pixel(7);
        send_pixel(8);
        send_pixel(9);

        repeat(30) @(posedge clk);
        $display("TEST PASSED: All pixels reordered correctly!");
        $finish;
    end

    // Verification Thread (The Receiver)

    int expected_output_seq = 0;

    initial begin
        palette_ready = 1;
        
        forever begin
            @(posedge clk);
            
            if (out_valid && palette_ready) begin
                
                if (out_seq_num !== expected_output_seq) begin
                    $error("FATAL: Out of order! Expected %0d, got %0d", expected_output_seq, out_seq_num);
                    $finish;
                end else begin
                    $display("[%0t] Successfully read Sequence: %0d (Iter: %0d)", $time, out_seq_num, out_iter_count);
                end
                
                expected_output_seq++;
            end

            // Simulate the Palette LUT stalling at frame #7
            if (expected_output_seq == 7 && palette_ready == 1'b1) begin
                $display("[%0t] DOWNSTREAM STALL: Palette LUT is busy...", $time);
                palette_ready = 0;
                repeat(10) @(posedge clk);
                palette_ready = 1;
                $display("[%0t] DOWNSTREAM RESUME: Palette LUT is ready.", $time);
            end
        end
    end

    initial begin
        #5000; 
        $error("FATAL: Simulation timed out. Pipeline likely stalled forever.");
        $finish;
    end

endmodule
