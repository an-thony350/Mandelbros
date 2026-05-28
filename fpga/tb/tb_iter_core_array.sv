`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_iter_core_array
// Tool: Vivado 2023.2
//
// Final-parameter smoke/scoreboard test for iter_core_array.
// Mirrors final NUM_CORES=16 and the final flat packed bus interface.
//////////////////////////////////////////////////////////////////////////////////

module tb_iter_core_array;

    localparam int NUM_CORES = 16;
    localparam int W         = 26;
    localparam int FRAC      = 22;
    localparam int SEQ_W     = 20;
    localparam int ITER_W    = 16;
    localparam int MODE_W    = 3;

    localparam logic [MODE_W-1:0] MODE_MANDEL = 3'd0;

    logic clk;
    logic rst_n;

    logic [NUM_CORES-1:0]          in_valid;
    logic [(W*NUM_CORES)-1:0]      c_r;
    logic [(W*NUM_CORES)-1:0]      c_i;
    logic [(W*NUM_CORES)-1:0]      z0_r;
    logic [(W*NUM_CORES)-1:0]      z0_i;
    logic [(ITER_W*NUM_CORES)-1:0] in_max_iter;
    logic [(MODE_W*NUM_CORES)-1:0] in_mode;
    logic [(SEQ_W*NUM_CORES)-1:0]  in_seq;
    logic [NUM_CORES-1:0]          in_ready;

    logic               out_ready;
    logic               out_valid;
    logic [SEQ_W-1:0]   out_seq;
    logic [ITER_W-1:0]  out_iter;
    logic [W-1:0]       out_z_r;
    logic [W-1:0]       out_z_i;
    logic               out_escaped;
    logic               out_overflow;

    int unsigned tests;
    int unsigned fails;
    bit seen [0:NUM_CORES-1];
    int unsigned n_seen;

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

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic signed [W-1:0] q_from_real(input real value);
        q_from_real = $rtoi(value * (1 << FRAC));
    endfunction

    task automatic tb_check(input bit condition, input string message);
        begin
            tests++;
            if (!condition) begin
                fails++;
                $display("[FAIL] %0t: %s", $time, message);
            end
        end
    endtask

    task automatic clear_inputs;
        begin
            in_valid    = '0;
            c_r         = '0;
            c_i         = '0;
            z0_r        = '0;
            z0_i        = '0;
            in_max_iter = '0;
            in_mode     = '0;
            in_seq      = '0;
        end
    endtask

    task automatic set_core_input(input int core_id, input int unsigned seq);
        begin
            c_r[(core_id*W) +: W]                    = q_from_real(2.0);
            c_i[(core_id*W) +: W]                    = q_from_real(2.0);
            z0_r[(core_id*W) +: W]                   = q_from_real(0.0);
            z0_i[(core_id*W) +: W]                   = q_from_real(0.0);
            in_max_iter[(core_id*ITER_W) +: ITER_W]  = 16'd32;
            in_mode[(core_id*MODE_W) +: MODE_W]      = MODE_MANDEL;
            in_seq[(core_id*SEQ_W) +: SEQ_W]         = SEQ_W'(seq);
            in_valid[core_id]                        = 1'b1;
        end
    endtask

    initial begin
        tests = 0;
        fails = 0;
        n_seen = 0;
        rst_n = 1'b0;
        out_ready = 1'b1;
        clear_inputs();
        for (int i = 0; i < NUM_CORES; i++) begin
            seen[i] = 1'b0;
        end

        $display("============================================================");
        $display(" tb_iter_core_array: final 16-core testbench");
        $display("============================================================");

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        tb_check(in_ready === {NUM_CORES{1'b1}}, "all 16 cores ready after reset");

        // Fire one rapidly escaping Mandelbrot pixel into every core on the same cycle.
        clear_inputs();
        for (int i = 0; i < NUM_CORES; i++) begin
            set_core_input(i, 1000 + i);
        end
        #1;
        tb_check(in_ready === {NUM_CORES{1'b1}}, "all 16 cores still ready before launch");
        @(posedge clk);
        @(negedge clk);
        clear_inputs();

        for (int cycle = 0; (cycle < 1000) && (n_seen < NUM_CORES); cycle++) begin
            @(posedge clk);
            if (out_valid && out_ready) begin
                int idx;
                idx = int'(out_seq) - 1000;
                tb_check((idx >= 0) && (idx < NUM_CORES),
                         $sformatf("output seq %0d maps into launched 16-core range", out_seq));
                if ((idx >= 0) && (idx < NUM_CORES)) begin
                    tb_check(!seen[idx], $sformatf("seq %0d not duplicated", out_seq));
                    seen[idx] = 1'b1;
                    n_seen++;
                    tb_check(out_escaped === 1'b1, $sformatf("seq %0d escaped as expected", out_seq));
                    tb_check(out_iter < 16'd32, $sformatf("seq %0d escaped before max_iter", out_seq));
                end
            end
        end

        tb_check(n_seen == NUM_CORES, "received one result from each of the 16 cores");
        for (int i = 0; i < NUM_CORES; i++) begin
            tb_check(seen[i], $sformatf("saw seq %0d from core-array batch", 1000+i));
        end

        $display("============================================================");
        $display(" tb_iter_core_array summary: tests=%0d fails=%0d", tests, fails);
        $display("============================================================");

        if (fails == 0) begin
            $display("[TB PASS] tb_iter_core_array completed successfully");
            $finish;
        end
        else begin
            $fatal(1, "[TB FAIL] tb_iter_core_array completed with %0d failure(s)", fails);
        end
    end

endmodule
