`timescale 1ns/1ps
// Self-checking testbench for iter_core. Runs a software reference for each
// test pixel and asserts the hardware iter count matches within tolerance.

module iter_core_tb;

    // Module parameters (match iter_core defaults)
    localparam int W      = 26;
    localparam int FRAC   = 22;
    localparam int SEQ_W  = 16;
    localparam int ITER_W = 16;
    localparam int MODE_W = 3;

    localparam logic [MODE_W-1:0] MODE_MANDEL  = 3'd0;
    localparam logic [MODE_W-1:0] MODE_JULIA   = 3'd1;
    localparam logic [MODE_W-1:0] MODE_BURNING = 3'd2;
    localparam logic [MODE_W-1:0] MODE_TRICORN = 3'd3;

    localparam time CLK_PERIOD = 10ns;   // 100 MHz

    // DUT signals
    logic                 clk = 0;
    logic                 rst_n;

    logic                 in_ready;
    logic                 in_valid;
    logic signed [W-1:0]  in_c_r, in_c_i, in_z0_r, in_z0_i;
    logic [ITER_W-1:0]    in_max_iter;
    logic [MODE_W-1:0]    in_mode;
    logic [SEQ_W-1:0]     in_seq;

    logic                 out_ready;
    logic                 out_valid;
    logic [SEQ_W-1:0]     out_seq;
    logic [ITER_W-1:0]    out_iter;
    logic signed [W-1:0]  out_z_r, out_z_i;
    logic                 out_escaped;
    logic                 out_overflow;

    // Clock
    always #(CLK_PERIOD/2) clk = ~clk;

    // Instantiate DUT
    iter_core #(
        .W(W), .FRAC(FRAC), .SEQ_W(SEQ_W), .ITER_W(ITER_W), .MODE_W(MODE_W)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_ready    (in_ready),
        .in_valid    (in_valid),
        .in_c_r      (in_c_r),
        .in_c_i      (in_c_i),
        .in_z0_r     (in_z0_r),
        .in_z0_i     (in_z0_i),
        .in_max_iter (in_max_iter),
        .in_mode     (in_mode),
        .in_seq      (in_seq),
        .out_ready   (out_ready),
        .out_valid   (out_valid),
        .out_seq     (out_seq),
        .out_iter    (out_iter),
        .out_z_r     (out_z_r),
        .out_z_i     (out_z_i),
        .out_escaped (out_escaped),
        .out_overflow(out_overflow)
    );

    // convert between real and 26-bit signed fixed point
    function automatic logic signed [W-1:0] to_q422(input real x);
        return $rtoi(x * (1 << FRAC));
    endfunction

    function automatic real from_q422(input logic signed [W-1:0] q);
        return $itor(q) / (1 << FRAC);
    endfunction

    // IEEE double precision returns iteration count
    function automatic int ref_mandelbrot(
        input real c_r, c_i, z0_r, z0_i,
        input int max_iter
    );
        real zr, zi, zr_new, zi_new;
        int  n;
        zr = z0_r; zi = z0_i;
        for (n = 0; n < max_iter; n++) begin
            zr_new = zr*zr - zi*zi + c_r;
            zi_new = 2.0*zr*zi      + c_i;
            zr = zr_new;
            zi = zi_new;
            if (zr*zr + zi*zi > 4.0) return n + 1;
        end
        return max_iter;
    endfunction

    // pass/fail counts
    int n_tests   = 0;
    int n_passes  = 0;
    int n_fails   = 0;

    task report_result(
        input string  name,
        input int     hw_iter,
        input int     sw_iter,
        input int     tolerance
    );
        int diff;
        diff = (hw_iter > sw_iter) ? (hw_iter - sw_iter) : (sw_iter - hw_iter);
        n_tests++;
        if (diff <= tolerance) begin
            n_passes++;
            $display("[PASS] %-30s  hw=%4d sw=%4d  diff=%0d",
                     name, hw_iter, sw_iter, diff);
        end
        else begin
            n_fails++;
            $display("[FAIL] %-30s  hw=%4d sw=%4d  diff=%0d  (tol=%0d)",
                     name, hw_iter, sw_iter, diff, tolerance);
        end
    endtask

    // passes a single pixel through the DUT, blocks until the result
    task automatic run_pixel(
        input  real           c_r_real,
        input  real           c_i_real,
        input  real           z0_r_real,
        input  real           z0_i_real,
        input  int            max_iter_val,
        input  logic [MODE_W-1:0] mode_val,
        input  logic [SEQ_W-1:0]  seq_val,
        output int            iter_result,
        output logic          escaped_result,
        output logic          overflow_result
    );
        int timeout;
        // Wait until DUT can take a pixel
        wait (in_ready);
        @(posedge clk);
        in_valid    <= 1'b1;
        in_c_r      <= to_q422(c_r_real);
        in_c_i      <= to_q422(c_i_real);
        in_z0_r     <= to_q422(z0_r_real);
        in_z0_i     <= to_q422(z0_i_real);
        in_max_iter <= max_iter_val;
        in_mode     <= mode_val;
        in_seq      <= seq_val;

        // deassert on the next cycle 
        @(posedge clk);
        in_valid    <= 1'b0;

        // wait for the matching seq to come out, with timeout
        timeout = 0;
        while (!(out_valid && out_seq == seq_val) && timeout < 100000) begin
            @(posedge clk);
            timeout++;
        end
        if (timeout >= 100000) begin
            $error("Timeout waiting for seq=%0d to come out", seq_val);
            iter_result     = -1;
            escaped_result  = 1'b0;
            overflow_result = 1'b0;
        end
        else begin
            iter_result     = out_iter;
            escaped_result  = out_escaped;
            overflow_result = out_overflow;
        end
    endtask

    // main test seq

    int          hw_iter;
    logic        hw_escaped, hw_overflow;
    int          sw_iter;
    real         test_c_r, test_c_i;
    int          i;
    logic [15:0] seq_counter = 0;

    initial begin
        // init
        rst_n       = 0;
        in_valid    = 0;
        in_c_r      = 0; in_c_i  = 0;
        in_z0_r     = 0; in_z0_i = 0;
        in_max_iter = 0;
        in_mode     = MODE_MANDEL;
        in_seq      = 0;
        out_ready   = 1;     // always ready to take output

        // reset for several cycles
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("================================================");
        $display(" iter_core testbench starting");
        $display("================================================");

        // c = (0, 0)
        run_pixel(0.0, 0.0, 0.0, 0.0, 64, MODE_MANDEL, seq_counter++,
                  hw_iter, hw_escaped, hw_overflow);
        sw_iter = ref_mandelbrot(0.0, 0.0, 0.0, 0.0, 64);
        report_result("c=(0,0) origin", hw_iter, sw_iter, 0);
        if (hw_escaped !== 1'b0) $error("  expected escaped=0");

        // c = (-0.5, 0)
        run_pixel(-0.5, 0.0, 0.0, 0.0, 64, MODE_MANDEL, seq_counter++,
                  hw_iter, hw_escaped, hw_overflow);
        sw_iter = ref_mandelbrot(-0.5, 0.0, 0.0, 0.0, 64);
        report_result("c=(-0.5,0) cardioid", hw_iter, sw_iter, 0);
        if (hw_escaped !== 1'b0) $error("  expected escaped=0");

        // c = (1.0, 0)
        run_pixel(1.0, 0.0, 0.0, 0.0, 64, MODE_MANDEL, seq_counter++,
                  hw_iter, hw_escaped, hw_overflow);
        sw_iter = ref_mandelbrot(1.0, 0.0, 0.0, 0.0, 64);
        report_result("c=(1,0) outside", hw_iter, sw_iter, 0);
        if (hw_escaped !== 1'b1) $error("  expected escaped=1");

        // c = (2.0, 0), escapes iteration 1
        run_pixel(2.0, 0.0, 0.0, 0.0, 64, MODE_MANDEL, seq_counter++,
                  hw_iter, hw_escaped, hw_overflow);
        sw_iter = ref_mandelbrot(2.0, 0.0, 0.0, 0.0, 64);
        report_result("c=(2,0) immediate escape", hw_iter, sw_iter, 0);
        if (hw_escaped !== 1'b1) $error("  expected escaped=1");

        // c = (-2.0, 0)
        run_pixel(-2.0, 0.0, 0.0, 0.0, 64, MODE_MANDEL, seq_counter++,
                  hw_iter, hw_escaped, hw_overflow);
        sw_iter = ref_mandelbrot(-2.0, 0.0, 0.0, 0.0, 64);
        report_result("c=(-2,0) boundary", hw_iter, sw_iter, 0);

        // c = (0.25, 0.5)
        run_pixel(0.25, 0.5, 0.0, 0.0, 64, MODE_MANDEL, seq_counter++,
                  hw_iter, hw_escaped, hw_overflow);
        sw_iter = ref_mandelbrot(0.25, 0.5, 0.0, 0.0, 64);
        report_result("c=(0.25,0.5)", hw_iter, sw_iter, 1);

        // c = (-0.75, 0.1)
        run_pixel(-0.75, 0.1, 0.0, 0.0, 256, MODE_MANDEL, seq_counter++,
                  hw_iter, hw_escaped, hw_overflow);
        sw_iter = ref_mandelbrot(-0.75, 0.1, 0.0, 0.0, 256);
        report_result("c=(-0.75,0.1) near boundary", hw_iter, sw_iter, 2);

        // julia mode, c constant = (-0.4, 0.6)
        run_pixel(-0.4, 0.6, 0.3, 0.0, 64, MODE_JULIA, seq_counter++,
                  hw_iter, hw_escaped, hw_overflow);
        sw_iter = ref_mandelbrot(-0.4, 0.6, 0.3, 0.0, 64);
        report_result("julia c=(-0.4,0.6) z0=(0.3,0)", hw_iter, sw_iter, 1);

        // 200 random pixels
        $display("--- Random sweep across complex plane ---");
        for (i = 0; i < 200; i++) begin
            // uniform
            test_c_r = (($urandom_range(0, 30000) / 10000.0)) - 2.0;  // -2.0 .. +1.0
            test_c_i = (($urandom_range(0, 30000) / 10000.0)) - 1.5;  // -1.5 .. +1.5
            run_pixel(test_c_r, test_c_i, 0.0, 0.0, 256, MODE_MANDEL,
                      seq_counter++, hw_iter, hw_escaped, hw_overflow);
            sw_iter = ref_mandelbrot(test_c_r, test_c_i, 0.0, 0.0, 256);
            // tolerance: 2 iterations, allowing for rounding v truncation diffs
            begin
                string nm;
                nm = $sformatf("rand[%0d] c=(%.3f,%.3f)", i, test_c_r, test_c_i);
                report_result(nm, hw_iter, sw_iter, 2);
            end
        end

        $display("================================================");
        $display(" Test summary: %0d/%0d passed, %0d failed",
                 n_passes, n_tests, n_fails);
        $display("================================================");
        if (n_fails > 0) $error("%0d test(s) failed", n_fails);
        $finish;
    end


    initial begin
        #5_000_000;   // 5 ms simulation time
        $error("testbench hung");
        $finish;
    end

endmodule
