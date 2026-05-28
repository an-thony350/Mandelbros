`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Purpose:
//   Unit-level verification of result_arbiter 
//
// What this checks:
//   1. Reset behaviour.
//   2. No-output behaviour when no core has a valid result.
//   3. Single-core selection and payload muxing.
//   4. Round-robin priority movement after accepted transfers.
//   5. Wraparound from the final core back to core 0.
//   6. Backpressure hold behaviour when the reorder buffer is not ready.
//   7. Full final-design core sweep with NUM_CORES = 16.
//   8. Bursty/non-contiguous valid sets, matching likely real iter_core output.
//////////////////////////////////////////////////////////////////////////////////

module arbiter_tb;

    localparam int NUM_CORES = 16;
    localparam int W         = 26;
    localparam int ITER_W    = 16;
    localparam int SEQ_W     = 20;

    localparam time CLK_PERIOD = 10ns;

    logic clk;
    logic rst_n;

    logic [NUM_CORES-1:0]                core_out_valid;
    logic [NUM_CORES-1:0]                core_out_ready;
    logic [(SEQ_W*NUM_CORES)-1:0]        core_out_seq;
    logic [(ITER_W*NUM_CORES)-1:0]       core_out_iter;
    logic signed [(W*NUM_CORES)-1:0]     core_out_z_r;
    logic signed [(W*NUM_CORES)-1:0]     core_out_z_i;
    logic [NUM_CORES-1:0]                core_out_escaped;
    logic [NUM_CORES-1:0]                core_out_overflow;

    logic                                rob_in_valid;
    logic                                rob_in_ready;
    logic [ITER_W-1:0]                   rob_in_iter_count;
    logic [SEQ_W-1:0]                    rob_in_seq_num;
    logic signed [W-1:0]                 rob_in_z_r;
    logic signed [W-1:0]                 rob_in_z_i;
    logic                                rob_in_escaped;
    logic                                rob_in_overflow;

    int n_tests;
    int n_fails;

    // DUT
    result_arbiter #(
        .NUM_CORES(NUM_CORES),
        .W(W),
        .ITER_W(ITER_W),
        .SEQ_W(SEQ_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .core_out_valid(core_out_valid),
        .core_out_ready(core_out_ready),
        .core_out_seq(core_out_seq),
        .core_out_iter(core_out_iter),
        .core_out_z_r(core_out_z_r),
        .core_out_z_i(core_out_z_i),
        .core_out_escaped(core_out_escaped),
        .core_out_overflow(core_out_overflow),

        .rob_in_valid(rob_in_valid),
        .rob_in_ready(rob_in_ready),
        .rob_in_iter_count(rob_in_iter_count),
        .rob_in_seq_num(rob_in_seq_num),
        .rob_in_z_r(rob_in_z_r),
        .rob_in_z_i(rob_in_z_i),
        .rob_in_escaped(rob_in_escaped),
        .rob_in_overflow(rob_in_overflow)
    );

    // Clock
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Helpers for packed per-core buses
    function automatic logic [SEQ_W-1:0] get_seq(input int core_id);
        get_seq = core_out_seq[(core_id*SEQ_W) +: SEQ_W];
    endfunction

    function automatic logic [ITER_W-1:0] get_iter(input int core_id);
        get_iter = core_out_iter[(core_id*ITER_W) +: ITER_W];
    endfunction

    function automatic logic signed [W-1:0] get_z_r(input int core_id);
        get_z_r = core_out_z_r[(core_id*W) +: W];
    endfunction

    function automatic logic signed [W-1:0] get_z_i(input int core_id);
        get_z_i = core_out_z_i[(core_id*W) +: W];
    endfunction

    task automatic check(input bit condition, input string msg);
        begin
            n_tests++;
            if (!condition) begin
                n_fails++;
                $display("[FAIL] %s", msg);
            end
            else begin
                $display("[PASS] %s", msg);
            end
        end
    endtask

    task automatic clear_all_cores;
        begin
            core_out_valid    = '0;
            core_out_seq      = '0;
            core_out_iter     = '0;
            core_out_z_r      = '0;
            core_out_z_i      = '0;
            core_out_escaped  = '0;
            core_out_overflow = '0;
        end
    endtask

    task automatic set_core_result(
        input int core_id,
        input logic [SEQ_W-1:0] seq,
        input logic [ITER_W-1:0] iter,
        input logic signed [W-1:0] z_r,
        input logic signed [W-1:0] z_i,
        input logic escaped,
        input logic overflow
    );
        begin
            check((core_id >= 0) && (core_id < NUM_CORES),
                  $sformatf("set_core_result core_id %0d in range", core_id));

            core_out_valid[core_id] = 1'b1;
            core_out_seq[(core_id*SEQ_W) +: SEQ_W]   = seq;
            core_out_iter[(core_id*ITER_W) +: ITER_W] = iter;
            core_out_z_r[(core_id*W) +: W]            = z_r;
            core_out_z_i[(core_id*W) +: W]            = z_i;
            core_out_escaped[core_id]                 = escaped;
            core_out_overflow[core_id]                = overflow;
        end
    endtask

    task automatic drop_core(input int core_id);
        begin
            core_out_valid[core_id] = 1'b0;
        end
    endtask

    task automatic apply_reset;
        begin
            rst_n = 1'b0;
            rob_in_ready = 1'b0;
            clear_all_cores();
            repeat (5) @(posedge clk);
            #(CLK_PERIOD/10);

            check(rob_in_valid === 1'b0, "reset: rob_in_valid low");
            check(core_out_ready === '0, "reset: no core ready");

            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            #(CLK_PERIOD/10);
        end
    endtask

    task automatic expect_no_grant(input string name);
        begin
            #(CLK_PERIOD/10);
            check(rob_in_valid === 1'b0,
                  {name, ": rob_in_valid should be low"});
            check(core_out_ready === '0,
                  {name, ": core_out_ready should be all zero"});
        end
    endtask

    task automatic expect_selected(
        input int core_id,
        input logic expected_ready_to_core,
        input string name
    );
        logic [NUM_CORES-1:0] expected_ready_vec;
        begin
            #(CLK_PERIOD/10);

            expected_ready_vec = '0;
            expected_ready_vec[core_id] = expected_ready_to_core;

            check(rob_in_valid === 1'b1,
                  {name, ": rob_in_valid should be high"});
            check(rob_in_seq_num === get_seq(core_id),
                  {name, ": selected seq matches core payload"});
            check(rob_in_iter_count === get_iter(core_id),
                  {name, ": selected iter matches core payload"});
            check(rob_in_z_r === get_z_r(core_id),
                  {name, ": selected z_r matches core payload"});
            check(rob_in_z_i === get_z_i(core_id),
                  {name, ": selected z_i matches core payload"});
            check(rob_in_escaped === core_out_escaped[core_id],
                  {name, ": selected escaped matches core payload"});
            check(rob_in_overflow === core_out_overflow[core_id],
                  {name, ": selected overflow matches core payload"});
            check(core_out_ready === expected_ready_vec,
                  {name, ": ready demux selects only expected core"});
        end
    endtask

    task automatic accept_selected(input int core_id, input string name);
        begin
            rob_in_ready = 1'b1;
            expect_selected(core_id, 1'b1, name);
            @(posedge clk);
            #(CLK_PERIOD/10);
            drop_core(core_id);
            rob_in_ready = 1'b0;
            #(CLK_PERIOD/10);
        end
    endtask

    // Test sequence
    initial begin
        n_tests = 0;
        n_fails = 0;

        $display("==============================");
        $display(" starting result_arbiter_tb...");
        $display("==============================");

        apply_reset();

        // T1: No valid cores.
        clear_all_cores();
        rob_in_ready = 1'b1;
        expect_no_grant("T1 no valid cores");

        // T2: Single valid result, non-zero positive/negative payload fields.
        clear_all_cores();
        rob_in_ready = 1'b0;
        set_core_result(2, 20'd16, 16'd7, 26'sd123, -26'sd45, 1'b1, 1'b0);
        expect_selected(2, 1'b0, "T2 single core selected while ROB stalled");
        accept_selected(2, "T2 single core accepted");

        // After accepting core 2, round-robin pointer should move to 3.
        // T3: Cores 3 and 0 are valid; core 3 must win before wraparound core 0.
        clear_all_cores();
        set_core_result(3, 20'd30, 16'd4,  26'sd300, -26'sd300, 1'b1, 1'b0);
        set_core_result(0, 20'd31, 16'd5,  26'sd100, -26'sd100, 1'b1, 1'b0);
        accept_selected(3, "T3a rr selects core 3 before core 0");
        accept_selected(0, "T3b rr wraps and selects core 0");

        // After accepting core 0, pointer should move to 1.
        // T4/T5: Backpressure hold. Core 2 is selected but not accepted. Core 1
        // becomes valid later, but held core 2 must remain selected until accepted.
        clear_all_cores();
        rob_in_ready = 1'b0;
        set_core_result(2, 20'd40, 16'd9, 26'sd222, -26'sd222, 1'b1, 1'b0);
        expect_selected(2, 1'b0, "T4 selected core ready low when ROB not ready");

        @(posedge clk);
        #(CLK_PERIOD/10);
        set_core_result(1, 20'd41, 16'd10, 26'sd111, -26'sd111, 1'b1, 1'b0);
        expect_selected(2, 1'b0, "T5 held grant remains core 2 despite new core 1 valid");

        accept_selected(2, "T5a accept held core 2");
        accept_selected(1, "T5b then accept pending core 1");

        // T6: Non-contiguous burst after pointer movement.
        // After accepting core 1, pointer should move to 2. Valid set is 4,7,12,1.
        // Expected order is 4,7,12,1.
        clear_all_cores();
        set_core_result(4,  20'd104, 16'd14, 26'sd400, -26'sd400, 1'b1, 1'b0);
        set_core_result(7,  20'd107, 16'd17, 26'sd700, -26'sd700, 1'b1, 1'b0);
        set_core_result(12, 20'd112, 16'd22, 26'sd1200, -26'sd1200, 1'b0, 1'b0);
        set_core_result(1,  20'd101, 16'd11, 26'sd100, -26'sd100, 1'b1, 1'b1);
        accept_selected(4,  "T6a sparse burst selects core 4");
        accept_selected(7,  "T6b sparse burst selects core 7");
        accept_selected(12, "T6c sparse burst selects core 12");
        accept_selected(1,  "T6d sparse burst wraps to core 1");

        // T7: Full final-design 16-core sweep after reset.
        apply_reset();
        clear_all_cores();
        for (int c = 0; c < NUM_CORES; c++) begin
            set_core_result(
                c,
                1000 + c,
                10 + c,
                100 + c,
                -(100 + c),
                (c % 2) == 0,
                (c == NUM_CORES-1)
            );
        end

        for (int c = 0; c < NUM_CORES; c++) begin
            accept_selected(c, $sformatf("T7 full sweep selects core %0d", c));
        end
        expect_no_grant("T7 after all cores consumed");

        $display("============================================================");
        $display(" result_arbiter_tb summary: tests=%0d fails=%0d", n_tests, n_fails);
        $display("============================================================");

        if (n_fails == 0) begin
            $display("[TB PASS] result_arbiter_tb completed successfully");
        end
        else begin
            $error("[TB FAIL] result_arbiter_tb saw %0d failure(s)", n_fails);
        end

        $finish;
    end

endmodule
