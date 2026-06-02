`timescale 1ns / 1ps

module pixel_write_engine_tb;

    localparam int ADDR_W       = 32;
    localparam int DATA_W       = 32;
    localparam int SEQ_W        = 5;
    localparam int X_RES        = 8;
    localparam int Y_RES        = 4;
    localparam int FRAME_PIXELS = X_RES * Y_RES;

    localparam logic [ADDR_W-1:0] FRAMEBUFFER_BASE = 32'h1000_0000;
    localparam int TIMEOUT_CYCLES = 5000;

    logic clk;
    logic rst_n;

    logic              start;
    logic              enable;
    logic              soft_reset;
    logic [ADDR_W-1:0] framebuffer_base;

    logic             in_valid;
    logic             in_ready;
    logic [SEQ_W-1:0] in_pixel_index;
    logic [7:0]       in_r;
    logic [7:0]       in_g;
    logic [7:0]       in_b;

    logic        busy;
    logic        done;
    logic        idle;
    logic        error;
    logic [31:0] pixels_accepted;
    logic [31:0] pixels_written;
    logic [31:0] write_errors;

    logic [ADDR_W-1:0]     m_axi_awaddr;
    logic [7:0]            m_axi_awlen;
    logic [2:0]            m_axi_awsize;
    logic [1:0]            m_axi_awburst;
    logic                  m_axi_awvalid;
    logic                  m_axi_awready;

    logic [DATA_W-1:0]     m_axi_wdata;
    logic [(DATA_W/8)-1:0] m_axi_wstrb;
    logic                  m_axi_wlast;
    logic                  m_axi_wvalid;
    logic                  m_axi_wready;

    logic [1:0]            m_axi_bresp;
    logic                  m_axi_bvalid;
    logic                  m_axi_bready;

    int unsigned tests;
    int unsigned fails;

    pixel_write_engine #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .SEQ_W(SEQ_W),
        .X_RES(X_RES),
        .Y_RES(Y_RES),
        .FRAME_PIXELS(FRAME_PIXELS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .enable(enable),
        .soft_reset(soft_reset),
        .framebuffer_base(framebuffer_base),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_pixel_index(in_pixel_index),
        .in_r(in_r),
        .in_g(in_g),
        .in_b(in_b),
        .busy(busy),
        .done(done),
        .idle(idle),
        .error(error),
        .pixels_accepted(pixels_accepted),
        .pixels_written(pixels_written),
        .write_errors(write_errors),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic tb_check(input bit condition, input string message);
        begin
            tests++;
            if (!condition) begin
                fails++;
                $display("[FAIL] %0t: %s", $time, message);
            end
        end
    endtask

    function automatic logic [31:0] expected_word(input int unsigned pixel_index);
        logic [7:0] r;
        logic [7:0] g;
        logic [7:0] b;
        begin
            r = pixel_index + 8'h10;
            g = (pixel_index * 3) + 8'h20;
            b = 8'hFF - pixel_index;
            expected_word = {8'h00, r, g, b};
        end
    endfunction

    function automatic int unsigned scrambled_index(input int unsigned n);
        scrambled_index = ((n * 7) + 3) % FRAME_PIXELS;
    endfunction

    // Lightweight AXI write target

    logic [31:0] mem       [0:FRAME_PIXELS-1];
    logic        mem_valid [0:FRAME_PIXELS-1];

    logic model_reset;
    logic hold_b_response;

    logic [31:0] cycle_count;
    logic        have_aw_q;
    logic        have_w_q;
    logic        resp_active_q;
    logic [1:0]  b_delay_q;

    logic [ADDR_W-1:0] captured_awaddr_q;
    logic [31:0]       captured_wdata_q;
    logic [3:0]        captured_wstrb_q;

    int unsigned axi_write_count;
    int signed   error_on_write;

    wire aw_allow = ((cycle_count % 5) != 2);
    wire w_allow  = ((cycle_count % 7) != 3) && ((cycle_count % 7) != 4);

    assign m_axi_awready = rst_n && !model_reset && !have_aw_q && !resp_active_q && !m_axi_bvalid && aw_allow;
    assign m_axi_wready  = rst_n && !model_reset && !have_w_q  && !resp_active_q && !m_axi_bvalid && w_allow;

    task automatic store_axi_write(
        input logic [ADDR_W-1:0] addr,
        input logic [31:0]       data,
        input logic [3:0]        strb
    );
        logic [ADDR_W-1:0] offset;
        int unsigned pixel;
        begin
            offset = addr - FRAMEBUFFER_BASE;
            pixel  = offset >> 2;

            tb_check(addr >= FRAMEBUFFER_BASE,
                     $sformatf("write address below framebuffer base: addr=0x%08h", addr));
            tb_check(offset[1:0] == 2'b00,
                     $sformatf("write address is not 32-bit aligned: addr=0x%08h", addr));
            tb_check(pixel < FRAME_PIXELS,
                     $sformatf("write address outside test framebuffer: addr=0x%08h pixel=%0d", addr, pixel));
            tb_check(strb == 4'hF,
                     $sformatf("unexpected WSTRB: got 0x%0h", strb));

            if (pixel < FRAME_PIXELS) begin
                mem[pixel]       = data;
                mem_valid[pixel] = 1'b1;
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n || model_reset) begin
            cycle_count       <= 32'd0;
            have_aw_q         <= 1'b0;
            have_w_q          <= 1'b0;
            resp_active_q     <= 1'b0;
            b_delay_q         <= 2'd0;
            captured_awaddr_q <= '0;
            captured_wdata_q  <= '0;
            captured_wstrb_q  <= '0;
            m_axi_bvalid      <= 1'b0;
            m_axi_bresp       <= 2'b00;
            axi_write_count   <= 0;

            for (int i = 0; i < FRAME_PIXELS; i++) begin
                mem[i]       <= 32'hDEAD_BEEF;
                mem_valid[i] <= 1'b0;
            end
        end
        else begin
            cycle_count <= cycle_count + 32'd1;

            if (m_axi_awvalid && m_axi_awready) begin
                tb_check(m_axi_awlen == 8'd0, "AWLEN should be zero for a single-beat write");
                tb_check(m_axi_awsize == 3'b010, "AWSIZE should be 4 bytes");
                tb_check(m_axi_awburst == 2'b01, "AWBURST should be INCR");
                captured_awaddr_q <= m_axi_awaddr;
                have_aw_q <= 1'b1;
            end

            if (m_axi_wvalid && m_axi_wready) begin
                tb_check(m_axi_wlast == 1'b1, "WLAST should be asserted for single-beat write");
                captured_wdata_q <= m_axi_wdata;
                captured_wstrb_q <= m_axi_wstrb;
                have_w_q <= 1'b1;
            end

            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid  <= 1'b0;
                m_axi_bresp   <= 2'b00;
                resp_active_q <= 1'b0;
                have_aw_q     <= 1'b0;
                have_w_q      <= 1'b0;
                axi_write_count <= axi_write_count + 1;
            end
            else if (resp_active_q && !m_axi_bvalid) begin
                if (!hold_b_response) begin
                    if (b_delay_q == 0) begin
                        m_axi_bvalid <= 1'b1;
                        if (int'(axi_write_count) == error_on_write) begin
                            m_axi_bresp <= 2'b10;
                        end
                        else begin
                            m_axi_bresp <= 2'b00;
                        end
                    end
                    else begin
                        b_delay_q <= b_delay_q - 1'b1;
                    end
                end
            end
            else if (have_aw_q && have_w_q && !resp_active_q && !m_axi_bvalid) begin
                store_axi_write(captured_awaddr_q, captured_wdata_q, captured_wstrb_q);
                resp_active_q <= 1'b1;
                b_delay_q <= axi_write_count[1:0];
            end
        end
    end

    // Test helpers

    task automatic apply_reset;
        begin
            rst_n            = 1'b0;
            model_reset      = 1'b1;
            start            = 1'b0;
            enable           = 1'b0;
            soft_reset       = 1'b0;
            framebuffer_base = FRAMEBUFFER_BASE;
            in_valid         = 1'b0;
            in_pixel_index   = '0;
            in_r             = '0;
            in_g             = '0;
            in_b             = '0;
            hold_b_response  = 1'b0;
            error_on_write   = -1;

            repeat (5) @(posedge clk);
            #1;
            tb_check(idle == 1'b1, "writer should report idle after reset");
            tb_check(done == 1'b0, "done should clear on reset");
            tb_check(error == 1'b0, "error should clear on reset");

            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            #1;
            model_reset = 1'b0;
            enable = 1'b1;
        end
    endtask

    task automatic reset_axi_model(input int signed error_index);
        begin
            @(negedge clk);
            model_reset = 1'b1;
            hold_b_response = 1'b0;
            error_on_write = error_index;
            @(posedge clk);
            #1;
            @(negedge clk);
            model_reset = 1'b0;
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(posedge clk);
            #1;
            start = 1'b0;
            tb_check(busy == 1'b1, "writer should become busy after start");
            tb_check(done == 1'b0, "done should be low after start");
            tb_check(in_ready == enable, "in_ready should follow enable when idle and active");
        end
    endtask

    task automatic send_pixel(input int unsigned pixel_index);
        logic [31:0] word;
        begin
            word = expected_word(pixel_index);

            @(negedge clk);
            in_pixel_index = pixel_index[SEQ_W-1:0];
            in_r = word[23:16];
            in_g = word[15:8];
            in_b = word[7:0];
            in_valid = 1'b1;

            while (!in_ready) begin
                @(negedge clk);
            end

            @(posedge clk);
            #1;
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic send_scrambled_frame(input string label);
        int unsigned pixel_index;
        begin
            $display("[RUN] %s: sending %0d unordered pixels", label, FRAME_PIXELS);
            for (int i = 0; i < FRAME_PIXELS; i++) begin
                pixel_index = scrambled_index(i);
                send_pixel(pixel_index);
            end
        end
    endtask

    task automatic wait_for_done(input string label);
        int cycles;
        bit seen_done;
        begin
            cycles = 0;
            seen_done = 1'b0;

            while (!seen_done && (cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;
                cycles++;
                if (done) begin
                    seen_done = 1'b1;
                end
            end

            tb_check(seen_done, {label, ": writer reached done"});
            tb_check(pixels_accepted == FRAME_PIXELS,
                     $sformatf("%s: pixels_accepted should be %0d, got %0d", label, FRAME_PIXELS, pixels_accepted));
            tb_check(pixels_written == FRAME_PIXELS,
                     $sformatf("%s: pixels_written should be %0d, got %0d", label, FRAME_PIXELS, pixels_written));
            tb_check(busy == 1'b0, {label, ": busy should clear after done"});
        end
    endtask

    task automatic wait_for_idle(input string label);
        int cycles;
        bit seen_idle;
        begin
            cycles = 0;
            seen_idle = 1'b0;

            while (!seen_idle && (cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;
                cycles++;
                if (idle) begin
                    seen_idle = 1'b1;
                end
            end

            tb_check(seen_idle, {label, ": writer returned to idle"});
        end
    endtask

    task automatic check_memory(input string label);
        begin
            for (int i = 0; i < FRAME_PIXELS; i++) begin
                tb_check(mem_valid[i], $sformatf("%s: pixel %0d was written", label, i));
                if (mem_valid[i]) begin
                    tb_check(mem[i] == expected_word(i),
                             $sformatf("%s: pixel %0d data mismatch expected=0x%08h got=0x%08h",
                                       label, i, expected_word(i), mem[i]));
                end
            end
        end
    endtask

    task automatic run_clean_frame;
        begin
            $display("------------------------------------------------------------");
            $display("Clean unordered framebuffer write test");
            $display("------------------------------------------------------------");
            reset_axi_model(-1);
            pulse_start();
            send_scrambled_frame("clean frame");
            wait_for_done("clean frame");
            tb_check(error == 1'b0, "clean frame should not set error");
            tb_check(write_errors == 32'd0, "clean frame should have zero write_errors");
            check_memory("clean frame");
        end
    endtask

    task automatic run_error_frame;
        begin
            $display("------------------------------------------------------------");
            $display("AXI BRESP error accounting test");
            $display("------------------------------------------------------------");
            reset_axi_model(5);
            pulse_start();
            send_scrambled_frame("error frame");
            wait_for_done("error frame");
            tb_check(error == 1'b1, "error frame should set error");
            tb_check(write_errors == 32'd1,
                     $sformatf("error frame should count one write error, got %0d", write_errors));
            check_memory("error frame");
        end
    endtask

    task automatic run_enable_gate_test;
        begin
            $display("------------------------------------------------------------");
            $display("Enable gate test");
            $display("------------------------------------------------------------");
            reset_axi_model(-1);

            @(negedge clk);
            enable = 1'b0;
            pulse_start();
            tb_check(in_ready == 1'b0, "in_ready should be low while enable is low");

            repeat (5) @(posedge clk);
            #1;
            tb_check(pixels_accepted == 32'd0, "writer should not accept pixels while enable is low");

            @(negedge clk);
            enable = 1'b1;
            send_scrambled_frame("enable gate frame");
            wait_for_done("enable gate frame");
            tb_check(error == 1'b0, "enable gate frame should not set error");
            check_memory("enable gate frame");
        end
    endtask

    task automatic run_soft_reset_drain_test;
        int cycles;
        bit response_started;
        begin
            $display("------------------------------------------------------------");
            $display("Soft reset drains in-flight AXI transaction test");
            $display("------------------------------------------------------------");
            reset_axi_model(-1);
            hold_b_response = 1'b1;
            pulse_start();
            send_pixel(5);

            cycles = 0;
            response_started = 1'b0;
            while (!response_started && (cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;
                cycles++;
                if (resp_active_q) begin
                    response_started = 1'b1;
                end
            end
            tb_check(response_started, "AXI model captured write before soft reset");

            @(negedge clk);
            soft_reset = 1'b1;
            @(posedge clk);
            #1;
            soft_reset = 1'b0;
            tb_check(busy == 1'b1, "soft_reset should not abandon an in-flight write immediately");

            @(negedge clk);
            hold_b_response = 1'b0;
            wait_for_idle("soft reset drain");
            tb_check(done == 1'b0, "soft reset should clear done");
            tb_check(error == 1'b0, "soft reset should clear error");
            tb_check(pixels_accepted == 32'd0, "soft reset should clear pixels_accepted");
            tb_check(pixels_written == 32'd0, "soft reset should clear pixels_written");
            tb_check(write_errors == 32'd0, "soft reset should clear write_errors");
        end
    endtask

    initial begin
        tests = 0;
        fails = 0;

        $display("============================================================");
        $display(" pixel_write_engine_tb: direct framebuffer writer unit test");
        $display(" X_RES=%0d Y_RES=%0d FRAME_PIXELS=%0d", X_RES, Y_RES, FRAME_PIXELS);
        $display("============================================================");

        apply_reset();
        run_clean_frame();
        run_error_frame();
        run_enable_gate_test();
        run_soft_reset_drain_test();

        $display("============================================================");
        $display(" pixel_write_engine_tb summary: tests=%0d fails=%0d", tests, fails);
        $display("============================================================");

        if (fails == 0) begin
            $display("[TB PASS] pixel_write_engine_tb completed successfully");
            $finish;
        end
        else begin
            $fatal(1, "[TB FAIL] pixel_write_engine_tb completed with %0d failure(s)", fails);
        end
    end

endmodule
