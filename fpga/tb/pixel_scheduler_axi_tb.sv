`timescale 1ns / 1ps

// AXI-Lite final-parameter test for pixel_scheduler_top / pixel_scheduler_AXI.
// Mirrors final geometry: NUM_CORES=16, X_RES=1280, Y_RES=720.

module pixel_scheduler_axi_tb;

    // Set xsim.simulate.runtime to all, or at least around 12 ms.

    localparam int NUM_CORES = 16;
    localparam int W         = 26;
    localparam int FRAC      = 22;
    localparam int SEQ_W     = 20;
    localparam int ITER_W    = 16;
    localparam int MODE_W    = 3;
    localparam int X_RES     = 1280;
    localparam int Y_RES     = 720;
    localparam int PIXELS    = X_RES * Y_RES;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic aresetn = 1'b0;

    function automatic logic signed [W-1:0] q_from_real(input real value);
        q_from_real = $rtoi(value * (1 << FRAC));
    endfunction

    function automatic logic [31:0] reg_from_q(input logic signed [W-1:0] q_value);
        reg_from_q = {6'd0, q_value};
    endfunction

    // Scheduler-side ports.
    logic [NUM_CORES-1:0]                in_ready;
    logic [NUM_CORES-1:0]                in_valid;
    logic                                last_pixel;
    logic signed [(W*NUM_CORES)-1:0]     c_r;
    logic signed [(W*NUM_CORES)-1:0]     c_i;
    logic signed [(W*NUM_CORES)-1:0]     z0_r;
    logic signed [(W*NUM_CORES)-1:0]     z0_i;
    logic [(ITER_W*NUM_CORES)-1:0]       out_max_iter;
    logic [(MODE_W*NUM_CORES)-1:0]       out_mode;
    logic [(SEQ_W*NUM_CORES)-1:0]        out_seq;

    // AXI-Lite signals.
    logic [4:0]  awaddr;
    logic [2:0]  awprot;
    logic        awvalid;
    logic        awready;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wvalid;
    logic        wready;
    logic [1:0]  bresp;
    logic        bvalid;
    logic        bready;
    logic [4:0]  araddr;
    logic [2:0]  arprot;
    logic        arvalid;
    logic        arready;
    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid;
    logic        rready;

    pixel_scheduler_top #(
        .NUM_CORES(NUM_CORES), .W(W), .SEQ_W(SEQ_W), .ITER_W(ITER_W),
        .MODE_W(MODE_W), .X_RES(X_RES), .Y_RES(Y_RES),
        .C_S00_AXI_DATA_WIDTH(32), .C_S00_AXI_ADDR_WIDTH(5)
    ) dut (
        .in_ready(in_ready), .in_valid(in_valid), .last_pixel(last_pixel),
        .c_r(c_r), .c_i(c_i), .z0_r(z0_r), .z0_i(z0_i),
        .out_max_iter(out_max_iter), .out_mode(out_mode), .out_seq(out_seq),
        .s00_axi_aclk(clk), .s00_axi_aresetn(aresetn),
        .s00_axi_awaddr(awaddr), .s00_axi_awprot(awprot),
        .s00_axi_awvalid(awvalid), .s00_axi_awready(awready),
        .s00_axi_wdata(wdata), .s00_axi_wstrb(wstrb), .s00_axi_wvalid(wvalid),
        .s00_axi_wready(wready), .s00_axi_bresp(bresp), .s00_axi_bvalid(bvalid),
        .s00_axi_bready(bready), .s00_axi_araddr(araddr), .s00_axi_arprot(arprot),
        .s00_axi_arvalid(arvalid), .s00_axi_arready(arready),
        .s00_axi_rdata(rdata), .s00_axi_rresp(rresp), .s00_axi_rvalid(rvalid),
        .s00_axi_rready(rready)
    );

    int fails = 0;

    task automatic tb_check(input bit condition, input string message);
        if (!condition) begin
            fails++;
            $display("[FAIL] %0t: %s", $time, message);
        end
    endtask

    task automatic axi_write(input logic [4:0] addr, input logic [31:0] data);
        begin
            @(posedge clk);
            awaddr  <= addr;
            awprot  <= 3'b000;
            awvalid <= 1'b1;
            wdata   <= data;
            wstrb   <= 4'hF;
            wvalid  <= 1'b1;
            bready  <= 1'b1;

            wait (awready && wready);
            @(posedge clk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;

            wait (bvalid);
            tb_check(bresp == 2'b00, "AXI write response was not OKAY");
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    task automatic axi_read(input logic [4:0] addr, output logic [31:0] data);
        begin
            @(posedge clk);
            araddr  <= addr;
            arprot  <= 3'b000;
            arvalid <= 1'b1;
            rready  <= 1'b1;

            wait (arready);
            @(posedge clk);
            arvalid <= 1'b0;

            wait (rvalid);
            data = rdata;
            tb_check(rresp == 2'b00, "AXI read response was not OKAY");
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    task automatic write_and_check(input logic [4:0] addr, input logic [31:0] data, input string name);
        logic [31:0] read_data;
        begin
            axi_write(addr, data);
            axi_read(addr, read_data);
            tb_check(read_data == data, {"AXI readback mismatch for ", name});
        end
    endtask

    function automatic logic [SEQ_W-1:0] seq_for_valid;
        logic [SEQ_W-1:0] value;
        begin
            value = '0;
            for (int i = 0; i < NUM_CORES; i++) begin
                if (in_valid[i]) begin
                    value = out_seq[(i*SEQ_W) +: SEQ_W];
                end
            end
            seq_for_valid = value;
        end
    endfunction

    function automatic logic signed [W-1:0] cr_for_valid;
        logic signed [W-1:0] value;
        begin
            value = '0;
            for (int i = 0; i < NUM_CORES; i++) begin
                if (in_valid[i]) begin
                    value = c_r[(i*W) +: W];
                end
            end
            cr_for_valid = value;
        end
    endfunction

    function automatic logic signed [W-1:0] ci_for_valid;
        logic signed [W-1:0] value;
        begin
            value = '0;
            for (int i = 0; i < NUM_CORES; i++) begin
                if (in_valid[i]) begin
                    value = c_i[(i*W) +: W];
                end
            end
            ci_for_valid = value;
        end
    endfunction

    int dispatches = 0;
    int last_pulses = 0;
    logic checking_frame;

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            dispatches     <= 0;
            last_pulses    <= 0;
        end
        else if (|in_valid) begin
            tb_check(checking_frame, "scheduler dispatched while reg7[0] was not in run state");

            if (checking_frame) begin
                tb_check($onehot(in_valid), "more than one in_valid bit was asserted");
                tb_check(seq_for_valid() == dispatches[SEQ_W-1:0], "sequence did not increment contiguously");

                if (dispatches < PIXELS) begin
                    int x;
                    int y;
                    logic signed [W-1:0] expected_cr;
                    logic signed [W-1:0] expected_ci;
                    x = dispatches % X_RES;
                    y = dispatches / X_RES;
                    expected_cr = q_from_real(-2.0)   + x * q_from_real(3.0 / 1280.0);
                    expected_ci = q_from_real(-1.125) + y * q_from_real(2.25 / 720.0);
                    tb_check(cr_for_valid() == expected_cr, "c_r did not match configured coordinate ramp");
                    tb_check(ci_for_valid() == expected_ci, "c_i did not match configured coordinate ramp");
                end

                if (last_pixel) begin
                    last_pulses <= last_pulses + 1;
                    tb_check(dispatches == PIXELS-1, "last_pixel was not aligned with final pixel");
                end

                dispatches <= dispatches + 1;
            end
        end
    end

    initial begin
        $display("================================================");
        $display(" pixel_scheduler_axi_tb final 16-core 720p starting");
        $display("================================================");

        in_ready = '1;
        checking_frame = 1'b0;
        awaddr = '0; awprot = '0; awvalid = 1'b0;
        wdata = '0; wstrb = '0; wvalid = 1'b0;
        bready = 1'b0;
        araddr = '0; arprot = '0; arvalid = 1'b0; rready = 1'b0;

        repeat (8) @(posedge clk);
        aresetn <= 1'b1;
        repeat (10) @(posedge clk);

        tb_check(dispatches == 0, "scheduler dispatched before software start/run enable");

        // Register map: reg0 x_jump, reg1 y_jump, reg2 x_min, reg3 y_min,
        // reg4 jul_c_r, reg5 jul_c_i, reg6 {mode[18:16], max_iter[15:0]},
        // reg7[0] run enable.
        write_and_check(5'h00, reg_from_q(q_from_real( 3.0 / 1280.0)), "x_jump");
        write_and_check(5'h04, reg_from_q(q_from_real( 2.25 / 720.0)), "y_jump");
        write_and_check(5'h08, reg_from_q(q_from_real(-2.0)),   "x_min");
        write_and_check(5'h0C, reg_from_q(q_from_real(-1.125)), "y_min");
        write_and_check(5'h10, reg_from_q(q_from_real(-0.8)),   "jul_c_r");
        write_and_check(5'h14, reg_from_q(q_from_real( 0.156)), "jul_c_i");
        write_and_check(5'h18, {13'd0, 3'd0, 16'd256},          "mode_max_iter");

        repeat (5) @(posedge clk);
        tb_check(dispatches == 0, "scheduler dispatched while configured but not started");

        // Start the frame.
        checking_frame = 1'b1;
        axi_write(5'h1C, 32'h0000_0001);

        for (int cycle = 0; cycle < (PIXELS + 2000); cycle++) begin
            @(posedge clk);
            if ((cycle != 0) && ((cycle % 100000) == 0)) begin
                $display("[PROGRESS] AXI scheduler cycle=%0d dispatches=%0d/%0d fails=%0d", cycle, dispatches, PIXELS, fails);
            end
            if (dispatches == PIXELS) begin
                repeat (4) @(posedge clk);
                tb_check(dispatches == PIXELS, "scheduler did not dispatch exactly one frame");
                tb_check(last_pulses == 1, "last_pixel did not pulse exactly once");

                $display("================================================");
                $display(" AXI scheduler summary: dispatches=%0d fails=%0d", dispatches, fails);
                $display("================================================");

                if (fails == 0) begin
                    $display("[PASS] tb completed successfully");
                    $finish;
                end
                else begin
                    $fatal(1, "[FAIL] tb completed with %0d failure(s)", fails);
                end
            end
        end

        $fatal(1, "tb timed out: dispatches=%0d/%0d fails=%0d", dispatches, PIXELS, fails);
    end

endmodule
