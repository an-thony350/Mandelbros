`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
//
// Testbench: skid_buffer_tb
// Project: FractalScope
// Tool: Vivado 2023.2 / XSim
//
// Description:
//   Self-checking unit testbench for skid_buffer_m using the final pipeline data
//   width used between each iter_core and the result_arbiter:
//
//       seq[19:0] + iter[15:0] + z_r[25:0] + z_i[25:0]
//       + escaped + overflow = 90 bits
//
//   The testbench verifies the 2-deep valid/ready FIFO behaviour that matters for
//   the final block design:
//     - reset flushes the buffer
//     - empty / one-entry / full ready-valid states
//     - write-only, read-only, simultaneous read/write
//     - backpressure holds the oldest output stable
//     - a full buffer does not accept a new word in the same cycle that it frees
//       one entry, because in_ready is intentionally registered-count based
//     - ordered delivery under realistic burst/stall patterns
//////////////////////////////////////////////////////////////////////////////////

module skid_buffer_tb;

    localparam int W          = 26;
    localparam int ITER_W     = 16;
    localparam int SEQ_W      = 20;
    localparam int INPUT_DATA = SEQ_W + ITER_W + W + W + 1 + 1; // 90

    localparam time CLK_PERIOD = 10ns;

    logic clk = 1'b0;
    logic rst_n;

    logic                  in_valid;
    logic                  in_ready;
    logic [INPUT_DATA-1:0] in_data;

    logic                  out_valid;
    logic                  out_ready;
    logic [INPUT_DATA-1:0] out_data;

    int n_tests;
    int n_fails;

    logic last_accept_in;
    logic last_accept_out;

    // Reference model queue. The DUT is only 2 deep, but the larger array makes
    // the helper tasks simple while still checking that model_count never exceeds 2.
    logic [INPUT_DATA-1:0] model_q [0:255];
    int model_head;
    int model_tail;
    int model_count;

    always #(CLK_PERIOD/2) clk = ~clk;

    skid_buffer_m #(
        .INPUT_DATA(INPUT_DATA)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_ready  (in_ready),
        .in_data   (in_data),
        .out_valid (out_valid),
        .out_ready (out_ready),
        .out_data  (out_data)
    );

    function automatic logic [INPUT_DATA-1:0] make_payload(
        input logic [SEQ_W-1:0]          seq,
        input logic [ITER_W-1:0]         iter,
        input logic signed [W-1:0]       z_r,
        input logic signed [W-1:0]       z_i,
        input logic                      escaped,
        input logic                      overflow
    );
        make_payload = {seq, iter, z_r, z_i, escaped, overflow};
    endfunction

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

    task automatic model_clear();
        model_head  = 0;
        model_tail  = 0;
        model_count = 0;
    endtask

    task automatic model_push(input logic [INPUT_DATA-1:0] data);
        check(model_count < 2, "reference model push only when skid buffer has space");
        model_q[model_tail] = data;
        model_tail = (model_tail + 1) % 256;
        model_count++;
    endtask

    task automatic model_pop(output logic [INPUT_DATA-1:0] data);
        check(model_count > 0, "reference model pop only when skid buffer has data");
        data = model_q[model_head];
        model_head = (model_head + 1) % 256;
        model_count--;
    endtask

    task automatic check_interface(input string tag);
        logic expected_in_ready;
        logic expected_out_valid;

        expected_in_ready  = (model_count < 2);
        expected_out_valid = (model_count > 0);

        check(in_ready === expected_in_ready,
              {tag, ": in_ready matches 2-deep occupancy model"});
        check(out_valid === expected_out_valid,
              {tag, ": out_valid matches 2-deep occupancy model"});

        if (expected_out_valid) begin
            check(out_data === model_q[model_head],
                  {tag, ": out_data is oldest queued payload"});
        end
    endtask

    task automatic step_cycle(
        input logic                  drive_valid,
        input logic [INPUT_DATA-1:0] drive_data,
        input logic                  drive_ready,
        input string                 tag
    );
        logic accept_in;
        logic accept_out;
        logic [INPUT_DATA-1:0] accepted_in_data;
        logic [INPUT_DATA-1:0] popped_data;

        @(negedge clk);
        in_valid = drive_valid;
        in_data  = drive_data;
        out_ready = drive_ready;

        #1;
        check_interface({tag, " before edge"});

        accept_in        = in_valid && in_ready;
        accept_out       = out_valid && out_ready;
        accepted_in_data = in_data;
        last_accept_in   = accept_in;
        last_accept_out  = accept_out;

        @(posedge clk);

        // The DUT's simultaneous read/write behaviour is FIFO-like: the old head
        // is consumed and the new accepted payload is appended to the tail.
        if (accept_out) begin
            model_pop(popped_data);
        end
        if (accept_in) begin
            model_push(accepted_in_data);
        end

        #1;
        check_interface({tag, " after edge"});
    endtask

    task automatic reset_dut();
        @(negedge clk);
        rst_n     = 1'b0;
        in_valid  = 1'b0;
        in_data   = '0;
        out_ready = 1'b0;
        model_clear();

        repeat (3) @(posedge clk);
        #1;
        check(in_ready  === 1'b1, "reset: in_ready high because buffer is empty");
        check(out_valid === 1'b0, "reset: out_valid low because buffer is empty");

        @(negedge clk);
        rst_n = 1'b1;
        #1;
        check_interface("after reset release");
    endtask

    task automatic drain_until_empty(input string tag);
        int guard;
        logic [INPUT_DATA-1:0] dummy_payload;

        dummy_payload = '0;
        guard = 0;
        while (model_count > 0 && guard < 8) begin
            step_cycle(1'b0, dummy_payload, 1'b1, {tag, " drain"});
            guard++;
        end
        check(model_count == 0, {tag, ": reference model drained to empty"});
    endtask

    initial begin
        logic [INPUT_DATA-1:0] p0;
        logic [INPUT_DATA-1:0] p1;
        logic [INPUT_DATA-1:0] p2;
        logic [INPUT_DATA-1:0] p3;
        logic [INPUT_DATA-1:0] p4;
        logic [INPUT_DATA-1:0] p5;
        logic [INPUT_DATA-1:0] p6;
        logic [INPUT_DATA-1:0] p7;
        logic [INPUT_DATA-1:0] p8;
        int i;

        n_tests = 0;
        n_fails = 0;
        model_clear();
        last_accept_in  = 1'b0;
        last_accept_out = 1'b0;

        rst_n     = 1'b0;
        in_valid  = 1'b0;
        in_data   = '0;
        out_ready = 1'b0;

        p0 = make_payload(20'd0,  16'd4,  26'sd1,     -26'sd1,    1'b1, 1'b0);
        p1 = make_payload(20'd1,  16'd8,  26'sd10,    -26'sd10,   1'b1, 1'b0);
        p2 = make_payload(20'd2,  16'd12, 26'sd100,   -26'sd100,  1'b0, 1'b0);
        p3 = make_payload(20'd3,  16'd16, 26'sd1000,  -26'sd1000, 1'b1, 1'b1);
        p4 = make_payload(20'd4,  16'd20, -26'sd7,     26'sd9,    1'b1, 1'b0);
        p5 = make_payload(20'd5,  16'd24, -26'sd15,    26'sd31,   1'b1, 1'b0);
        p6 = make_payload(20'd6,  16'd28,  26'sd12345,-26'sd222,  1'b0, 1'b0);
        p7 = make_payload(20'd7,  16'd32, -26'sd333,   26'sd444,  1'b1, 1'b0);
        p8 = make_payload(20'd8,  16'd36,  26'sd555,  -26'sd666,  1'b1, 1'b1);

        $display("============================================================");
        $display(" skid_buffer_tb starting");
        $display(" INPUT_DATA=%0d bits", INPUT_DATA);
        $display("============================================================");

        reset_dut();

        // T1: Idle empty buffer. Nothing should become valid unless input handshakes.
        step_cycle(1'b0, '0, 1'b0, "T1 idle empty, downstream stalled");
        step_cycle(1'b0, '0, 1'b1, "T1 idle empty, downstream ready");

        // T2: Single write then hold then read.
        step_cycle(1'b1, p0, 1'b0, "T2a write one payload into empty buffer");
        step_cycle(1'b0, '0, 1'b0, "T2b hold one payload under backpressure");
        step_cycle(1'b0, '0, 1'b1, "T2c read one payload out");
        check(model_count == 0, "T2 final occupancy is empty");

        // T3: Fill both entries, prove full backpressure, and prove that a word
        // offered while full is not accepted even if the same edge pops one entry.
        step_cycle(1'b1, p1, 1'b0, "T3a write first payload while stalled");
        step_cycle(1'b1, p2, 1'b0, "T3b write second payload while stalled");
        check(model_count == 2, "T3 full occupancy reached");
        check(in_ready === 1'b0, "T3 full buffer deasserts in_ready");

        step_cycle(1'b1, p3, 1'b0, "T3c full and stalled: offered payload is rejected");
        check(model_count == 2, "T3c occupancy remains full after rejected write");

        step_cycle(1'b1, p3, 1'b1, "T3d full plus downstream ready: read only, no same-cycle refill");
        check(last_accept_out === 1'b1, "T3d downstream consumed the oldest full-buffer entry");
        check(last_accept_in  === 1'b0, "T3d input was not accepted while in_ready was low at the edge");
        check(model_count == 1, "T3d occupancy drops to one because full-cycle input was not accepted");
        check(in_ready === 1'b1, "T3d buffer advertises space one cycle after full read");

        step_cycle(1'b1, p3, 1'b0, "T3e retry previously rejected payload once space is visible");
        check(model_count == 2, "T3e retry refills buffer to full");
        drain_until_empty("T3f");

        // T4: True simultaneous read/write when occupancy is one. This models a
        // steady stream from a core through the skid buffer into an accepting arbiter.
        step_cycle(1'b1, p4, 1'b0, "T4a preload one payload");
        step_cycle(1'b1, p5, 1'b1, "T4b simultaneous read p4 and write p5");
        step_cycle(1'b1, p6, 1'b1, "T4c simultaneous read p5 and write p6");
        step_cycle(1'b1, p7, 1'b1, "T4d simultaneous read p6 and write p7");
        step_cycle(1'b0, '0, 1'b1, "T4e drain final streamed payload p7");
        check(model_count == 0, "T4 final occupancy is empty after streamed drain");

        // T5: Backpressure holds the oldest output stable while the second slot
        // can still fill, then full prevents further acceptance.
        step_cycle(1'b1, p0, 1'b0, "T5a preload p0");
        step_cycle(1'b1, p1, 1'b0, "T5b accept p1 into second slot while holding p0");
        check(model_count == 2, "T5b buffer full with p0 then p1");
        check(out_data === p0, "T5b oldest p0 is still presented at output");

        step_cycle(1'b1, p8, 1'b0, "T5c full stalled: p8 is not accepted and p0 remains output");
        check(out_data === p0, "T5c output still holds oldest p0 under full backpressure");
        drain_until_empty("T5d");

        // T6: Reset flushes pending data even if both entries are occupied.
        step_cycle(1'b1, p2, 1'b0, "T6a fill entry 0 before reset");
        step_cycle(1'b1, p3, 1'b0, "T6b fill entry 1 before reset");
        check(model_count == 2, "T6 full before reset");
        reset_dut();
        check(model_count == 0, "T6 reset flushes reference model");
        check(out_valid === 1'b0, "T6 reset flushes DUT output valid");

        // T7: Deterministic burst/stall pattern. The source respects ready/valid
        // by retrying after rejected cycles; the scoreboard checks ordering every cycle.
        step_cycle(1'b1, make_payload(20'd100, 16'd1,  26'sd1,  26'sd2,  1'b1, 1'b0), 1'b0, "T7a burst write 100");
        step_cycle(1'b1, make_payload(20'd101, 16'd2,  26'sd3,  26'sd4,  1'b1, 1'b0), 1'b0, "T7b burst write 101");
        step_cycle(1'b1, make_payload(20'd102, 16'd3,  26'sd5,  26'sd6,  1'b1, 1'b0), 1'b1, "T7c full-cycle read only, 102 must be retried");
        step_cycle(1'b1, make_payload(20'd102, 16'd3,  26'sd5,  26'sd6,  1'b1, 1'b0), 1'b1, "T7d retry 102 with simultaneous transfer");
        step_cycle(1'b1, make_payload(20'd103, 16'd4, -26'sd7,  26'sd8,  1'b0, 1'b0), 1'b0, "T7e write 103 while downstream stalls");
        step_cycle(1'b1, make_payload(20'd104, 16'd5,  26'sd9, -26'sd10, 1'b1, 1'b1), 1'b1, "T7f full-cycle read only, 104 must be retried");
        step_cycle(1'b1, make_payload(20'd104, 16'd5,  26'sd9, -26'sd10, 1'b1, 1'b1), 1'b1, "T7g retry 104 with simultaneous transfer");
        drain_until_empty("T7h");

        // T8: A compact sweep of realistic final-design payloads. This keeps the
        // width and sign extension paths honest. The source retries the same
        // payload until the ready/valid handshake accepts it.
        for (i = 0; i < 12; i++) begin
            logic [INPUT_DATA-1:0] sweep_payload;
            int attempts;

            sweep_payload = make_payload(
                200 + i,
                i * 7,
                i * 111 - 500,
                300 - i * 37,
                (i % 3) != 0,
                (i == 9)
            );

            attempts = 0;
            do begin
                // Alternate stalls so the buffer repeatedly sees empty, one-entry,
                // full, and simultaneous transfer states. If the buffer was full
                // at the edge, the same payload is retried on the next cycle.
                step_cycle(
                    1'b1,
                    sweep_payload,
                    ((i + attempts) % 3) != 0,
                    {"T8 sweep payload ", $sformatf("%0d attempt %0d", i, attempts)}
                );
                attempts++;
            end while (!last_accept_in && attempts < 5);

            check(last_accept_in === 1'b1, {"T8 payload accepted after retry loop ", $sformatf("%0d", i)});
        end
        drain_until_empty("T8 final");

        $display("============================================================");
        $display(" skid_buffer_tb summary: tests=%0d fails=%0d", n_tests, n_fails);
        $display("============================================================");

        if (n_fails == 0) begin
            $display("[TB PASS] skid_buffer_tb completed successfully");
            $finish;
        end
        else begin
            $display("[TB FAIL] skid_buffer_tb completed with %0d failure(s)", n_fails);
            $fatal(1);
        end
    end

endmodule
