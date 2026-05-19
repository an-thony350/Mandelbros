`timescale 1ns / 1ps

module colour_palette_tb;

    localparam int W            = 26;
    localparam int ITER_W       = 16;
    localparam int SEQ_W        = 20;
    localparam int PALETTE_BITS = 10;

    localparam time CLK_PERIOD = 10ns;

    logic clk = 1'b0;
    logic rst;

    always #(CLK_PERIOD/2) clk = ~clk;

    // Input from reorder buffer
    logic                in_valid;
    logic                palette_ready;

    logic [ITER_W-1:0]   in_iter_count;
    logic [SEQ_W-1:0]    in_seq_num;
    logic signed [W-1:0] in_z_r;
    logic signed [W-1:0] in_z_i;
    logic                in_escaped;
    logic                in_overflow;

    // Output to framebuffer / pixel writer
    logic                out_valid;
    logic                out_ready;

    logic [SEQ_W-1:0]    out_seq_num;
    logic [7:0]          out_r;
    logic [7:0]          out_g;
    logic [7:0]          out_b;

    int n_tests;
    int n_fails;

    colour_palette #(
        .W            (W),
        .ITER_W       (ITER_W),
        .SEQ_W        (SEQ_W),
        .PALETTE_BITS (PALETTE_BITS)
    ) dut (
        .clk           (clk),
        .rst           (rst),

        .in_valid      (in_valid),
        .palette_ready (palette_ready),

        .in_iter_count (in_iter_count),
        .in_seq_num    (in_seq_num),
        .in_z_r        (in_z_r),
        .in_z_i        (in_z_i),
        .in_escaped    (in_escaped),
        .in_overflow   (in_overflow),

        .out_valid     (out_valid),
        .out_ready     (out_ready),

        .out_seq_num   (out_seq_num),
        .out_r         (out_r),
        .out_g         (out_g),
        .out_b         (out_b)
    );

    // Expected colour model

    function automatic logic [23:0] expected_palette_lookup(
        input logic [PALETTE_BITS-1:0] idx
    );
        logic [7:0] t;
        logic [7:0] r;
        logic [7:0] g;
        logic [7:0] b;
        begin
            t = idx[PALETTE_BITS-1 -: 8];

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

    // Test helpers

    task automatic check(input logic condition, input string msg);
        begin
            n_tests++;
            if (condition) begin
                $display("[PASS] %s", msg);
            end
            else begin
                n_fails++;
                $display("[FAIL] %s", msg);
            end
        end
    endtask

    task automatic clear_inputs();
        begin
            in_valid      = 1'b0;
            in_iter_count = '0;
            in_seq_num    = '0;
            in_z_r        = '0;
            in_z_i        = '0;
            in_escaped    = 1'b0;
            in_overflow   = 1'b0;
        end
    endtask

    task automatic drive_pixel(
        input int   iter_count,
        input int   seq_num,
        input int   z_r,
        input int   z_i,
        input logic escaped,
        input logic overflow
    );
        begin
            in_valid      = 1'b1;
            in_iter_count = iter_count[ITER_W-1:0];
            in_seq_num    = seq_num[SEQ_W-1:0];
            in_z_r        = z_r;
            in_z_i        = z_i;
            in_escaped    = escaped;
            in_overflow   = overflow;
        end
    endtask

    task automatic check_output(
        input logic              expected_valid,
        input int                expected_seq,
        input logic [23:0]       expected_rgb,
        input string             name
    );
        begin
            #1;

            check(out_valid === expected_valid,
                  {name, ": out_valid"});

            if (expected_valid) begin
                check(out_seq_num === expected_seq[SEQ_W-1:0],
                      {name, ": out_seq_num"});

                check({out_r, out_g, out_b} === expected_rgb,
                      {name, ": RGB"});
            end
        end
    endtask

    task automatic send_and_check(
        input int   iter_count,
        input int   seq_num,
        input int   z_r,
        input int   z_i,
        input logic escaped,
        input logic overflow,
        input string name
    );
        logic [23:0] exp_rgb;
        begin
            exp_rgb = expected_colour(
                iter_count[ITER_W-1:0],
                escaped,
                overflow
            );

            drive_pixel(iter_count, seq_num, z_r, z_i, escaped, overflow);

            @(posedge clk);
            #1;

            in_valid = 1'b0;

            check_output(1'b1, seq_num, exp_rgb, name);
        end
    endtask

    // Main test sequence

    logic [23:0] held_rgb;
    logic [SEQ_W-1:0] held_seq;

    initial begin
        n_tests = 0;
        n_fails = 0;

        rst       = 1'b1;
        out_ready = 1'b1;
        clear_inputs();

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        $display("================================================");
        $display(" colour_palette testbench starting");
        $display("================================================");

        // Test 1: reset / idle behaviour
        #1;
        check(out_valid === 1'b0, "T1 reset leaves out_valid low");
        check(palette_ready === 1'b1, "T1 empty output register means palette_ready high");

        // Test 2: escaped pixel uses palette colour
        send_and_check(
            16,        // iter_count
            5,         // seq
            123,       // z_r, unused for now
            -456,      // z_i, unused for now
            1'b1,      // escaped
            1'b0,      // overflow
            "T2 escaped pixel palette colour"
        );

        // Test 3: non-escaped pixel is black
        send_and_check(
            64,
            6,
            0,
            0,
            1'b0,
            1'b0,
            "T3 non-escaped pixel black"
        );

        // Test 4: overflow pixel is magenta debug colour
        send_and_check(
            7,
            7,
            100,
            200,
            1'b1,
            1'b1,
            "T4 overflow pixel magenta"
        );

        // Test 5: output valid clears when accepted and no new input arrives
        clear_inputs();
        out_ready = 1'b1;

        @(posedge clk);
        #1;

        check(out_valid === 1'b0,
              "T5 out_valid clears when no new input is presented");

        check(palette_ready === 1'b1,
              "T5 palette_ready remains high when empty");

        // Test 6: backpressure holds output stable

        // First send pixel A.
        out_ready = 1'b1;
        send_and_check(
            20,
            100,
            1,
            2,
            1'b1,
            1'b0,
            "T6a load pixel A"
        );

        held_rgb = {out_r, out_g, out_b};
        held_seq = out_seq_num;

        // Now stall downstream.
        out_ready = 1'b0;
        #1;

        check(palette_ready === 1'b0,
              "T6b palette_ready low when holding valid output and out_ready low");

        // Try to present pixel B while stalled.
        drive_pixel(
            30,
            101,
            3,
            4,
            1'b1,
            1'b0
        );

        @(posedge clk);
        #1;

        // Output should still be A.
        check(out_valid === 1'b1,
              "T6c out_valid remains high while stalled");

        check(out_seq_num === held_seq,
              "T6c held seq remains unchanged while stalled");

        check({out_r, out_g, out_b} === held_rgb,
              "T6c held RGB remains unchanged while stalled");

        check(palette_ready === 1'b0,
              "T6c palette_ready still low while stalled");

        // Release stall while keeping B valid.
        out_ready = 1'b1;

        @(posedge clk);
        #1;

        in_valid = 1'b0;

        check_output(
            1'b1,
            101,
            expected_colour(30[ITER_W-1:0], 1'b1, 1'b0),
            "T6d pixel B accepted after stall clears"
        );

        // Test 7: one-pixel-per-cycle streaming
        out_ready = 1'b1;

        for (int i = 0; i < 8; i++) begin
            drive_pixel(
                40 + i,
                200 + i,
                i,
                -i,
                1'b1,
                1'b0
            );

            @(posedge clk);
            #1;

            check_output(
                1'b1,
                200 + i,
                expected_colour((40 + i)[ITER_W-1:0], 1'b1, 1'b0),
                $sformatf("T7 stream pixel %0d", i)
            );
        end

        in_valid = 1'b0;

        @(posedge clk);
        #1;

        check(out_valid === 1'b0,
              "T7 output valid clears after stream ends");

        // Summary
        $display("================================================");
        $display(" colour_palette summary: tests=%0d fails=%0d",
                 n_tests, n_fails);
        $display("================================================");

        if (n_fails > 0) begin
            $error("%0d colour_palette test(s) failed", n_fails);
        end

        $finish;
    end

    // Watchdog
    initial begin
        #10_000;
        $error("colour_palette_tb timeout");
        $finish;
    end

endmodule