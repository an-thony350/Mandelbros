`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: reorder_buffer_tb
// Tool: Vivado 2023.2 / XSim
//
// Final-parameter self-checking testbench for the FractalScope reorder_buffer.
// This version intentionally mirrors the target downstream geometry:
//   BUFFER_SIZE = 4096
//   SCREEN_W    = 1280
//   SEQ_W       = 20
//
// It verifies out-of-order release, full line EOL timing, 4096-entry full-buffer
// behaviour, rejected write while full, retry after drain, and reset restart.
//////////////////////////////////////////////////////////////////////////////////

module reorder_buffer_tb;

    localparam int W           = 26;
    localparam int ITER_W      = 16;
    localparam int SEQ_W       = 20;
    localparam int BUFFER_SIZE = 4096;
    localparam int SCREEN_W    = 1280;
    localparam int MAX_ITER    = 256;

    logic clk;
    logic rst_n;
    logic palette_ready;

    logic [ITER_W-1:0]   in_iter_count;
    logic [SEQ_W-1:0]    in_seq_num;
    logic signed [W-1:0] in_z_r;
    logic signed [W-1:0] in_z_i;
    logic                in_escaped;
    logic                in_overflow;
    logic                in_valid;

    logic                out_ready;
    logic [ITER_W-1:0]   out_iter_count;
    logic [SEQ_W-1:0]    out_seq_num;
    logic signed [W-1:0] out_z_r;
    logic signed [W-1:0] out_z_i;
    logic                out_escaped;
    logic                out_overflow;
    logic                out_valid;
    logic                out_sof;
    logic                out_eol;
    logic                out_hit_max;

    int unsigned tests;
    int unsigned fails;

    reorder_buffer #(
        .W(W),
        .ITER_W(ITER_W),
        .SEQ_W(SEQ_W),
        .BUFFER_SIZE(BUFFER_SIZE),
        .SCREEN_W(SCREEN_W),
        .MAX_ITER(MAX_ITER)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
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
        .out_valid(out_valid),
        .out_sof(out_sof),
        .out_eol(out_eol),
        .out_hit_max(out_hit_max)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic [ITER_W-1:0] exp_iter(input int unsigned seq);
        exp_iter = (seq * 13 + 16'h1234);
    endfunction

    function automatic logic signed [W-1:0] exp_z_r(input int unsigned seq);
        int signed tmp;
        begin
            tmp = seq * 101 - 17;
            exp_z_r = tmp;
        end
    endfunction

    function automatic logic signed [W-1:0] exp_z_i(input int unsigned seq);
        int signed tmp;
        begin
            tmp = -((seq * 53) + 9);
            exp_z_i = tmp;
        end
    endfunction

    function automatic logic exp_escaped(input int unsigned seq);
        exp_escaped = ((seq % 3) != 1);
    endfunction

    function automatic logic exp_overflow(input int unsigned seq);
        exp_overflow = ((seq % 5) == 0);
    endfunction

    function automatic logic exp_sof(input int unsigned seq);
        exp_sof = (seq == 0);
    endfunction

    function automatic logic exp_eol(input int unsigned seq);
        exp_eol = ((seq % SCREEN_W) == (SCREEN_W - 1));
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

    task automatic clear_input;
        begin
            in_valid      = 1'b0;
            in_seq_num    = '0;
            in_iter_count = '0;
            in_z_r        = '0;
            in_z_i        = '0;
            in_escaped    = 1'b0;
            in_overflow   = 1'b0;
        end
    endtask

    task automatic drive_pixel(input int unsigned seq);
        begin
            in_seq_num    = SEQ_W'(seq);
            in_iter_count = exp_iter(seq);
            in_z_r        = exp_z_r(seq);
            in_z_i        = exp_z_i(seq);
            in_escaped    = exp_escaped(seq);
            in_overflow   = exp_overflow(seq);
            in_valid      = 1'b1;
        end
    endtask

    task automatic expect_no_output(input string label);
        begin
            #1;
            tb_check(out_valid === 1'b0, {label, ": out_valid low"});
            tb_check(out_hit_max === 1'b0, {label, ": out_hit_max low when invalid"});
        end
    endtask

    task automatic expect_output(input int unsigned seq, input string label);
        begin
            #1;
            tb_check(out_valid === 1'b1, $sformatf("%s seq=%0d: out_valid", label, seq));
            tb_check(out_seq_num === SEQ_W'(seq), $sformatf("%s seq=%0d: out_seq_num", label, seq));
            tb_check(out_iter_count === exp_iter(seq), $sformatf("%s seq=%0d: iter", label, seq));
            tb_check(out_z_r === exp_z_r(seq), $sformatf("%s seq=%0d: z_r", label, seq));
            tb_check(out_z_i === exp_z_i(seq), $sformatf("%s seq=%0d: z_i", label, seq));
            tb_check(out_escaped === exp_escaped(seq), $sformatf("%s seq=%0d: escaped", label, seq));
            tb_check(out_overflow === exp_overflow(seq), $sformatf("%s seq=%0d: overflow", label, seq));
            tb_check(out_sof === exp_sof(seq), $sformatf("%s seq=%0d: sof", label, seq));
            tb_check(out_eol === exp_eol(seq), $sformatf("%s seq=%0d: eol", label, seq));
            tb_check(out_hit_max === (1'b1 && !exp_escaped(seq)), $sformatf("%s seq=%0d: hit_max", label, seq));
        end
    endtask

    task automatic write_pixel(input int unsigned seq, input string label);
        begin
            @(negedge clk);
            drive_pixel(seq);
            #1;
            tb_check(out_ready === 1'b1, $sformatf("%s seq=%0d: out_ready before write", label, seq));
            @(posedge clk);
            @(negedge clk);
            clear_input();
        end
    endtask

    task automatic attempt_rejected_write(input int unsigned seq, input string label);
        begin
            @(negedge clk);
            drive_pixel(seq);
            #1;
            tb_check(out_ready === 1'b0, $sformatf("%s seq=%0d: out_ready low before rejected write", label, seq));
            @(posedge clk);
            @(negedge clk);
            clear_input();
        end
    endtask

    task automatic consume_expected(input int unsigned seq, input string label);
        begin
            // Called while positioned before the consuming clock edge. Do not
            // wait for another negedge here, otherwise a ready/valid output can
            // be consumed before it is checked.
            clear_input();
            palette_ready = 1'b1;
            expect_output(seq, label);
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic apply_reset;
        begin
            rst_n = 1'b0;
            palette_ready = 1'b0;
            clear_input();
            repeat (4) @(posedge clk);
            expect_no_output("during reset");
            tb_check(out_ready === 1'b1, "during reset: out_ready high");
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            expect_no_output("after reset release");
            tb_check(out_ready === 1'b1, "after reset release: out_ready high");
        end
    endtask

    initial begin
        tests = 0;
        fails = 0;
        rst_n = 1'b0;
        palette_ready = 1'b0;
        clear_input();

        $display("============================================================");
        $display(" reorder_buffer_tb: final 4096-entry / 1280-wide testbench");
        $display(" BUFFER_SIZE=%0d SCREEN_W=%0d SEQ_W=%0d", BUFFER_SIZE, SCREEN_W, SEQ_W);
        $display("============================================================");

        apply_reset();

        // Out-of-order completion: future pixels are stored until seq0 arrives.
        palette_ready = 1'b1;
        write_pixel(2, "T1 future seq2");
        expect_no_output("T1 seq2 cannot release before seq0");
        write_pixel(1, "T1 future seq1");
        expect_no_output("T1 seq1 cannot release before seq0");
        write_pixel(0, "T1 missing seq0");
        expect_output(0, "T1 seq0 visible");

        consume_expected(0, "T2 consume seq0");
        expect_output(1, "T2 seq1 visible");
        consume_expected(1, "T2 consume seq1");
        expect_output(2, "T2 seq2 visible");
        consume_expected(2, "T2 consume seq2");
        expect_no_output("T2 empty after seq2");

        // Advance through the rest of the first 1280-pixel line using final SCREEN_W.
        palette_ready = 1'b1;
        for (int unsigned seq = 3; seq < SCREEN_W; seq++) begin
            write_pixel(seq, "T3 first-line write");
            expect_output(seq, "T3 first-line output");
            consume_expected(seq, "T3 first-line consume");
        end
        expect_no_output("T3 empty after first 1280-pixel line");

        // Fill all 4096 entries while the palette is stalled.
        palette_ready = 1'b0;
        for (int unsigned seq = SCREEN_W; seq < SCREEN_W + BUFFER_SIZE; seq++) begin
            @(negedge clk);
            drive_pixel(seq);
            #1;
            tb_check(out_ready === 1'b1,
                     $sformatf("T4 fill full buffer seq=%0d: out_ready high before write", seq));
            @(posedge clk);
            if (((seq - SCREEN_W) % 512) == 0) begin
                $display("[PROGRESS] filled %0d/%0d entries", seq - SCREEN_W + 1, BUFFER_SIZE);
            end
        end
        @(negedge clk);
        clear_input();
        #1;
        tb_check(out_ready === 1'b0, "T4 full 4096-entry buffer deasserts out_ready");
        expect_output(SCREEN_W, "T4 oldest entry held while full and stalled");

        attempt_rejected_write(SCREEN_W + BUFFER_SIZE, "T5 rejected full-buffer write");
        expect_output(SCREEN_W, "T5 rejected write did not disturb oldest output");

        // Drain the full buffer and verify final SCREEN_W EOL continues correctly.
        palette_ready = 1'b1;
        for (int unsigned seq = SCREEN_W; seq < SCREEN_W + BUFFER_SIZE; seq++) begin
            consume_expected(seq, "T6 drain full buffer");
            if (((seq - SCREEN_W) % 512) == 0) begin
                $display("[PROGRESS] drained %0d/%0d entries", seq - SCREEN_W + 1, BUFFER_SIZE);
            end
        end
        @(negedge clk);
        expect_no_output("T6 rejected seq was not accidentally accepted");
        tb_check(out_ready === 1'b1, "T6 buffer ready after full drain");

        write_pixel(SCREEN_W + BUFFER_SIZE, "T7 retry rejected seq after space returns");
        expect_output(SCREEN_W + BUFFER_SIZE, "T7 retried seq visible");
        consume_expected(SCREEN_W + BUFFER_SIZE, "T7 consume retried seq");
        expect_no_output("T7 empty after retried seq");

        // Reset must restart expected sequence at zero.
        write_pixel(SCREEN_W + BUFFER_SIZE + 1, "T8 pre-reset write current frame");
        expect_output(SCREEN_W + BUFFER_SIZE + 1, "T8 pre-reset output visible");
        apply_reset();
        write_pixel(1, "T9 after reset future seq1");
        expect_no_output("T9 future seq1 held after reset");
        write_pixel(0, "T9 after reset seq0");
        expect_output(0, "T9 seq0 visible after reset restart");
        consume_expected(0, "T9 consume seq0 after reset");
        expect_output(1, "T9 seq1 visible after reset seq0 consumed");
        consume_expected(1, "T9 consume seq1 after reset");

        $display("============================================================");
        $display(" reorder_buffer_tb summary: tests=%0d fails=%0d", tests, fails);
        $display("============================================================");

        if (fails == 0) begin
            $display("[TB PASS] reorder_buffer_tb completed successfully");
            $finish;
        end
        else begin
            $fatal(1, "[TB FAIL] reorder_buffer_tb completed with %0d failure(s)", fails);
        end
    end

endmodule
