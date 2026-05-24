`timescale 1ns/1ps

// Comprehensive self-checking testbench for iter_core.
// Covers:
// Mandelbrot, Julia, Burning Ship, Tricorn modes
// targeted known points
// random sweeps across all modes
// burst/mixed-difficulty injection with multiple in-flight pixels
// output backpressure/stall behaviour
// explicit overflow cases
// reset during active operation
//
// Notes:
//   - Boundary/random tests allow a small tolerance because the DUT uses Q4.22 fixed-point arithmetic with rounding/truncation at every iteration.

module iter_core_tb;

    // Params matching iter_core
    localparam int W      = 26;
    localparam int FRAC   = 22;
    localparam int SEQ_W  = 16;
    localparam int ITER_W = 16;
    localparam int MODE_W = 3;

    localparam logic [MODE_W-1:0] MODE_MANDEL  = 3'd0;
    localparam logic [MODE_W-1:0] MODE_JULIA   = 3'd1;
    localparam logic [MODE_W-1:0] MODE_BURNING = 3'd2;
    localparam logic [MODE_W-1:0] MODE_TRICORN = 3'd3;

    localparam time CLK_PERIOD = 10ns;

    localparam int MAX_SEQ          = (1 << SEQ_W);
    localparam int INPUT_TIMEOUT    = 20000;
    localparam int DRAIN_TIMEOUT    = 300000;
    localparam int GLOBAL_TIMEOUT_NS = 50_000_000;

    // Overflow checking policy
    localparam int OVF_DONT_CARE = 0;
    localparam int OVF_EXPECT_0  = 1;
    localparam int OVF_EXPECT_1  = 2;

    // Backpressure modes
    localparam int BP_ALWAYS_READY = 0;
    localparam int BP_RANDOM_75    = 1;
    localparam int BP_RANDOM_50    = 2;
    localparam int BP_RANDOM_25    = 3;
    localparam int BP_BURSTY       = 4;
    localparam int BP_MANUAL       = 5;

    // DUT signals
    logic clk = 1'b0;
    logic rst_n;

    logic                 in_ready;
    logic                 in_valid;
    logic signed [W-1:0]  in_c_r;
    logic signed [W-1:0]  in_c_i;
    logic signed [W-1:0]  in_z0_r;
    logic signed [W-1:0]  in_z0_i;
    logic [ITER_W-1:0]    in_max_iter;
    logic [MODE_W-1:0]    in_mode;
    logic [SEQ_W-1:0]     in_seq;

    logic                 out_ready;
    logic                 out_valid;
    logic [SEQ_W-1:0]     out_seq;
    logic [ITER_W-1:0]    out_iter;
    logic signed [W-1:0]  out_z_r;
    logic signed [W-1:0]  out_z_i;
    logic                 out_escaped;
    logic                 out_overflow;

    always #(CLK_PERIOD/2) clk = ~clk;

    iter_core #(
        .W      (W),
        .FRAC   (FRAC),
        .SEQ_W  (SEQ_W),
        .ITER_W (ITER_W),
        .MODE_W (MODE_W)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),

        .in_ready     (in_ready),
        .in_valid     (in_valid),
        .in_c_r       (in_c_r),
        .in_c_i       (in_c_i),
        .in_z0_r      (in_z0_r),
        .in_z0_i      (in_z0_i),
        .in_max_iter  (in_max_iter),
        .in_mode      (in_mode),
        .in_seq       (in_seq),

        .out_ready    (out_ready),
        .out_valid    (out_valid),
        .out_seq      (out_seq),
        .out_iter     (out_iter),
        .out_z_r      (out_z_r),
        .out_z_i      (out_z_i),
        .out_escaped  (out_escaped),
        .out_overflow (out_overflow)
    );

    // Fixed-point helpers
    function automatic logic signed [W-1:0] to_q422(input real x);
        return $rtoi(x * (1 << FRAC));
    endfunction

    function automatic real from_q422(input logic signed [W-1:0] q);
        return $itor(q) / (1 << FRAC);
    endfunction

    function automatic real abs_real(input real x);
        if (x < 0.0) return -x;
        else         return  x;
    endfunction

    function automatic string mode_name(input logic [MODE_W-1:0] mode);
        case (mode)
            MODE_MANDEL:  return "MANDEL";
            MODE_JULIA:   return "JULIA";
            MODE_BURNING: return "BURNING";
            MODE_TRICORN: return "TRICORN";
            default:      return "UNKNOWN";
        endcase
    endfunction

    // Software reference matching the core semantics
    task automatic ref_model(
        input  real c_r,
        input  real c_i,
        input  real z0_r,
        input  real z0_i,
        input  int  max_iter,
        input  logic [MODE_W-1:0] mode,
        output int  ref_iter,
        output logic ref_escaped,
        output real ref_z_r,
        output real ref_z_i
    );
        real zr;
        real zi;
        real zm_r;
        real zm_i;
        real zr_new;
        real zi_new;
        int n;
        begin
            zr = z0_r;
            zi = z0_i;

            for (n = 0; n < max_iter; n++) begin
                // Core checks current z_n for escape before committing z_{n+1}.
                if ((zr*zr + zi*zi) > 4.0) begin
                    ref_iter    = n;
                    ref_escaped = 1'b1;
                    ref_z_r     = zr;
                    ref_z_i     = zi;
                    return;
                end

                case (mode)
                    MODE_BURNING: begin
                        zm_r = abs_real(zr);
                        zm_i = abs_real(zi);
                    end
                    MODE_TRICORN: begin
                        zm_r =  zr;
                        zm_i = -zi;
                    end
                    default: begin
                        zm_r = zr;
                        zm_i = zi;
                    end
                endcase

                zr_new = zm_r*zm_r - zm_i*zm_i + c_r;
                zi_new = 2.0*zm_r*zm_i + c_i;

                zr = zr_new;
                zi = zi_new;
            end

            ref_iter    = max_iter;
            ref_escaped = 1'b0;
            ref_z_r     = zr;
            ref_z_i     = zi;
        end
    endtask

    // Expected result database, indexed by sequence number
    bit                  exp_valid       [0:MAX_SEQ-1];
    int                  exp_iter        [0:MAX_SEQ-1];
    int                  exp_tolerance   [0:MAX_SEQ-1];
    logic                exp_escaped     [0:MAX_SEQ-1];
    int                  exp_ovf_policy  [0:MAX_SEQ-1];
    logic                exp_overflow    [0:MAX_SEQ-1];
    real                 exp_z_r         [0:MAX_SEQ-1];
    real                 exp_z_i         [0:MAX_SEQ-1];
    real                 exp_z_tol       [0:MAX_SEQ-1];
    bit                  exp_check_z     [0:MAX_SEQ-1];
    string               exp_name        [0:MAX_SEQ-1];

    int next_seq;
    int outstanding;
    int n_expected;
    int n_checked;
    int n_passes;
    int n_fails;
    int n_unexpected;

    // Output ready/backpressure driver
    int   bp_mode;
    logic manual_out_ready;
    int   bp_counter;

    // Drive out_ready just after each positive clock edge so it is stable
    // for the *next* DUT sampling edge. This avoids TB/DUT races when the
    // scoreboard also samples out_valid && out_ready at posedge.
    always @(posedge clk) begin
        if (!rst_n) begin
            out_ready  <= 1'b1;
            bp_counter <= 0;
        end
        else begin
            #1;
            bp_counter <= bp_counter + 1;

            case (bp_mode)
                BP_ALWAYS_READY: out_ready <= 1'b1;
                BP_RANDOM_75:    out_ready <= ($urandom_range(0, 3) != 0);
                BP_RANDOM_50:    out_ready <= ($urandom_range(0, 1) != 0);
                BP_RANDOM_25:    out_ready <= ($urandom_range(0, 3) == 0);
                BP_BURSTY:       out_ready <= ((bp_counter % 13) < 9);
                BP_MANUAL:       out_ready <= manual_out_ready;
                default:         out_ready <= 1'b1;
            endcase
        end
    end

    // Scoreboard
    task automatic fail_msg(input string msg);
        begin
            n_fails++;
            $display("[FAIL] %s", msg);
        end
    endtask

    task automatic pass_msg(input string msg);
        begin
            n_passes++;
            $display("[PASS] %s", msg);
        end
    endtask

    function automatic int abs_int(input int a);
        if (a < 0) return -a;
        else       return  a;
    endfunction

    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            int seq_i;
            int diff;
            real hw_zr_real;
            real hw_zi_real;
            real zr_diff;
            real zi_diff;

            seq_i = out_seq;

            if (!exp_valid[seq_i]) begin
                n_unexpected++;
                fail_msg($sformatf("unexpected output seq=%0d iter=%0d escaped=%0b overflow=%0b",
                                   seq_i, out_iter, out_escaped, out_overflow));
            end
            else begin
                n_checked++;

                diff = abs_int(int'(out_iter) - exp_iter[seq_i]);
                if (diff > exp_tolerance[seq_i]) begin
                    fail_msg($sformatf("%s seq=%0d iter mismatch: hw=%0d ref=%0d diff=%0d tol=%0d",
                                       exp_name[seq_i], seq_i, out_iter, exp_iter[seq_i],
                                       diff, exp_tolerance[seq_i]));
                end

                // For exact tests, also check escaped flag exactly.
                // For tolerance-based boundary/random tests, tiny fixed-point differences
                // can move the escape decision by a few iterations, so do not over-check
                // the boolean unless this is a zero-tolerance case.
                if ((exp_tolerance[seq_i] == 0) && (out_escaped !== exp_escaped[seq_i])) begin
                    fail_msg($sformatf("%s seq=%0d escaped mismatch: hw=%0b ref=%0b",
                                       exp_name[seq_i], seq_i, out_escaped, exp_escaped[seq_i]));
                end

                if (exp_ovf_policy[seq_i] == OVF_EXPECT_1) begin
                    if (out_escaped !== 1'b1) begin
                        fail_msg($sformatf("%s seq=%0d expected escaped=1 because overflow was expected",
                                           exp_name[seq_i], seq_i));
                    end
                end

                if (exp_ovf_policy[seq_i] == OVF_EXPECT_0) begin
                    if (out_overflow !== 1'b0) begin
                        fail_msg($sformatf("%s seq=%0d expected overflow=0, got 1",
                                           exp_name[seq_i], seq_i));
                    end
                end
                else if (exp_ovf_policy[seq_i] == OVF_EXPECT_1) begin
                    if (out_overflow !== 1'b1) begin
                        fail_msg($sformatf("%s seq=%0d expected overflow=1, got 0",
                                           exp_name[seq_i], seq_i));
                    end
                end

                if (exp_check_z[seq_i]) begin
                    hw_zr_real = from_q422(out_z_r);
                    hw_zi_real = from_q422(out_z_i);
                    zr_diff = abs_real(hw_zr_real - exp_z_r[seq_i]);
                    zi_diff = abs_real(hw_zi_real - exp_z_i[seq_i]);

                    if ((zr_diff > exp_z_tol[seq_i]) || (zi_diff > exp_z_tol[seq_i])) begin
                        fail_msg($sformatf("%s seq=%0d z mismatch: hw=(%.6f,%.6f) ref=(%.6f,%.6f) tol=%.6f",
                                           exp_name[seq_i], seq_i,
                                           hw_zr_real, hw_zi_real,
                                           exp_z_r[seq_i], exp_z_i[seq_i],
                                           exp_z_tol[seq_i]));
                    end
                end

                // One expected output is fully consumed.
                exp_valid[seq_i] = 1'b0;
                outstanding--;
            end
        end
    end

    task automatic clear_expected_db();
        begin
            for (int i = 0; i < MAX_SEQ; i++) begin
                exp_valid[i]      = 1'b0;
                exp_iter[i]       = 0;
                exp_tolerance[i]  = 0;
                exp_escaped[i]    = 1'b0;
                exp_ovf_policy[i] = OVF_DONT_CARE;
                exp_overflow[i]   = 1'b0;
                exp_z_r[i]        = 0.0;
                exp_z_i[i]        = 0.0;
                exp_z_tol[i]      = 0.0;
                exp_check_z[i]    = 1'b0;
                exp_name[i]       = "";
            end

            outstanding = 0;
        end
    endtask

    // Reset helper
    task automatic apply_reset();
        begin
            @(negedge clk);

            // If reset is intentionally applied while transactions are in flight,
            // those expected outputs are deliberately flushed from the DUT.
            // They should not count against the final checked-vs-expected total.
            if (outstanding != 0) begin
                $display("[INFO] reset flushed %0d outstanding expected output(s)", outstanding);
                n_expected = n_expected - outstanding;
            end

            rst_n       <= 1'b0;
            in_valid    <= 1'b0;
            in_c_r      <= '0;
            in_c_i      <= '0;
            in_z0_r     <= '0;
            in_z0_i     <= '0;
            in_max_iter <= '0;
            in_mode     <= MODE_MANDEL;
            in_seq      <= '0;
            bp_mode     <= BP_ALWAYS_READY;
            manual_out_ready <= 1'b1;
            clear_expected_db();

            repeat (5) @(negedge clk);
            rst_n <= 1'b1;
            repeat (3) @(negedge clk);
        end
    endtask

    // Pixel driver
    task automatic send_case(
        input string name,
        input real c_r_real,
        input real c_i_real,
        input real z0_r_real,
        input real z0_i_real,
        input int max_iter_val,
        input logic [MODE_W-1:0] mode_val,
        input int tolerance,
        input int ovf_policy,
        input bit check_z,
        input real z_tolerance
    );
        int seq_i;
        int wait_cycles;
        int ref_iter;
        logic ref_escaped;
        real ref_zr;
        real ref_zi;
        bit accepted;
        begin
            if (next_seq >= MAX_SEQ) begin
                $fatal(1, "Sequence number exhausted. Increase SEQ_W or reduce test count.");
            end

            seq_i = next_seq;
            next_seq++;

            ref_model(
                c_r_real, c_i_real, z0_r_real, z0_i_real,
                max_iter_val, mode_val,
                ref_iter, ref_escaped, ref_zr, ref_zi
            );

            if (exp_valid[seq_i]) begin
                $fatal(1, "Expected DB collision at seq=%0d", seq_i);
            end

            exp_valid[seq_i]      = 1'b1;
            exp_iter[seq_i]       = ref_iter;
            exp_tolerance[seq_i]  = tolerance;
            exp_escaped[seq_i]    = ref_escaped;
            exp_ovf_policy[seq_i] = ovf_policy;
            exp_overflow[seq_i]   = (ovf_policy == OVF_EXPECT_1);
            exp_z_r[seq_i]        = ref_zr;
            exp_z_i[seq_i]        = ref_zi;
            exp_z_tol[seq_i]      = z_tolerance;
            exp_check_z[seq_i]    = check_z;
            exp_name[seq_i]       = {name, " [", mode_name(mode_val), "]"};

            outstanding++;
            n_expected++;

            // Drive inputs before a positive edge and hold until ready is sampled high.
            @(negedge clk);
            in_valid    <= 1'b1;
            in_c_r      <= to_q422(c_r_real);
            in_c_i      <= to_q422(c_i_real);
            in_z0_r     <= to_q422(z0_r_real);
            in_z0_i     <= to_q422(z0_i_real);
            in_max_iter <= max_iter_val;
            in_mode     <= mode_val;
            in_seq      <= SEQ_W'(seq_i);

            wait_cycles = 0;
            accepted    = 1'b0;

            while (!accepted && wait_cycles < INPUT_TIMEOUT) begin
                if (in_ready) begin
                    @(posedge clk); // transaction occurs at this edge
                    accepted = 1'b1;
                end
                else begin
                    @(posedge clk); // no transaction this cycle
                    wait_cycles++;
                    @(negedge clk);
                end
            end

            if (!accepted) begin
                fail_msg($sformatf("input handshake timeout for %s seq=%0d", name, seq_i));
                exp_valid[seq_i] = 1'b0;
                outstanding--;
            end

            @(negedge clk);
            in_valid <= 1'b0;
        end
    endtask

    task automatic drain_outputs(input string phase_name);
        int cycles;
        begin
            cycles = 0;
            while ((outstanding > 0) && (cycles < DRAIN_TIMEOUT)) begin
                @(negedge clk);
                cycles++;
            end

            if (outstanding != 0) begin
                fail_msg($sformatf("drain timeout after phase '%s': outstanding=%0d",
                                   phase_name, outstanding));
            end
            else begin
                $display("[INFO] drained phase '%s' in %0d cycles", phase_name, cycles);
            end
        end
    endtask

    // Test groups
    task automatic test_mandel_known();
        begin
            $display("--- Known Mandelbrot points ---");
            bp_mode = BP_ALWAYS_READY;

            send_case("origin c=(0,0)",              0.0,   0.0, 0.0, 0.0,  64, MODE_MANDEL, 0, OVF_EXPECT_0, 1, 0.0005);
            send_case("cardioid c=(-0.5,0)",       -0.5,   0.0, 0.0, 0.0,  64, MODE_MANDEL, 0, OVF_EXPECT_0, 1, 0.0005);
            // c=(1,0) eventually reaches z=5. The DUT escapes by detecting
            // square overflow in Q4.22, so out_overflow is expected.
            send_case("outside c=(1,0)",            1.0,   0.0, 0.0, 0.0,  64, MODE_MANDEL, 0, OVF_EXPECT_1, 0, 0.0);
            send_case("c=(2,0) escape boundary",    2.0,   0.0, 0.0, 0.0,  64, MODE_MANDEL, 0, OVF_DONT_CARE, 0, 0.0);
            send_case("c=(-2,0) boundary",         -2.0,   0.0, 0.0, 0.0,  64, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);
            send_case("c=(0.25,0.5)",              0.25,  0.5, 0.0, 0.0,  64, MODE_MANDEL, 1, OVF_DONT_CARE, 0, 0.0);
            send_case("near boundary -0.75+0.1i", -0.75,  0.1, 0.0, 0.0, 256, MODE_MANDEL, 3, OVF_DONT_CARE, 0, 0.0);

            drain_outputs("known Mandelbrot");
        end
    endtask

    task automatic test_julia_known();
        begin
            $display("--- Known Julia points ---");
            bp_mode = BP_ALWAYS_READY;

            send_case("julia c=(-0.4,0.6) z=(0.3,0)",  -0.4, 0.6,  0.3,  0.0,  64, MODE_JULIA, 2, OVF_DONT_CARE, 0, 0.0);
            send_case("julia c=(-0.8,0.156) z=(0,0)", -0.8, 0.156,0.0,  0.0, 128, MODE_JULIA, 3, OVF_DONT_CARE, 0, 0.0);
            send_case("julia immediate z0=(3,0)",       0.0, 0.0,  3.0,  0.0,  64, MODE_JULIA, 0, OVF_EXPECT_1, 0, 0.0);
            send_case("julia c=(0,0) z=(0.5,0)",        0.0, 0.0,  0.5,  0.0,  64, MODE_JULIA, 0, OVF_EXPECT_0, 1, 0.0005);

            drain_outputs("known Julia");
        end
    endtask

    task automatic test_burning_known();
        begin
            $display("--- Known Burning Ship points ---");
            bp_mode = BP_ALWAYS_READY;

            send_case("burning origin",               0.0,   0.0, 0.0, 0.0,  64, MODE_BURNING, 0, OVF_EXPECT_0, 1, 0.0005);
            send_case("burning c=(-0.5,-0.5)",       -0.5,  -0.5, 0.0, 0.0, 128, MODE_BURNING, 3, OVF_DONT_CARE, 0, 0.0);
            send_case("burning c=(-1.8,-0.05)",      -1.8, -0.05, 0.0, 0.0, 128, MODE_BURNING, 3, OVF_DONT_CARE, 0, 0.0);
            send_case("burning c=(0.5,0.5)",          0.5,   0.5, 0.0, 0.0,  64, MODE_BURNING, 2, OVF_DONT_CARE, 0, 0.0);
            send_case("burning negative z0 branch",  -0.4,  -0.6,-0.3,-0.2,  64, MODE_BURNING, 2, OVF_DONT_CARE, 0, 0.0);

            drain_outputs("known Burning Ship");
        end
    endtask

    task automatic test_tricorn_known();
        begin
            $display("--- Known Tricorn points ---");
            bp_mode = BP_ALWAYS_READY;

            send_case("tricorn origin",              0.0,  0.0, 0.0, 0.0,  64, MODE_TRICORN, 0, OVF_EXPECT_0, 1, 0.0005);
            send_case("tricorn c=(-0.5,0)",        -0.5,  0.0, 0.0, 0.0,  64, MODE_TRICORN, 1, OVF_DONT_CARE, 0, 0.0);
            send_case("tricorn c=(0.3,0.5)",        0.3,  0.5, 0.0, 0.0, 128, MODE_TRICORN, 3, OVF_DONT_CARE, 0, 0.0);
            send_case("tricorn z0 imag branch",    -0.2,  0.4, 0.1,-0.5,  64, MODE_TRICORN, 2, OVF_DONT_CARE, 0, 0.0);

            drain_outputs("known Tricorn");
        end
    endtask

    task automatic test_max_iter_edges();
        begin
            $display("--- max_iter edge cases ---");
            bp_mode = BP_ALWAYS_READY;

            send_case("max_iter=1 inside",  0.0, 0.0, 0.0, 0.0, 1, MODE_MANDEL, 0, OVF_EXPECT_0, 1, 0.0005);
            send_case("max_iter=2 inside", -0.5, 0.0, 0.0, 0.0, 2, MODE_MANDEL, 0, OVF_EXPECT_0, 1, 0.0005);
            send_case("max_iter=3 outside", 1.0, 0.0, 0.0, 0.0, 3, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);
            send_case("max_iter=256 inside",0.0, 0.0, 0.0, 0.0,256, MODE_MANDEL, 0, OVF_EXPECT_0, 1, 0.0005);

            drain_outputs("max_iter edges");
        end
    endtask

    task automatic test_overflow_cases();
        begin
            $display("--- Explicit overflow cases ---");
            bp_mode = BP_ALWAYS_READY;

            // z0=(3,0) is already outside the escape radius. Squaring it in the
            // hardware exceeds Q4.22 square range, so overflow should assert.
            send_case("overflow Julia z0=(3,0)", 0.0, 0.0, 3.0, 0.0, 64, MODE_JULIA, 0, OVF_EXPECT_1, 0, 0.0);

            // c=(5,0) creates z1=(5,0), so the next magnitude-square operation
            // should overflow and force escape.
            send_case("overflow Mandel c=(5,0)", 5.0, 0.0, 0.0, 0.0, 64, MODE_MANDEL, 1, OVF_EXPECT_1, 0, 0.0);
            send_case("overflow Julia c=(5,0)",  5.0, 0.0, 0.0, 0.0, 64, MODE_JULIA,  1, OVF_EXPECT_1, 0, 0.0);
            send_case("overflow Burning c=(5,0)",5.0, 0.0, 0.0, 0.0, 64, MODE_BURNING,1, OVF_EXPECT_1, 0, 0.0);
            send_case("overflow Tricorn c=(5,0)",5.0, 0.0, 0.0, 0.0, 64, MODE_TRICORN,1, OVF_EXPECT_1, 0, 0.0);

            drain_outputs("overflow cases");
        end
    endtask

    task automatic test_random_sweeps();
        real cr;
        real ci;
        real zr;
        real zi;
        begin
            $display("--- Random sweeps across all modes ---");
            bp_mode = BP_ALWAYS_READY;

            for (int i = 0; i < 50; i++) begin
                cr = ($urandom_range(0, 30000) / 10000.0) - 2.0;  // -2.0 .. +1.0
                ci = ($urandom_range(0, 30000) / 10000.0) - 1.5;  // -1.5 .. +1.5
                send_case($sformatf("random Mandel %0d", i), cr, ci, 0.0, 0.0, 256, MODE_MANDEL, 3, OVF_DONT_CARE, 0, 0.0);
            end

            for (int i = 0; i < 50; i++) begin
                cr = -0.8 + ($urandom_range(0, 16000) / 10000.0); // -0.8 .. +0.8
                ci = -0.8 + ($urandom_range(0, 16000) / 10000.0); // -0.8 .. +0.8
                zr = -1.5 + ($urandom_range(0, 30000) / 10000.0); // -1.5 .. +1.5
                zi = -1.5 + ($urandom_range(0, 30000) / 10000.0);
                send_case($sformatf("random Julia %0d", i), cr, ci, zr, zi, 128, MODE_JULIA, 4, OVF_DONT_CARE, 0, 0.0);
            end

            for (int i = 0; i < 50; i++) begin
                cr = ($urandom_range(0, 30000) / 10000.0) - 2.0;
                ci = ($urandom_range(0, 25000) / 10000.0) - 1.5;
                send_case($sformatf("random Burning %0d", i), cr, ci, 0.0, 0.0, 128, MODE_BURNING, 4, OVF_DONT_CARE, 0, 0.0);
            end

            for (int i = 0; i < 50; i++) begin
                cr = ($urandom_range(0, 30000) / 10000.0) - 2.0;
                ci = ($urandom_range(0, 30000) / 10000.0) - 1.5;
                send_case($sformatf("random Tricorn %0d", i), cr, ci, 0.0, 0.0, 128, MODE_TRICORN, 4, OVF_DONT_CARE, 0, 0.0);
            end

            drain_outputs("random sweeps");
        end
    endtask

    task automatic test_burst_mixed();
        begin
            $display("--- Burst/mixed difficulty test ---");
            bp_mode = BP_ALWAYS_READY;

            for (int i = 0; i < 80; i++) begin
                case (i % 8)
                    0: send_case($sformatf("burst inside %0d", i),      0.0, 0.0, 0.0, 0.0, 128, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);
                    1: send_case($sformatf("burst quick %0d", i),       1.1, 0.0, 0.0, 0.0, 128, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);
                    2: send_case($sformatf("burst boundary %0d", i),  -0.75,0.1, 0.0, 0.0, 256, MODE_MANDEL, 4, OVF_DONT_CARE, 0, 0.0);
                    3: send_case($sformatf("burst Julia %0d", i),      -0.4,0.6, 0.3, 0.0, 128, MODE_JULIA, 3, OVF_DONT_CARE, 0, 0.0);
                    4: send_case($sformatf("burst Burning %0d", i),    -0.5,-0.5,0.0,0.0,128, MODE_BURNING, 4, OVF_DONT_CARE, 0, 0.0);
                    5: send_case($sformatf("burst Tricorn %0d", i),     0.3,0.5, 0.0,0.0,128, MODE_TRICORN, 4, OVF_DONT_CARE, 0, 0.0);
                    6: send_case($sformatf("burst overflow %0d", i),    5.0,0.0, 0.0,0.0, 64, MODE_MANDEL, 1, OVF_EXPECT_1, 0, 0.0);
                    7: send_case($sformatf("burst maxiter %0d", i),    -0.5,0.0, 0.0,0.0,256, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);
                endcase
            end

            drain_outputs("burst mixed");
        end
    endtask

    task automatic test_backpressure();
        logic [SEQ_W-1:0] held_seq;
        logic [ITER_W-1:0] held_iter;
        begin
            $display("--- Backpressure/stall tests ---");

            // Manual stall: feed a quick pixel, wait until it is valid, hold out_ready low,
            // and verify the output stays stable.
            bp_mode = BP_MANUAL;
            manual_out_ready = 1'b1;

            send_case("manual stall quick escape", 1.1, 0.0, 0.0, 0.0, 64, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);

            // Hold output unready before the result arrives.
            @(negedge clk);
            manual_out_ready = 1'b0;

            // Wait until the completed result is being held at the output.
            begin
                int stall_wait;
                bit saw_valid;
                stall_wait = 0;
                saw_valid = 1'b0;

                while (!saw_valid && (stall_wait < 1000)) begin
                    @(negedge clk);
                    stall_wait++;
                    if (out_valid) begin
                        held_seq  = out_seq;
                        held_iter = out_iter;
                        saw_valid = 1'b1;
                    end
                end
            end

            if (!out_valid) begin
                fail_msg("manual backpressure: out_valid never asserted while stalled");
            end
            else begin
                repeat (10) begin
                    @(negedge clk);
                    if ((out_seq !== held_seq) || (out_iter !== held_iter)) begin
                        fail_msg("manual backpressure: output changed while out_ready=0");
                    end
                end
            end

            manual_out_ready = 1'b1;
            drain_outputs("manual backpressure");

            // Random backpressure with many in-flight pixels.
            bp_mode = BP_RANDOM_50;
            for (int i = 0; i < 100; i++) begin
                case (i % 4)
                    0: send_case($sformatf("bp Mandel %0d", i),  0.0, 0.0, 0.0, 0.0, 128, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);
                    1: send_case($sformatf("bp quick %0d", i),   1.1, 0.0, 0.0, 0.0, 128, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);
                    2: send_case($sformatf("bp Julia %0d", i),  -0.4, 0.6, 0.3,0.0,128, MODE_JULIA,  3, OVF_DONT_CARE, 0, 0.0);
                    3: send_case($sformatf("bp Tricorn %0d", i), 0.3, 0.5, 0.0,0.0,128, MODE_TRICORN,4, OVF_DONT_CARE, 0, 0.0);
                endcase
            end
            drain_outputs("random backpressure");

            bp_mode = BP_ALWAYS_READY;
        end
    endtask

    task automatic test_reset_during_activity();
        begin
            $display("--- Reset during active operation ---");
            bp_mode = BP_ALWAYS_READY;

            // Send several long-running pixels, then reset before draining.
            for (int i = 0; i < 6; i++) begin
                send_case($sformatf("pre-reset long %0d", i), 0.0, 0.0, 0.0, 0.0, 256, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);
            end

            apply_reset();

            // After reset, a fresh transaction should work and no old seq should leak out.
            send_case("post-reset sanity", 1.1, 0.0, 0.0, 0.0, 64, MODE_MANDEL, 0, OVF_EXPECT_0, 0, 0.0);
            drain_outputs("post-reset sanity");
        end
    endtask

    // Main sequence
    initial begin
        rst_n            = 1'b0;
        in_valid         = 1'b0;
        in_c_r           = '0;
        in_c_i           = '0;
        in_z0_r          = '0;
        in_z0_i          = '0;
        in_max_iter      = '0;
        in_mode          = MODE_MANDEL;
        in_seq           = '0;
        out_ready        = 1'b1;
        bp_mode          = BP_ALWAYS_READY;
        manual_out_ready = 1'b1;
        bp_counter       = 0;

        next_seq      = 0;
        outstanding   = 0;
        n_expected    = 0;
        n_checked     = 0;
        n_passes      = 0;
        n_fails       = 0;
        n_unexpected  = 0;

        clear_expected_db();
        apply_reset();

        $display("================================================");
        $display(" iter_core comprehensive testbench starting");
        $display(" W=%0d FRAC=%0d SEQ_W=%0d ITER_W=%0d", W, FRAC, SEQ_W, ITER_W);
        $display("================================================");

        test_mandel_known();
        test_julia_known();
        test_burning_known();
        test_tricorn_known();
        test_max_iter_edges();
        test_overflow_cases();
        test_random_sweeps();
        test_burst_mixed();
        test_backpressure();
        test_reset_during_activity();

        drain_outputs("final drain");

        $display("================================================");
        $display(" Comprehensive iter_core summary:");
        $display("   expected   = %0d", n_expected);
        $display("   checked    = %0d", n_checked);
        $display("   unexpected = %0d", n_unexpected);
        $display("   fails      = %0d", n_fails);
        $display("================================================");

        if ((n_fails != 0) || (n_checked != n_expected) || (n_unexpected != 0)) begin
            $error("iter_core comprehensive testbench failed");
        end
        else begin
            $display("[PASS] all comprehensive iter_core tests passed");
        end

        $finish;
    end

    // Global watchdog
    initial begin
        #(GLOBAL_TIMEOUT_NS);
        $error("Global timeout: iter_core_comprehensive_tb hung");
        $finish;
    end

endmodule
