`timescale 1ns / 1ps

module tb_iter_core_array();

    localparam int NUM_CORES = 32;
    localparam int W         = 26;
    localparam int FRAC      = 22;
    localparam int SEQ_W     = 16;
    localparam int ITER_W    = 16;
    localparam int MODE_W    = 3;
    localparam logic [W-1:0] ESCAPE_THRESH_Q422 = 26'sh100_0000;


    logic clk;
    logic rst_n; 

    // Inputs
    logic [NUM_CORES-1:0]          in_valid;
    logic [(W*NUM_CORES)-1:0]      c_r;
    logic [(W*NUM_CORES)-1:0]      c_i;
    logic [(W*NUM_CORES)-1:0]      z0_r;
    logic [(W*NUM_CORES)-1:0]      z0_i;
    logic [(ITER_W*NUM_CORES)-1:0] in_max_iter;
    logic [(MODE_W*NUM_CORES)-1:0] in_mode;
    logic [(SEQ_W*NUM_CORES)-1:0]  in_seq;

    // Outputs
    logic [NUM_CORES-1:0]          in_ready; 
    logic [NUM_CORES-1:0]          out_ready;
    logic [NUM_CORES-1:0]          out_valid;
    logic [(SEQ_W*NUM_CORES)-1:0]  out_seq;
    logic [(ITER_W*NUM_CORES)-1:0] out_iter;
    logic [(W*NUM_CORES)-1:0]      out_z_r;
    logic [(W*NUM_CORES)-1:0]      out_z_i;
    logic [NUM_CORES-1:0]          out_escaped;
    logic [NUM_CORES-1:0]          out_overflow;

    int timeout = 0;
    logic core0_done = 0;
    logic core1_done = 0;
    logic core31_done = 0;
    logic [SEQ_W-1:0] seq_0 = 0, seq_1 = 0, seq_31 = 0;
    logic esc_0 = 0, esc_1 = 0, esc_31 = 0;


    iter_core_array #(
        .NUM_CORES(NUM_CORES),
        .W(W),
        .FRAC(FRAC),
        .SEQ_W(SEQ_W),
        .ITER_W(ITER_W),
        .MODE_W(MODE_W),
        .ESCAPE_THRESH_Q422(ESCAPE_THRESH_Q422)
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


    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end


    task automatic load_core_data(
        input int id, 
        input logic signed [W-1:0] test_c_r, 
        input logic signed [W-1:0] test_c_i, 
        input logic [SEQ_W-1:0]    test_seq
    );
        begin
            c_r         [id*W      +: W]      <= test_c_r;
            c_i         [id*W      +: W]      <= test_c_i;
            z0_r        [id*W      +: W]      <= 0;
            z0_i        [id*W      +: W]      <= 0;
            in_max_iter [id*ITER_W +: ITER_W] <= 256;
            in_mode     [id*MODE_W +: MODE_W] <= 0; 
            in_seq      [id*SEQ_W  +: SEQ_W]  <= test_seq;
            
            in_valid[id] <= 1'b1;
        end
    endtask


    initial begin
        rst_n       = 0;  
        in_valid    = '0;
        c_r         = '0;
        c_i         = '0;
        z0_r        = '0;
        z0_i        = '0;
        in_max_iter = '0;
        in_mode     = '0;
        in_seq      = '0;
        
        out_ready   = {NUM_CORES{1'b1}}; 

        repeat(10) @(posedge clk);
        rst_n <= 1; 
        
        repeat(2) @(posedge clk);

        $display("--- Injecting test coordinates into Cores 0, 1, and 31 ---");

        load_core_data(0,   26'sh080_0000,  26'sh080_0000, 16'd101); // Core 0
        load_core_data(1,  -26'sh080_0000,  26'sh080_0000, 16'd102); // Core 1
        load_core_data(31,  26'sh040_0000, -26'sh040_0000, 16'd999); // Core 31
        
        @(posedge clk);
        in_valid <= '0;

        $display("--- Waiting for Cores to assert out_valid ---");

        while (!(core0_done && core1_done && core31_done) && timeout < 1500) begin
            
            // Latch Core 0
            if (out_valid[0] && !core0_done) begin
                core0_done = 1;
                seq_0 = out_seq[0*SEQ_W +: SEQ_W];
                esc_0 = out_escaped[0];
                $display(" -> Core 0 finished at cycle %0d", timeout);
            end
            
            // Latch Core 1
            if (out_valid[1] && !core1_done) begin
                core1_done = 1;
                seq_1 = out_seq[1*SEQ_W +: SEQ_W];
                esc_1 = out_escaped[1];
                $display(" -> Core 1 finished at cycle %0d", timeout);
            end
            
            // Latch Core 31
            if (out_valid[31] && !core31_done) begin
                core31_done = 1;
                seq_31 = out_seq[31*SEQ_W +: SEQ_W];
                esc_31 = out_escaped[31];
                $display(" -> Core 31 finished at cycle %0d", timeout);
            end
            
            @(posedge clk);
            timeout++;
        end
        
        if (timeout >= 1500) begin
            $display("WARNING: Simulation timed out.");
        end else begin
            $display("SUCCESS: All tracked cores finished processing!");
        end

        // 5. Check the latched data
        $display("Core 0  Sequence Out: %d | Escaped: %b", seq_0, esc_0);
        $display("Core 1  Sequence Out: %d | Escaped: %b", seq_1, esc_1);
        $display("Core 31 Sequence Out: %d | Escaped: %b", seq_31, esc_31);

        #50;
        $display("--- Simulation Complete ---");
        $finish;
    end

endmodule