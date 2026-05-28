`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineers: Anthony Bartlett & Denzil Erza-Essien
//
// Testbench: perf_counters_tb
// Target:    Vivado 2023.2 / XSim
//
// Purpose:
//   Self-checking unit testbench for the final FractalScope perf_counters RTL.
//
//     - counters update only on stream_valid && stream_ready
//     - sof_pulse snapshots the previous frame and starts a new frame
//     - first pixel of a new frame is counted if SOF coincides with a handshake
//     - invalid/stalled pixels are ignored
//     - snapshots remain stable between SOF pulses
//     - frame-cycle counter includes the SOF cycle as cycle 1 of the new frame
//     - reset clears temporary and snapshot counters
//
//////////////////////////////////////////////////////////////////////////////////

module perf_counters_tb;

    localparam int ITER_W = 16;

    logic              clk;
    logic              rst_n;
    logic              stream_valid;
    logic              stream_ready;
    logic              sof_pulse;
    logic [ITER_W-1:0] pixel_iter;
    logic              pixel_escaped;
    logic              pixel_hit_max;

    logic [31:0]       snap_frame_cycles;
    logic [63:0]       snap_total_iters;
    logic [31:0]       snap_pixels_escaped;
    logic [31:0]       snap_pixels_hit_max;

    int tests;
    int fails;

    logic [31:0]       ref_tmp_frame_cycles;
    logic [63:0]       ref_tmp_total_iters;
    logic [31:0]       ref_tmp_pixels_escaped;
    logic [31:0]       ref_tmp_pixels_hit_max;

    logic [31:0]       ref_snap_frame_cycles;
    logic [63:0]       ref_snap_total_iters;
    logic [31:0]       ref_snap_pixels_escaped;
    logic [31:0]       ref_snap_pixels_hit_max;

    perf_counters #(
        .ITER_W(ITER_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .stream_valid(stream_valid),
        .stream_ready(stream_ready),
        .sof_pulse(sof_pulse),
        .pixel_iter(pixel_iter),
        .pixel_escaped(pixel_escaped),
        .pixel_hit_max(pixel_hit_max),
        .snap_frame_cycles(snap_frame_cycles),
        .snap_total_iters(snap_total_iters),
        .snap_pixels_escaped(snap_pixels_escaped),
        .snap_pixels_hit_max(snap_pixels_hit_max)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic pass(input string msg);
        begin
            tests++;
            $display("[PASS] %s", msg);
        end
    endtask

    task automatic fail(input string msg);
        begin
            tests++;
            fails++;
            $display("[FAIL] %s", msg);
        end
    endtask

    task automatic check32(
        input string       label,
        input logic [31:0] actual,
        input logic [31:0] expected
    );
        begin
            if (actual !== expected) begin
                fail($sformatf("%s: expected=0x%08h actual=0x%08h", label, expected, actual));
            end else begin
                pass($sformatf("%s: expected=0x%08h actual=0x%08h", label, expected, actual));
            end
        end
    endtask

    task automatic check64(
        input string       label,
        input logic [63:0] actual,
        input logic [63:0] expected
    );
        begin
            if (actual !== expected) begin
                fail($sformatf("%s: expected=0x%016h actual=0x%016h", label, expected, actual));
            end else begin
                pass($sformatf("%s: expected=0x%016h actual=0x%016h", label, expected, actual));
            end
        end
    endtask

    task automatic update_reference_model;
        begin
            if (!rst_n) begin
                ref_tmp_frame_cycles   = '0;
                ref_tmp_total_iters    = '0;
                ref_tmp_pixels_escaped = '0;
                ref_tmp_pixels_hit_max = '0;

                ref_snap_frame_cycles   = '0;
                ref_snap_total_iters    = '0;
                ref_snap_pixels_escaped = '0;
                ref_snap_pixels_hit_max = '0;
            end else begin
                if (sof_pulse) begin
                    ref_snap_frame_cycles   = ref_tmp_frame_cycles;
                    ref_snap_total_iters    = ref_tmp_total_iters;
                    ref_snap_pixels_escaped = ref_tmp_pixels_escaped;
                    ref_snap_pixels_hit_max = ref_tmp_pixels_hit_max;

                    ref_tmp_frame_cycles = 32'd1;

                    if (stream_valid && stream_ready) begin
                        ref_tmp_total_iters    = {{(64-ITER_W){1'b0}}, pixel_iter};
                        ref_tmp_pixels_escaped = pixel_escaped ? 32'd1 : 32'd0;
                        ref_tmp_pixels_hit_max = pixel_hit_max ? 32'd1 : 32'd0;
                    end else begin
                        ref_tmp_total_iters    = '0;
                        ref_tmp_pixels_escaped = '0;
                        ref_tmp_pixels_hit_max = '0;
                    end
                end else begin
                    ref_tmp_frame_cycles = ref_tmp_frame_cycles + 32'd1;

                    if (stream_valid && stream_ready) begin
                        ref_tmp_total_iters = ref_tmp_total_iters + {{(64-ITER_W){1'b0}}, pixel_iter};

                        if (pixel_escaped) begin
                            ref_tmp_pixels_escaped = ref_tmp_pixels_escaped + 32'd1;
                        end

                        if (pixel_hit_max) begin
                            ref_tmp_pixels_hit_max = ref_tmp_pixels_hit_max + 32'd1;
                        end
                    end
                end
            end
        end
    endtask

    task automatic check_against_reference(input string label);
        begin
            check32($sformatf("%s: snap_frame_cycles", label),
                    snap_frame_cycles,
                    ref_snap_frame_cycles);
            check64($sformatf("%s: snap_total_iters", label),
                    snap_total_iters,
                    ref_snap_total_iters);
            check32($sformatf("%s: snap_pixels_escaped", label),
                    snap_pixels_escaped,
                    ref_snap_pixels_escaped);
            check32($sformatf("%s: snap_pixels_hit_max", label),
                    snap_pixels_hit_max,
                    ref_snap_pixels_hit_max);
        end
    endtask

    task automatic check_snapshot_exact(
        input string       label,
        input logic [31:0] exp_cycles,
        input logic [63:0] exp_iters,
        input logic [31:0] exp_escaped,
        input logic [31:0] exp_hit_max
    );
        begin
            check32($sformatf("%s: exact frame cycles", label),
                    snap_frame_cycles,
                    exp_cycles);
            check64($sformatf("%s: exact total iterations", label),
                    snap_total_iters,
                    exp_iters);
            check32($sformatf("%s: exact escaped pixels", label),
                    snap_pixels_escaped,
                    exp_escaped);
            check32($sformatf("%s: exact hit-max pixels", label),
                    snap_pixels_hit_max,
                    exp_hit_max);
        end
    endtask

    task automatic drive_cycle(
        input logic              rst_n_i,
        input logic              valid_i,
        input logic              ready_i,
        input logic              sof_i,
        input logic [ITER_W-1:0] iter_i,
        input logic              escaped_i,
        input logic              hit_max_i,
        input string             label
    );
        begin
            @(negedge clk);
            rst_n         = rst_n_i;
            stream_valid  = valid_i;
            stream_ready  = ready_i;
            sof_pulse     = sof_i;
            pixel_iter    = iter_i;
            pixel_escaped = escaped_i;
            pixel_hit_max = hit_max_i;

            @(posedge clk);
            #1;
            update_reference_model();
            check_against_reference(label);
        end
    endtask

    initial begin
        tests = 0;
        fails = 0;

        rst_n         = 1'b0;
        stream_valid  = 1'b0;
        stream_ready  = 1'b0;
        sof_pulse     = 1'b0;
        pixel_iter    = '0;
        pixel_escaped = 1'b0;
        pixel_hit_max = 1'b0;

        ref_tmp_frame_cycles   = '0;
        ref_tmp_total_iters    = '0;
        ref_tmp_pixels_escaped = '0;
        ref_tmp_pixels_hit_max = '0;
        ref_snap_frame_cycles   = '0;
        ref_snap_total_iters    = '0;
        ref_snap_pixels_escaped = '0;
        ref_snap_pixels_hit_max = '0;

        $display("============================================================");
        $display(" perf_counters_tb: Vivado 2023.2 final-interface testbench");
        $display(" ITER_W=%0d", ITER_W);
        $display("============================================================");

        // T0: reset must clear both temporary counters and public snapshots.
        drive_cycle(1'b0, 1'b0, 1'b0, 1'b0, 16'd0,   1'b0, 1'b0, "T0a reset cycle 0");
        drive_cycle(1'b0, 1'b1, 1'b1, 1'b1, 16'd999, 1'b1, 1'b1, "T0b reset ignores active-looking inputs");
        check_snapshot_exact("T0 reset clears public snapshots", 32'd0, 64'd0, 32'd0, 32'd0);

        // T1: after reset release, frame_cycles runs internally, but snapshots stay zero until SOF.
        drive_cycle(1'b1, 1'b0, 1'b0, 1'b0, 16'd0, 1'b0, 1'b0, "T1a idle after reset release");
        drive_cycle(1'b1, 1'b0, 1'b1, 1'b0, 16'd0, 1'b0, 1'b0, "T1b idle valid-low ready-high");
        drive_cycle(1'b1, 1'b1, 1'b0, 1'b0, 16'd777, 1'b1, 1'b1, "T1c stalled valid before first frame is ignored");
        check_snapshot_exact("T1 snapshots remain zero before first SOF", 32'd0, 64'd0, 32'd0, 32'd0);

        // T2: start frame A. The SOF cycle snapshots the pre-frame idle period and
        // counts the first pixel of frame A because valid && ready is true.
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b1, 16'd100, 1'b0, 1'b1, "T2a SOF starts frame A and counts first pixel");
        check_snapshot_exact("T2a first SOF snapshots three pre-frame cycles", 32'd3, 64'd0, 32'd0, 32'd0);

        // Frame A body. Only handshake cycles should count.
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b0, 16'd45,  1'b1, 1'b0, "T2b frame A counts escaped pixel");
        drive_cycle(1'b1, 1'b1, 1'b0, 1'b0, 16'd999, 1'b1, 1'b1, "T2c frame A ignores valid pixel while stream_ready low");
        drive_cycle(1'b1, 1'b0, 1'b1, 1'b0, 16'd888, 1'b1, 1'b1, "T2d frame A ignores ready-only non-valid cycle");
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b0, 16'd10,  1'b1, 1'b0, "T2e frame A counts second escaped pixel");
        drive_cycle(1'b1, 1'b0, 1'b1, 1'b0, 16'd0,   1'b0, 1'b0, "T2f frame A idle cycle contributes only to cycles");
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b0, 16'd200, 1'b0, 1'b1, "T2g frame A counts hit-max pixel");
        drive_cycle(1'b1, 1'b0, 1'b0, 1'b0, 16'd0,   1'b0, 1'b0, "T2h frame A idle stalled cycle");
        drive_cycle(1'b1, 1'b1, 1'b0, 1'b0, 16'd321, 1'b1, 1'b1, "T2i frame A final stalled offered pixel is ignored");

        // T3: start frame B. This snapshots frame A:
        //   counted pixels: 100, 45, 10, 200
        //   total iters:    355
        //   escaped count:  2
        //   hit-max count:  2
        //   frame cycles:   9, counting the frame-A SOF cycle as cycle 1.
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b1, 16'd7, 1'b1, 1'b0, "T3a SOF starts frame B and snapshots frame A");
        check_snapshot_exact("T3a frame A snapshot", 32'd9, 64'd355, 32'd2, 32'd2);

        // T4: continue frame B, then send an SOF pulse without a pixel handshake.
        // The previous frame should still snapshot correctly, and the new frame starts empty.
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b0, 16'd5, 1'b0, 1'b1, "T4a frame B counts second pixel");
        drive_cycle(1'b1, 1'b0, 1'b1, 1'b1, 16'd999, 1'b1, 1'b1, "T4b SOF without valid snapshots frame B and starts empty frame C");
        check_snapshot_exact("T4b frame B snapshot from SOF without handshake", 32'd2, 64'd12, 32'd1, 32'd1);

        // T5: empty frame C has no handshakes; next SOF should snapshot zero pixel counts.
        drive_cycle(1'b1, 1'b0, 1'b1, 1'b0, 16'd0,   1'b0, 1'b0, "T5a empty frame C idle cycle");
        drive_cycle(1'b1, 1'b0, 1'b1, 1'b0, 16'd123, 1'b1, 1'b1, "T5b empty frame C valid-low ignored cycle");
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b1, 16'd20,  1'b0, 1'b1, "T5c SOF starts frame D and snapshots empty frame C");
        check_snapshot_exact("T5c empty frame C snapshot", 32'd3, 64'd0, 32'd0, 32'd0);

        // T6: reset during an active frame must clear all public snapshots.
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b0, 16'd30, 1'b1, 1'b0, "T6a frame D counts one more pixel before reset");
        drive_cycle(1'b0, 1'b1, 1'b1, 1'b1, 16'd55, 1'b1, 1'b1, "T6b reset flushes counters despite active SOF/handshake");
        check_snapshot_exact("T6b reset clears snapshots again", 32'd0, 64'd0, 32'd0, 32'd0);

        // T7: after reset, counting should restart from a clean state.
        drive_cycle(1'b1, 1'b0, 1'b1, 1'b0, 16'd0,  1'b0, 1'b0, "T7a post-reset idle cycle");
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b1, 16'd64, 1'b1, 1'b0, "T7b post-reset SOF starts fresh frame");
        check_snapshot_exact("T7b post-reset SOF snapshots one idle cycle only", 32'd1, 64'd0, 32'd0, 32'd0);
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b0, 16'd36, 1'b0, 1'b1, "T7c post-reset frame counts second pixel");
        drive_cycle(1'b1, 1'b1, 1'b1, 1'b1, 16'd1,  1'b1, 1'b0, "T7d next SOF snapshots post-reset frame");
        check_snapshot_exact("T7d post-reset frame snapshot", 32'd2, 64'd100, 32'd1, 32'd1);

        $display("============================================================");
        $display(" perf_counters_tb summary: tests=%0d fails=%0d", tests, fails);
        $display("============================================================");

        if (fails == 0) begin
            $display("[TB PASS] perf_counters_tb completed successfully");
        end else begin
            $display("[TB FAIL] perf_counters_tb completed with %0d failures", fails);
        end

        $finish;
    end

endmodule
