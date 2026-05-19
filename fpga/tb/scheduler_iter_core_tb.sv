// Ran in Vivado 2023.2, giving 11.1ms -> ~90FPS @ 1280 x 720 with 32 cores at a 0.0064% failure rate
// Can adjust NUM_CORES and X,Y_RES for faster/smaller or slower/larger tests

`timescale 1ns/1ps

module scheduler_iter_core_tb;

    localparam int NUM_CORES = 32;
    localparam int W         = 26;
    localparam int FRAC      = 22;
    localparam int ITER_W    = 16;
    localparam int MODE_W    = 3;

    localparam int X_RES     = 1280;
    localparam int Y_RES     = 720;
    localparam int N_PIXELS  = X_RES * Y_RES;
    
    localparam int SEQ_W     = (N_PIXELS <= 1) ? 1 : $clog2(N_PIXELS);
    
    localparam real X_MIN_REAL = -2.0;
    localparam real X_MAX_REAL =  1.0;
    localparam real Y_MIN_REAL = -1.125;
    localparam real Y_MAX_REAL =  1.125;
    
    localparam real X_JUMP_REAL = (X_RES <= 1) ? 0.0 : (X_MAX_REAL - X_MIN_REAL) / real'(X_RES - 1);
    localparam real Y_JUMP_REAL = (Y_RES <= 1) ? 0.0 : (Y_MAX_REAL - Y_MIN_REAL) / real'(Y_RES - 1);

localparam int MAX_ITER_VAL = 64;

    localparam logic [MODE_W-1:0] MODE_MANDEL = 3'd0;
    localparam logic [MODE_W-1:0] MODE_JULIA  = 3'd1;

    localparam time CLK_PERIOD = 10ns;

    logic clk = 1'b0;
    logic rst;

    always #(CLK_PERIOD/2) clk = ~clk;

    // Scheduler configuration
    logic signed [W-1:0] x_jump;
    logic signed [W-1:0] y_jump;
    logic signed [W-1:0] x_min;
    logic signed [W-1:0] y_min;

    logic signed [W-1:0] jul_c_r;
    logic signed [W-1:0] jul_c_i;
    logic [ITER_W-1:0]   in_max_iter;
    logic [MODE_W-1:0]   in_mode;

    logic last_pixel;

    // Scheduler -> cores
    logic [NUM_CORES-1:0]        core_in_ready;
    logic [NUM_CORES-1:0]        core_in_valid;

    logic signed [W-1:0]         core_c_r      [NUM_CORES];
    logic signed [W-1:0]         core_c_i      [NUM_CORES];
    logic signed [W-1:0]         core_z0_r     [NUM_CORES];
    logic signed [W-1:0]         core_z0_i     [NUM_CORES];
    logic [ITER_W-1:0]           core_max_iter [NUM_CORES];
    logic [MODE_W-1:0]           core_mode     [NUM_CORES];
    logic [SEQ_W-1:0]            core_seq      [NUM_CORES];

    // Cores -> testbench
    logic [NUM_CORES-1:0]        core_out_ready;
    logic [NUM_CORES-1:0]        core_out_valid;

    logic [SEQ_W-1:0]            core_out_seq      [NUM_CORES];
    logic [ITER_W-1:0]           core_out_iter     [NUM_CORES];
    logic signed [W-1:0]         core_out_z_r      [NUM_CORES];
    logic signed [W-1:0]         core_out_z_i      [NUM_CORES];
    logic [NUM_CORES-1:0]        core_out_escaped;
    logic [NUM_CORES-1:0]        core_out_overflow;

    assign core_out_ready = '1;

    // Fixed-point helpers

    function automatic logic signed [W-1:0] to_q422(input real x);
        return $rtoi(x * (1 << FRAC));
    endfunction

    function automatic real from_q422(input logic signed [W-1:0] q);
        return $itor(q) / (1 << FRAC);
    endfunction
    
    function automatic logic signed [W-1:0] coord_q(
        input logic signed [W-1:0] min_q,
        input logic signed [W-1:0] step_q,
        input int idx
    );
        logic signed [63:0] tmp;
        begin
            tmp = $signed(min_q) + ($signed(step_q) * idx);
            return tmp[W-1:0];
        end
    endfunction

    // Software reference: Mandelbrot only for first integration test

    function automatic int ref_mandelbrot(
        input real c_r,
        input real c_i,
        input real z0_r,
        input real z0_i,
        input int  max_iter
    );
        real zr;
        real zi;
        real zr_new;
        real zi_new;
        int n;

        zr = z0_r;
        zi = z0_i;

        for (n = 0; n < max_iter; n++) begin
            zr_new = zr*zr - zi*zi + c_r;
            zi_new = 2.0*zr*zi + c_i;

            zr = zr_new;
            zi = zi_new;

            if (zr*zr + zi*zi > 4.0) begin
                return n + 1;
            end
        end

        return max_iter;
    endfunction

    // DUT: pixel scheduler

pixel_scheduler #(
    .NUM_CORES (NUM_CORES),
    .W         (W),
    .SEQ_W     (SEQ_W),
    .ITER_W    (ITER_W),
    .MODE_W    (MODE_W),
    .X_RES     (X_RES),
    .Y_RES     (Y_RES)
) sched (
    .clk          (clk),
    .rst          (rst),

    .x_jump       (x_jump),
    .y_jump       (y_jump),
    .x_min        (x_min),
    .y_min        (y_min),
    .last_pixel   (last_pixel),

    .jul_c_r      (jul_c_r),
    .jul_c_i      (jul_c_i),
    .in_max_iter  (in_max_iter),
    .in_mode      (in_mode),

    .in_ready     (core_in_ready),
    .in_valid     (core_in_valid),

    .c_r          (core_c_r),
    .c_i          (core_c_i),
    .z0_r         (core_z0_r),
    .z0_i         (core_z0_i),

    .out_max_iter (core_max_iter),
    .out_mode     (core_mode),
    .out_seq      (core_seq)
);

    // DUT: multiple iter_core instances
    genvar gi;
    generate
        for (gi = 0; gi < NUM_CORES; gi++) begin : gen_cores

            iter_core #(
                .W      (W),
                .FRAC   (FRAC),
                .SEQ_W  (SEQ_W),
                .ITER_W (ITER_W),
                .MODE_W (MODE_W)
            ) core (
                .clk          (clk),
                .rst_n        (~rst),

                .in_ready     (core_in_ready[gi]),
                .in_valid     (core_in_valid[gi]),
                .in_c_r       (core_c_r[gi]),
                .in_c_i       (core_c_i[gi]),
                .in_z0_r      (core_z0_r[gi]),
                .in_z0_i      (core_z0_i[gi]),
                .in_max_iter  (core_max_iter[gi]),
                .in_mode      (core_mode[gi]),
                .in_seq       (core_seq[gi]),

                .out_ready    (core_out_ready[gi]),
                .out_valid    (core_out_valid[gi]),
                .out_seq      (core_out_seq[gi]),
                .out_iter     (core_out_iter[gi]),
                .out_z_r      (core_out_z_r[gi]),
                .out_z_i      (core_out_z_i[gi]),
                .out_escaped  (core_out_escaped[gi]),
                .out_overflow (core_out_overflow[gi])
            );

        end
    endgenerate

    // Scoreboard
    bit seen [0:N_PIXELS-1];

    int n_received;
    int n_passes;
    int n_fails;

    task automatic check_result(
        input int core_id,
        input int seq,
        input int hw_iter
    );
        int sx;
        int sy;
        int sw_iter;
        int diff;

        real c_r_real;
        real c_i_real;

        sx = seq % X_RES;
        sy = seq / X_RES;
        
        c_r_real = from_q422(coord_q(x_min, x_jump, sx));
        c_i_real = from_q422(coord_q(y_min, y_jump, sy));

        sw_iter = ref_mandelbrot(
            c_r_real,
            c_i_real,
            0.0,
            0.0,
            in_max_iter
        );

        diff = (hw_iter > sw_iter) ? (hw_iter - sw_iter) : (sw_iter - hw_iter);

        if (diff <= 2) begin
            n_passes++;
            $display("[PASS] core=%0d seq=%0d pixel=(%0d,%0d) c=(%.3f,%.3f) hw=%0d sw=%0d diff=%0d",
                     core_id, seq, sx, sy, c_r_real, c_i_real, hw_iter, sw_iter, diff);
        end
        else begin
            n_fails++;
            $display("[FAIL] core=%0d seq=%0d pixel=(%0d,%0d) c=(%.3f,%.3f) hw=%0d sw=%0d diff=%0d",
                     core_id, seq, sx, sy, c_r_real, c_i_real, hw_iter, sw_iter, diff);
        end
    endtask

    // Main test
    int timeout;
    int i;
    int seq_int;

    initial begin
        rst = 1'b1;

        x_min       = to_q422(X_MIN_REAL);
        y_min       = to_q422(Y_MIN_REAL);
        x_jump      = to_q422(X_JUMP_REAL);
        y_jump      = to_q422(Y_JUMP_REAL);

        jul_c_r     = to_q422(-0.4);
        jul_c_i     = to_q422(0.6);

        in_max_iter = MAX_ITER_VAL[ITER_W-1:0];
        in_mode     = MODE_MANDEL;

        n_received  = 0;
        n_passes    = 0;
        n_fails     = 0;

        for (i = 0; i < N_PIXELS; i++) begin
            seen[i] = 1'b0;
        end

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        $display("================================================");
        $display(" scheduler + iter_core integration test starting");
        $display(" NUM_CORES=%0d X_RES=%0d Y_RES=%0d N_PIXELS=%0d",
                 NUM_CORES, X_RES, Y_RES, N_PIXELS);
        $display("================================================");

        timeout = 0;

        while ((n_received < N_PIXELS) && (timeout < (N_PIXELS * (MAX_ITER_VAL * 8 + 100)))) begin
            @(negedge clk);
            timeout++;
        
            for (i = 0; i < NUM_CORES; i++) begin
                if (core_out_valid[i]) begin
                    seq_int = core_out_seq[i];
        
                    if (seq_int < N_PIXELS) begin
                        if (!seen[seq_int]) begin
                            seen[seq_int] = 1'b1;
                            n_received++;
                            check_result(i, seq_int, core_out_iter[i]);
                        end
                        else begin
                            n_fails++;
                            $display("[FAIL] duplicate seq=%0d from core=%0d", seq_int, i);
                        end
                    end
                    else begin
                        n_fails++;
                        $display("[FAIL] out-of-range seq=%0d from core=%0d", seq_int, i);
                    end
                end
            end
        end

        if (timeout >= (N_PIXELS * (MAX_ITER_VAL * 8 + 100))) begin
            n_fails++;
            $display("[FAIL] timeout: only received %0d/%0d pixels",
                     n_received, N_PIXELS);
        end

        for (i = 0; i < N_PIXELS; i++) begin
            if (!seen[i]) begin
                n_fails++;
                $display("[FAIL] missing output for seq=%0d", i);
            end
        end

        $display("================================================");
        $display(" Integration summary: received %0d/%0d, passes=%0d, fails=%0d",
                 n_received, N_PIXELS, n_passes, n_fails);
        $display("================================================");

        if (n_fails > 0) begin
            $error("%0d integration failure(s)", n_fails);
        end

        $finish;
    end

endmodule