`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
//
// Testbench: colour_palette_tb
// Project: FractalScope
// Tool: Vivado 2023.2 
//
// Description:
//   Self-checking unit testbench for colour_palette
//   ...
//////////////////////////////////////////////////////////////////////////////////

module colour_palette_tb;

    localparam int W            = 26;
    localparam int ITER_W       = 16;
    localparam int SEQ_W        = 20;
    localparam int PALETTE_BITS = 10;
    localparam real CLK_PERIOD  = 10.0;

    logic clk = 1'b0;
    logic rst_n;

    always #(CLK_PERIOD/2.0) clk = ~clk;

    logic                in_valid;
    logic                palette_ready;
    logic [ITER_W-1:0]   in_iter_count;
    logic [SEQ_W-1:0]    in_seq_num;
    logic signed [W-1:0] in_z_r;
    logic signed [W-1:0] in_z_i;
    logic                in_escaped;
    logic                in_overflow;
    logic                in_sof;
    logic                in_eol;

    logic                out_valid;
    logic                out_ready;
    logic [SEQ_W-1:0]    out_seq_num;
    logic [7:0]          out_r;
    logic [7:0]          out_g;
    logic [7:0]          out_b;
    logic                out_sof;
    logic                out_eol;

    int n_tests;
    int n_fails;

    colour_palette #(
        .W            (W),
        .ITER_W       (ITER_W),
        .SEQ_W        (SEQ_W),
        .PALETTE_BITS (PALETTE_BITS)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),

        .in_valid      (in_valid),
        .palette_ready (palette_ready),
        .in_iter_count (in_iter_count),
        .in_seq_num    (in_seq_num),
        .in_z_r        (in_z_r),
        .in_z_i        (in_z_i),
        .in_escaped    (in_escaped),
        .in_overflow   (in_overflow),
        .in_sof        (in_sof),
        .in_eol        (in_eol),

        .out_valid     (out_valid),
        .out_ready     (out_ready),
        .out_seq_num   (out_seq_num),
        .out_r         (out_r),
        .out_g         (out_g),
        .out_b         (out_b),
        .out_sof       (out_sof),
        .out_eol       (out_eol)
    );

    // Reference colour model
    function automatic logic [23:0] expected_palette_lookup(
        input logic [PALETTE_BITS-1:0] idx
    );
        logic [7:0] t;
        logic [7:0] r;
        logic [7:0] g;
        logic [7:0] b;
        begin
            if (PALETTE_BITS >= 8) begin
                t = idx[PALETTE_BITS-1 -: 8];
            end
            else begin
                t = {idx, {(8-PALETTE_BITS){1'b0}}};
            end

            r = t;
            g = {t[4:0], t[7:5]};
            b = 8'hFF - t;

            expected_palette_lookup = {r, g, b};
        end
    endfunction

    function automatic logic [23:0] expected_colour(
        input logic [ITER_W-1:0] iter_count,
        input logic              escaped,
        input logic              overflow
    );
        logic [PALETTE_BITS-1:0] idx;
        begin
            idx = iter_count[PALETTE_BITS-1:0];

            if (overflow) begin
                expected_colour = 24'hFF_00_FF;
            end
            else if (!escaped) begin
                expected_colour = 24'h00_00_00;
            end
            else begin
                expected_colour = expected_palette_lookup(idx);
            end
        end
    endfunction

    // Common checking/driving helpers
    task automatic check(input logic condition, input string msg);
        n_tests++;
        if (condition) begin
            $display("[PASS] %s", msg);
        end
        else begin
            n_fails++;
            $display("[FAIL] %s", msg);
        end
    endtask

    task automatic check_eq_1(
        input logic actual,
        input logic expected,
        input string msg
    );
        check(actual === expected,
              $sformatf("%s: expected=%0b actual=%0b", msg, expected, actual));
    endtask

    task automatic check_eq_seq(
        input logic [SEQ_W-1:0] actual,
        input logic [SEQ_W-1:0] expected,
        input string msg
    );
        check(actual === expected,
              $sformatf("%s: expected=0x%05h actual=0x%05h", msg, expected, actual));
    endtask

    task automatic check_eq_rgb(
        input logic [23:0] actual,
        input logic [23:0] expected,
        input string msg
    );
        check(actual === expected,
              $sformatf("%s: expected=0x%06h actual=0x%06h", msg, expected, actual));
    endtask

    task automatic clear_inputs();
        in_valid      = 1'b0;
        in_iter_count = '0;
        in_seq_num    = '0;
        in_z_r        = '0;
        in_z_i        = '0;
        in_escaped    = 1'b0;
        in_overflow   = 1'b0;
        in_sof        = 1'b0;
        in_eol        = 1'b0;
    endtask

    task automatic drive_pixel(
        input logic [ITER_W-1:0]   iter_count,
        input logic [SEQ_W-1:0]    seq_num,
        input logic signed [W-1:0] z_r,
        input logic signed [W-1:0] z_i,
        input logic                escaped,
        input logic                overflow,
        input logic                sof,
        input logic                eol
    );
        in_valid      = 1'b1;
        in_iter_count = iter_count;
        in_seq_num    = seq_num;
        in_z_r        = z_r;
        in_z_i        = z_i;
        in_escaped    = escaped;
        in_overflow   = overflow;
        in_sof        = sof;
        in_eol        = eol;
    endtask

    task automatic check_ready(input logic expected, input string name);
        #1;
        check_eq_1(palette_ready, expected, {name, ": palette_ready"});
    endtask

    task automatic check_invalid(input string name);
        #1;
        check_eq_1(out_valid, 1'b0, {name, ": out_valid low"});
    endtask

    task automatic check_output(
        input logic              expected_valid,
        input logic [SEQ_W-1:0]  expected_seq,
        input logic [23:0]       expected_rgb,
        input logic              expected_sof,
        input logic              expected_eol,
        input string             name
    );
        #1;

        check_eq_1(out_valid, expected_valid, {name, ": out_valid"});

        if (expected_valid) begin
            check_eq_seq(out_seq_num, expected_seq, {name, ": out_seq_num"});
            check_eq_rgb({out_r, out_g, out_b}, expected_rgb, {name, ": RGB"});
            check_eq_1(out_sof, expected_sof, {name, ": out_sof"});
            check_eq_1(out_eol, expected_eol, {name, ": out_eol"});
        end
    endtask

    task automatic apply_and_expect(
        input logic [ITER_W-1:0]   iter_count,
        input logic [SEQ_W-1:0]    seq_num,
        input logic signed [W-1:0] z_r,
        input logic signed [W-1:0] z_i,
        input logic                escaped,
        input logic                overflow,
        input logic                sof,
        input logic                eol,
        input string               name
    );
        logic [23:0] exp_rgb;
        begin
            exp_rgb = expected_colour(iter_count, escaped, overflow);

            out_ready = 1'b1;
            drive_pixel(iter_count, seq_num, z_r, z_i, escaped, overflow, sof, eol);
            check_ready(1'b1, {name, " before edge"});
            @(posedge clk);
            check_output(1'b1, seq_num, exp_rgb, sof, eol, {name, " after edge"});
        end
    endtask

    task automatic reset_dut();
        rst_n     = 1'b0;
        out_ready = 1'b0;
        clear_inputs();
        repeat (3) @(posedge clk);
        #1;
        check_eq_1(out_valid, 1'b0, "reset: out_valid low");
        check_eq_seq(out_seq_num, '0, "reset: out_seq_num zero");
        check_eq_rgb({out_r, out_g, out_b}, 24'h00_00_00, "reset: RGB zero");
        check_eq_1(out_sof, 1'b0, "reset: out_sof low");
        check_eq_1(out_eol, 1'b0, "reset: out_eol low");
        check_eq_1(palette_ready, 1'b1, "reset: palette_ready high because output register is empty");
        rst_n = 1'b1;
        @(posedge clk);
        #1;
    endtask

    // Test sequence
    initial begin
        n_tests = 0;
        n_fails = 0;

        rst_n = 1'b0;
        out_ready = 1'b0;
        clear_inputs();

        $display("============================================================");
        $display(" colour_palette_tb: Vivado 2023.2 final-BD-interface testbench v2");
        $display(" W=%0d ITER_W=%0d SEQ_W=%0d PALETTE_BITS=%0d", W, ITER_W, SEQ_W, PALETTE_BITS);
        $display("============================================================");

        // T0: reset and empty/idle behaviour.
        reset_dut();

        out_ready = 1'b0;
        clear_inputs();
        check_ready(1'b1, "T1 empty output register while downstream stalled");
        @(posedge clk);
        check_invalid("T1 idle while empty and downstream stalled");
        check_ready(1'b1, "T1 still ready because there is no held output");

        out_ready = 1'b1;
        @(posedge clk);
        check_invalid("T1 idle while empty and downstream ready");
        check_ready(1'b1, "T1 still ready when empty and downstream ready");

        // T2: core colour mapping cases.
        apply_and_expect(16'h0000, 20'h00001, 26'sd0,       26'sd0,       1'b1, 1'b0, 1'b1, 1'b0,
                         "T2a escaped iter 0 gives blue endpoint and SOF");
        apply_and_expect(16'h0003, 20'h00002, 26'sd123,     -26'sd456,    1'b1, 1'b0, 1'b0, 1'b0,
                         "T2b escaped iter 3 proves low two palette bits are compressed away");
        apply_and_expect(16'h0004, 20'h00003, -26'sd2222,   26'sd3333,    1'b1, 1'b0, 1'b0, 1'b0,
                         "T2c escaped iter 4 increments compressed colour t");
        apply_and_expect(16'h03FF, 20'h00004, 26'sd1,       26'sd2,       1'b1, 1'b0, 1'b0, 1'b1,
                         "T2d escaped palette max gives red-yellow endpoint and EOL");
        apply_and_expect(16'hFFFF, 20'h00005, 26'sd3,       26'sd4,       1'b1, 1'b0, 1'b1, 1'b1,
                         "T2e escaped high iter uses low PALETTE_BITS only and propagates both flags");
        apply_and_expect(16'h0123, 20'h00006, 26'sd111,     26'sd222,     1'b0, 1'b0, 1'b0, 1'b1,
                         "T2f non-escaped pixel is black regardless of iteration count");
        apply_and_expect(16'h0456, 20'h00007, -26'sd111,    -26'sd222,    1'b0, 1'b1, 1'b1, 1'b0,
                         "T2g overflow overrides non-escaped black with magenta");
        apply_and_expect(16'h0789, 20'h00008, 26'sd98765,   -26'sd12345,  1'b1, 1'b1, 1'b0, 1'b0,
                         "T2h overflow overrides escaped gradient with magenta");

        // T3: z values are currently deliberately ignored by the colour function.
        apply_and_expect(16'h0010, 20'h00100, 26'sd0,                 26'sd0,                 1'b1, 1'b0, 1'b0, 1'b0,
                         "T3a baseline escaped colour with zero z values");
        apply_and_expect(16'h0010, 20'h00101, 26'sh1FF_FFF,          -26'sh1FF_FFF,          1'b1, 1'b0, 1'b0, 1'b0,
                         "T3b same iter/flags but extreme z values gives same RGB");

        // T4 setup: first explicitly drain the output register.
        // The previous apply_and_expect call leaves out_valid high with the last
        // accepted pixel still registered. Because palette_ready is
        // (!out_valid || out_ready), dropping out_ready immediately after T3
        // would correctly make palette_ready low. That would test a full/stalled
        // register, not an empty/stalled register.
        clear_inputs();
        out_ready = 1'b1;
        @(posedge clk);
        #1;
        check_invalid("T4 setup bubble drains previous valid output");
        check_ready(1'b1, "T4 setup output register is empty");

        // T4: output register can capture while downstream is not ready if it is empty.
        out_ready = 1'b0;
        drive_pixel(16'h0020, 20'h00200, 26'sd55, -26'sd66, 1'b1, 1'b0, 1'b1, 1'b0);
        check_ready(1'b1, "T4a empty register accepts first pixel even with out_ready low");
        @(posedge clk);
        check_output(1'b1, 20'h00200, expected_colour(16'h0020, 1'b1, 1'b0), 1'b1, 1'b0,
                     "T4a first pixel held under downstream backpressure");
        check_ready(1'b0, "T4a output now full and downstream stalled");

        // T5: when full and stalled, a new input must not overwrite the held output.
        drive_pixel(16'h03F0, 20'h00201, -26'sd77, 26'sd88, 1'b1, 1'b0, 1'b0, 1'b1);
        check_ready(1'b0, "T5a full stalled register refuses replacement pixel before edge");
        @(posedge clk);
        check_output(1'b1, 20'h00200, expected_colour(16'h0020, 1'b1, 1'b0), 1'b1, 1'b0,
                     "T5a held pixel remains unchanged while stalled");
        check_ready(1'b0, "T5a still not ready while downstream remains stalled");

        // T6: simultaneous consume and replace when downstream becomes ready.
        out_ready = 1'b1;
        drive_pixel(16'h03F0, 20'h00201, -26'sd77, 26'sd88, 1'b1, 1'b0, 1'b0, 1'b1);
        check_ready(1'b1, "T6a downstream ready allows simultaneous consume and replace");
        @(posedge clk);
        check_output(1'b1, 20'h00201, expected_colour(16'h03F0, 1'b1, 1'b0), 1'b0, 1'b1,
                     "T6a replacement pixel appears after simultaneous transfer");
        check_ready(1'b1, "T6a remains ready because downstream is ready");

        // T7: valid deassertion should clear valid and sideband flags when a bubble is accepted.
        clear_inputs();
        out_ready = 1'b1;
        @(posedge clk);
        #1;
        check_eq_1(out_valid, 1'b0, "T7 bubble clears out_valid");
        check_eq_1(out_sof,   1'b0, "T7 bubble clears out_sof");
        check_eq_1(out_eol,   1'b0, "T7 bubble clears out_eol");
        check_ready(1'b1, "T7 ready remains high after bubble");

        // T8: continuous ready stream. This mirrors the normal path from reorder_buffer
        // through colour_palette into packer when packer is not backpressuring.
        out_ready = 1'b1;
        for (int i = 0; i < 12; i++) begin
            logic [ITER_W-1:0] iter_i;
            logic [SEQ_W-1:0]  seq_i;
            logic              sof_i;
            logic              eol_i;
            logic              escaped_i;
            logic              overflow_i;
            logic [23:0]       rgb_i;

            iter_i     = i[0] ? (16'h0300 + i) : (16'h0010 + (i * 13));
            seq_i      = 20'h01000 + i;
            sof_i      = (i == 0);
            eol_i      = (i == 5) || (i == 11);
            escaped_i  = (i != 3);
            overflow_i = (i == 8);
            rgb_i      = expected_colour(iter_i, escaped_i, overflow_i);

            drive_pixel(iter_i, seq_i, 26'sd100 + i, -26'sd200 - i, escaped_i, overflow_i, sof_i, eol_i);
            check_ready(1'b1, $sformatf("T8 stream pixel %0d before edge", i));
            @(posedge clk);
            check_output(1'b1, seq_i, rgb_i, sof_i, eol_i,
                         $sformatf("T8 stream pixel %0d after edge", i));
        end

        clear_inputs();
        @(posedge clk);
        check_invalid("T8 final bubble after continuous stream");

        // T9: reset flushes a valid held output and zeroes registered fields.
        out_ready = 1'b0;
        drive_pixel(16'h00A0, 20'h00AAA, 26'sd1, 26'sd2, 1'b1, 1'b0, 1'b1, 1'b1);
        @(posedge clk);
        check_output(1'b1, 20'h00AAA, expected_colour(16'h00A0, 1'b1, 1'b0), 1'b1, 1'b1,
                     "T9 valid output before reset flush");
        rst_n = 1'b0;
        clear_inputs();
        @(posedge clk);
        #1;
        check_eq_1(out_valid, 1'b0, "T9 reset flushes out_valid");
        check_eq_seq(out_seq_num, '0, "T9 reset clears out_seq_num");
        check_eq_rgb({out_r, out_g, out_b}, 24'h00_00_00, "T9 reset clears RGB");
        check_eq_1(out_sof, 1'b0, "T9 reset clears out_sof");
        check_eq_1(out_eol, 1'b0, "T9 reset clears out_eol");
        check_eq_1(palette_ready, 1'b1, "T9 reset makes palette_ready high");
        rst_n = 1'b1;
        @(posedge clk);

        $display("============================================================");
        $display(" colour_palette_tb summary: tests=%0d fails=%0d", n_tests, n_fails);
        $display("============================================================");

        if (n_fails == 0) begin
            $display("[TB PASS] colour_palette_tb completed successfully");
        end
        else begin
            $display("[TB FAIL] colour_palette_tb completed with %0d failures", n_fails);
            $fatal(1);
        end

        $finish;
    end

endmodule
