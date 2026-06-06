`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: pixel_scheduler_tb
// Tool: Vivado 2023.2 / XSim
//
// Final-parameter self-checking testbench for the FractalScope pixel_scheduler.
// This version intentionally mirrors the target block design geometry:
//   NUM_CORES = 16
//   X_RES     = 1280
//   Y_RES     = 720
//   SEQ_W     = 20
//
// It runs a complete 720p Mandelbrot frame and a complete 720p Julia frame.
// Set the Vivado simulation runtime to "all" or at least around 25 ms.
//////////////////////////////////////////////////////////////////////////////////

module pixel_scheduler_tb;

    localparam int NUM_CORES    = 16;
    localparam int W            = 26;
    localparam int FRAC         = 22;
    localparam int SEQ_W        = 20;
    localparam int ITER_W       = 16;
    localparam int MODE_W       = 3;
    localparam int X_RES        = 1280;
    localparam int Y_RES        = 720;
    localparam int FRAME_PIXELS = X_RES * Y_RES;

    localparam logic [MODE_W-1:0] MODE_MANDELBROT = 3'd0;
    localparam logic [MODE_W-1:0] MODE_JULIA      = 3'd1;

    logic clk;
    logic rst_n;

    logic signed [W-1:0] x_jump;
    logic signed [W-1:0] y_jump;
    logic signed [W-1:0] x_min;
    logic signed [W-1:0] y_min;
    logic                last_pixel;

    logic signed [W-1:0] jul_c_r;
    logic signed [W-1:0] jul_c_i;
    logic [ITER_W-1:0]   in_max_iter;
    logic [MODE_W-1:0]   in_mode;

    logic [NUM_CORES-1:0] in_ready;
    logic [NUM_CORES-1:0] in_valid;

    logic signed [(W*NUM_CORES)-1:0] c_r;
    logic signed [(W*NUM_CORES)-1:0] c_i;
    logic signed [(W*NUM_CORES)-1:0] z0_r;
    logic signed [(W*NUM_CORES)-1:0] z0_i;
    logic [(ITER_W*NUM_CORES)-1:0]   out_max_iter;
    logic [(MODE_W*NUM_CORES)-1:0]   out_mode;
    logic [(SEQ_W*NUM_CORES)-1:0]    out_seq;

    int unsigned tests;
    int unsigned fails;

    pixel_scheduler #(
        .NUM_CORES(NUM_CORES),
        .W(W),
        .SEQ_W(SEQ_W),
        .ITER_W(ITER_W),
        .MODE_W(MODE_W),
        .X_RES(X_RES),
        .Y_RES(Y_RES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .x_jump(x_jump),
        .y_jump(y_jump),
        .x_min(x_min),
        .y_min(y_min),
        .last_pixel(last_pixel),
        .jul_c_r(jul_c_r),
        .jul_c_i(jul_c_i),
        .in_max_iter(in_max_iter),
        .in_mode(in_mode),
        .in_ready(in_ready),
        .in_valid(in_valid),
        .c_r(c_r),
        .c_i(c_i),
        .z0_r(z0_r),
        .z0_i(z0_i),
        .out_max_iter(out_max_iter),
        .out_mode(out_mode),
        .out_seq(out_seq)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic signed [W-1:0] q_from_real(input real value);
        q_from_real = $rtoi(value * (1 << FRAC));
    endfunction

    function automatic logic signed [W-1:0] get_s26(
        input logic signed [(W*NUM_CORES)-1:0] bus,
        input int idx
    );
        get_s26 = bus[(idx*W) +: W];
    endfunction

    function automatic logic [SEQ_W-1:0] get_seq(input int idx);
        get_seq = out_seq[(idx*SEQ_W) +: SEQ_W];
    endfunction

    function automatic logic [ITER_W-1:0] get_iter(input int idx);
        get_iter = out_max_iter[(idx*ITER_W) +: ITER_W];
    endfunction

    function automatic logic [MODE_W-1:0] get_mode(input int idx);
        get_mode = out_mode[(idx*MODE_W) +: MODE_W];
    endfunction

    function automatic int highest_ready(input logic [NUM_CORES-1:0] mask);
        int result;
        begin
            result = 0;
            for (int i = 0; i < NUM_CORES; i++) begin
                if (mask[i]) begin
                    result = i;
                end
            end
            highest_ready = result;
        end
    endfunction

    function automatic logic [NUM_CORES-1:0] ready_mask_for_seq(input int unsigned seq);
        logic [NUM_CORES-1:0] mask;
        int a;
        int b;
        int c;
        begin
            mask = '0;
            a = seq % NUM_CORES;
            b = (seq * 5 + 3) % NUM_CORES;
            c = (seq * 7 + 11) % NUM_CORES;
            mask[a] = 1'b1;
            mask[b] = 1'b1;
            if ((seq % 97) == 0) begin
                mask[c] = 1'b1;
            end
            if ((seq % 4096) == 0) begin
                mask[NUM_CORES-1] = 1'b1;
            end
            ready_mask_for_seq = mask;
        end
    endfunction

    function automatic logic signed [W-1:0] expected_coord(
        input logic signed [W-1:0] min_value,
        input logic signed [W-1:0] step_value,
        input int unsigned idx
    );
        longint signed tmp;
        begin
            tmp = $signed(min_value) + (longint'(idx) * $signed(step_value));
            expected_coord = tmp[W-1:0];
        end
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

    task automatic check_no_dispatch(input string label);
        begin
            #1;
            tb_check(in_valid === '0, {label, ": in_valid should be zero"});
            tb_check(last_pixel === 1'b0, {label, ": last_pixel should be low"});
        end
    endtask

    task automatic check_dispatch(
        input int unsigned exp_seq_int,
        input logic [MODE_W-1:0] exp_mode,
        input string label
    );
        int exp_x;
        int exp_y;
        int chosen;
        logic [NUM_CORES-1:0] exp_valid;
        logic signed [W-1:0] exp_cr;
        logic signed [W-1:0] exp_ci;
        begin
            exp_x = exp_seq_int % X_RES;
            exp_y = exp_seq_int / X_RES;
            chosen = highest_ready(in_ready);
            exp_valid = '0;
            exp_valid[chosen] = 1'b1;
            exp_cr = expected_coord(x_min, x_jump, exp_x);
            exp_ci = expected_coord(y_min, y_jump, exp_y);

            #1;
            tb_check(in_valid === exp_valid,
                     $sformatf("%s seq=%0d: in_valid one-hot to highest ready core %0d", label, exp_seq_int, chosen));
            tb_check(last_pixel === (exp_seq_int == FRAME_PIXELS-1),
                     $sformatf("%s seq=%0d: last_pixel alignment", label, exp_seq_int));
            tb_check(get_seq(chosen) === SEQ_W'(exp_seq_int),
                     $sformatf("%s seq=%0d: selected core sequence", label, exp_seq_int));
            tb_check(get_iter(chosen) === in_max_iter,
                     $sformatf("%s seq=%0d: max_iter propagation", label, exp_seq_int));
            tb_check(get_mode(chosen) === exp_mode,
                     $sformatf("%s seq=%0d: mode propagation", label, exp_seq_int));

            if (exp_mode == MODE_JULIA) begin
                tb_check(get_s26(c_r, chosen) === jul_c_r,
                         $sformatf("%s seq=%0d: Julia c_r constant", label, exp_seq_int));
                tb_check(get_s26(c_i, chosen) === jul_c_i,
                         $sformatf("%s seq=%0d: Julia c_i constant", label, exp_seq_int));
                tb_check(get_s26(z0_r, chosen) === exp_cr,
                         $sformatf("%s seq=%0d: Julia z0_r coordinate", label, exp_seq_int));
                tb_check(get_s26(z0_i, chosen) === exp_ci,
                         $sformatf("%s seq=%0d: Julia z0_i coordinate", label, exp_seq_int));
            end
            else begin
                tb_check(get_s26(c_r, chosen) === exp_cr,
                         $sformatf("%s seq=%0d: Mandelbrot c_r coordinate", label, exp_seq_int));
                tb_check(get_s26(c_i, chosen) === exp_ci,
                         $sformatf("%s seq=%0d: Mandelbrot c_i coordinate", label, exp_seq_int));
                tb_check(get_s26(z0_r, chosen) === '0,
                         $sformatf("%s seq=%0d: Mandelbrot z0_r zero", label, exp_seq_int));
                tb_check(get_s26(z0_i, chosen) === '0,
                         $sformatf("%s seq=%0d: Mandelbrot z0_i zero", label, exp_seq_int));
            end
        end
    endtask

    task automatic apply_reset(input logic [MODE_W-1:0] mode_value, input logic [ITER_W-1:0] iter_value);
        begin
            rst_n       = 1'b0;
            in_ready    = '0;
            in_mode     = mode_value;
            in_max_iter = iter_value;
            repeat (4) @(posedge clk);
            check_no_dispatch("during reset");
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
            check_no_dispatch("after reset release with no ready cores");
        end
    endtask

    task automatic run_full_frame(input logic [MODE_W-1:0] mode_value, input string label);
        logic [NUM_CORES-1:0] mask;
        begin
            $display("------------------------------------------------------------");
            $display("%s full 1280x720 frame start", label);
            $display("------------------------------------------------------------");

            for (int unsigned seq = 0; seq < FRAME_PIXELS; seq++) begin
                if ((seq % 50000) == 0) begin
                    @(negedge clk);
                    in_ready = '0;
                    check_no_dispatch($sformatf("%s seq=%0d deliberate one-cycle no-ready stall", label, seq));
                    @(posedge clk);
                end

                @(negedge clk);
                mask = ready_mask_for_seq(seq);
                in_ready = mask;
                check_dispatch(seq, mode_value, label);
                @(posedge clk);

                if ((seq != 0) && ((seq % 100000) == 0)) begin
                    $display("[PROGRESS] %s dispatched %0d/%0d", label, seq, FRAME_PIXELS);
                end
            end

            @(negedge clk);
            in_ready = '1;
            repeat (5) begin
                check_no_dispatch({label, " frame_done blocks further dispatch"});
                @(posedge clk);
                @(negedge clk);
            end
        end
    endtask

    initial begin
        tests = 0;
        fails = 0;

        x_min   = q_from_real(-2.0);
        y_min   = q_from_real(-1.125);
        x_jump  = q_from_real(3.0 / 1280.0);
        y_jump  = q_from_real(2.25 / 720.0);
        jul_c_r = q_from_real(-0.8);
        jul_c_i = q_from_real(0.156);

        rst_n       = 1'b0;
        in_ready    = '0;
        in_max_iter = 16'd256;
        in_mode     = MODE_MANDELBROT;

        $display("============================================================");
        $display(" pixel_scheduler_tb: final 16-core 720p testbench");
        $display(" NUM_CORES=%0d X_RES=%0d Y_RES=%0d FRAME_PIXELS=%0d", NUM_CORES, X_RES, Y_RES, FRAME_PIXELS);
        $display("============================================================");

        apply_reset(MODE_MANDELBROT, 16'd256);
        run_full_frame(MODE_MANDELBROT, "Mandelbrot");

        apply_reset(MODE_JULIA, 16'd77);
        run_full_frame(MODE_JULIA, "Julia");

        $display("============================================================");
        $display(" pixel_scheduler_tb summary: tests=%0d fails=%0d", tests, fails);
        $display("============================================================");

        if (fails == 0) begin
            $display("[TB PASS] pixel_scheduler_tb completed successfully");
            $finish;
        end
        else begin
            $fatal(1, "[TB FAIL] pixel_scheduler_tb completed with %0d failure(s)", fails);
        end
    end

endmodule
