`timescale 1ns / 1ps

module result_arbiter_tb;

    localparam int NUM_CORES = 32;
    localparam int W         = 26;
    localparam int ITER_W    = 16;
    localparam int SEQ_W     = 20;

    localparam time CLK_PERIOD = 10ns;

    logic clk = 1'b0;
    logic rst;

    always #(CLK_PERIOD/2) clk = ~clk;
    
    // Inputs from all cores
    logic [NUM_CORES-1:0]        core_out_valid;
    logic [NUM_CORES-1:0]        core_out_ready;

    logic [SEQ_W-1:0]            core_out_seq      [NUM_CORES];
    logic [ITER_W-1:0]           core_out_iter     [NUM_CORES];
    logic signed [W-1:0]         core_out_z_r      [NUM_CORES];
    logic signed [W-1:0]         core_out_z_i      [NUM_CORES];
    logic [NUM_CORES-1:0]        core_out_escaped;
    logic [NUM_CORES-1:0]        core_out_overflow;

    // Output to reorder buffer
    logic                        rob_in_valid;
    logic                        rob_in_ready;

    logic [ITER_W-1:0]           rob_in_iter_count;
    logic [SEQ_W-1:0]            rob_in_seq_num;
    logic signed [W-1:0]         rob_in_z_r;
    logic signed [W-1:0]         rob_in_z_i;
    logic                        rob_in_escaped;
    logic                        rob_in_overflow;

    int n_tests;
    int n_fails;

    result_arbiter #(
        .NUM_CORES (NUM_CORES),
        .W         (W),
        .ITER_W    (ITER_W),
        .SEQ_W     (SEQ_W)
    ) dut (
        .clk               (clk),
        .rst               (rst),

        .core_out_valid    (core_out_valid),
        .core_out_ready    (core_out_ready),

        .core_out_seq      (core_out_seq),
        .core_out_iter     (core_out_iter),
        .core_out_z_r      (core_out_z_r),
        .core_out_z_i      (core_out_z_i),
        .core_out_escaped  (core_out_escaped),
        .core_out_overflow (core_out_overflow),

        .rob_in_valid      (rob_in_valid),
        .rob_in_ready      (rob_in_ready),

        .rob_in_iter_count (rob_in_iter_count),
        .rob_in_seq_num    (rob_in_seq_num),
        .rob_in_z_r        (rob_in_z_r),
        .rob_in_z_i        (rob_in_z_i),
        .rob_in_escaped    (rob_in_escaped),
        .rob_in_overflow   (rob_in_overflow)
    );

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

    task automatic clear_all_cores();
        begin
            core_out_valid   = '0;
            core_out_escaped = '0;
            core_out_overflow = '0;

            for (int i = 0; i < NUM_CORES; i++) begin
                core_out_seq[i]  = '0;
                core_out_iter[i] = '0;
                core_out_z_r[i]  = '0;
                core_out_z_i[i]  = '0;
            end
        end
    endtask

    task automatic set_core_result(
        input int core_id,
        input int seq,
        input int iter,
        input int z_r,
        input int z_i,
        input logic escaped,
        input logic overflow
    );
        begin
            core_out_valid[core_id]   = 1'b1;
            core_out_seq[core_id]     = seq[SEQ_W-1:0];
            core_out_iter[core_id]    = iter[ITER_W-1:0];
            core_out_z_r[core_id]     = z_r;
            core_out_z_i[core_id]     = z_i;
            core_out_escaped[core_id] = escaped;
            core_out_overflow[core_id] = overflow;
        end
    endtask

    task automatic expect_no_grant(input string name);
        begin
            #1;
            check(rob_in_valid === 1'b0, {name, ": rob_in_valid should be 0"});
            check(core_out_ready === '0, {name, ": no core should be ready"});
        end
    endtask

    task automatic expect_selected(input int core_id, input string name);
        begin
            #1;

            check(rob_in_valid === 1'b1,
                  {name, ": rob_in_valid should be 1"});

            check(rob_in_seq_num === core_out_seq[core_id],
                  {name, ": selected seq should match core"});

            check(rob_in_iter_count === core_out_iter[core_id],
                  {name, ": selected iter should match core"});

            check(rob_in_z_r === core_out_z_r[core_id],
                  {name, ": selected z_r should match core"});

            check(rob_in_z_i === core_out_z_i[core_id],
                  {name, ": selected z_i should match core"});

            check(rob_in_escaped === core_out_escaped[core_id],
                  {name, ": selected escaped should match core"});

            check(rob_in_overflow === core_out_overflow[core_id],
                  {name, ": selected overflow should match core"});

            for (int i = 0; i < NUM_CORES; i++) begin
                if (i == core_id) begin
                    check(core_out_ready[i] === rob_in_ready,
                          {name, ": selected core ready should follow rob_in_ready"});
                end
                else begin
                    check(core_out_ready[i] === 1'b0,
                          {name, ": unselected core ready should be 0"});
                end
            end
        end
    endtask

    task automatic accept_selected(input int core_id, input string name);
        begin
            rob_in_ready = 1'b1;
            expect_selected(core_id, name);

            @(posedge clk);
            #1;

            core_out_valid[core_id] = 1'b0;
            rob_in_ready = 1'b0;
            #1;
        end
    endtask

    initial begin
        n_tests = 0;
        n_fails = 0;

        rst = 1'b1;
        rob_in_ready = 1'b0;
        clear_all_cores();

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        $display("================================================");
        $display(" result_arbiter testbench starting");
        $display("================================================");

        // Test 1: no valid cores
        clear_all_cores();
        rob_in_ready = 1'b1;
        expect_no_grant("T1 no valid cores");

        // rr_ptr starts at 0, only core 2 valid, so choose core 2.
        clear_all_cores();
        set_core_result(2, 16, 7, 123, -45, 1'b1, 1'b0);
        accept_selected(2, "T2 single core 2 selected");

        // After accepting core 2, rr_ptr should move to 3.

        // Cores 3 and 0 valid. Since rr_ptr should be 3, choose core 3 first.
        clear_all_cores();
        set_core_result(3, 30, 4, 300, -300, 1'b1, 1'b0);
        set_core_result(0, 31, 5, 100, -100, 1'b1, 1'b0);

        accept_selected(3, "T3a round-robin chooses core 3 first");
        accept_selected(0, "T3b round-robin then chooses core 0");

        // After accepting core 0, rr_ptr should move to 1.

        clear_all_cores();
        rob_in_ready = 1'b0;
        set_core_result(2, 40, 9, 222, -222, 1'b1, 1'b0);

        expect_selected(2, "T4 selected core held while rob not ready");
        check(core_out_ready[2] === 1'b0,
              "T4 selected core ready should be 0 when rob_in_ready is 0");

        // Let the arbiter register the held grant.
        @(posedge clk);
        #1;

        // Add core 1 valid. Without the hold logic, arbiter might switch to core 1.
        // Correct behaviour: keep presenting core 2 until accepted.
        set_core_result(1, 41, 10, 111, -111, 1'b1, 1'b0);

        expect_selected(2, "T5 held grant should remain core 2 despite core 1 becoming valid");

        // Now accept core 2.
        accept_selected(2, "T5 accept held core 2");

        // Core 1 is still valid, so it should be selected next.
        accept_selected(1, "T5 then accept core 1");

        // This checks that the arbiter still rotates fairly.
        clear_all_cores();

        set_core_result(0, 50, 1, 10, -10, 1'b1, 1'b0);
        set_core_result(1, 51, 2, 20, -20, 1'b1, 1'b0);
        set_core_result(2, 52, 3, 30, -30, 1'b1, 1'b0);
        set_core_result(3, 53, 4, 40, -40, 1'b1, 1'b0);

        // Depending on previous rr_ptr, this should continue round-robin.
        // After accepting core 1 above, rr_ptr should be 2.
        accept_selected(2, "T6a round-robin chooses core 2");
        accept_selected(3, "T6b round-robin chooses core 3");
        accept_selected(0, "T6c round-robin wraps to core 0");
        accept_selected(1, "T6d round-robin then chooses core 1");
        
        // all 32 cores valid, check full round-robin sweep        
        clear_all_cores();
        rob_in_ready = 1'b0;
        
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        
        // Make every core valid
        for (int c = 0; c < NUM_CORES; c++) begin
            set_core_result(
                c,              // core_id
                1000 + c,        // seq
                10 + c,          // iter
                100 + c,         // z_r
                -100 - c,        // z_i
                1'b1,            // escaped
                1'b0             // overflow
            );
        end
        
        // Since rr_ptr was reset to 0, expected order is 0,1,2,...,31
        for (int c = 0; c < NUM_CORES; c++) begin
            accept_selected(c, $sformatf("T7 full 32-core sweep selects core %0d", c));
        end

        // Summary
        $display("================================================");
        $display(" result_arbiter summary: tests=%0d fails=%0d",
                 n_tests, n_fails);
        $display("================================================");

        if (n_fails > 0) begin
            $error("%0d arbiter test(s) failed", n_fails);
        end

        $finish;
    end

endmodule