`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench: pixel_write_engine_top_tb
// Tool: Vivado 2023.2 / XSim
//
// Self-checking integration test for:
//   pixel_write_engine_top -> pixel_write_engine_AXI -> pixel_write_engine
//
// Uses AXI-Lite tasks to configure the wrapper and a lightweight AXI write
// target to model DDR writes. The framebuffer is deliberately tiny so the test
// runs quickly while still checking unordered pixel-index writes.
//////////////////////////////////////////////////////////////////////////////////

module pixel_write_engine_top_tb;

    localparam int ADDR_W       = 32;
    localparam int DATA_W       = 32;
    localparam int SEQ_W        = 5;
    localparam int X_RES        = 8;
    localparam int Y_RES        = 4;
    localparam int FRAME_PIXELS = X_RES * Y_RES;

    localparam int S_AXI_DATA_W = 32;
    localparam int S_AXI_ADDR_W = 5;
    localparam int M_AXI_ADDR_W = 32;
    localparam int M_AXI_DATA_W = 32;

    localparam logic [ADDR_W-1:0] FRAMEBUFFER_BASE = 32'h1000_0000;
    localparam int TIMEOUT_CYCLES = 5000;
    localparam logic [15:0] X_RES_16 = X_RES;
    localparam logic [15:0] Y_RES_16 = Y_RES;
    localparam logic [31:0] EXPECTED_GEOMETRY = {Y_RES_16, X_RES_16};

    localparam logic [S_AXI_ADDR_W-1:0] A_CONTROL          = 5'h00;
    localparam logic [S_AXI_ADDR_W-1:0] A_STATUS           = 5'h04;
    localparam logic [S_AXI_ADDR_W-1:0] A_FRAMEBUFFER_BASE = 5'h08;
    localparam logic [S_AXI_ADDR_W-1:0] A_PIXELS_ACCEPTED  = 5'h0C;
    localparam logic [S_AXI_ADDR_W-1:0] A_PIXELS_WRITTEN   = 5'h10;
    localparam logic [S_AXI_ADDR_W-1:0] A_WRITE_ERRORS     = 5'h14;
    localparam logic [S_AXI_ADDR_W-1:0] A_FRAME_PIXELS     = 5'h18;
    localparam logic [S_AXI_ADDR_W-1:0] A_GEOMETRY         = 5'h1C;

    logic clk;
    logic rst_n;

    logic             in_valid;
    logic             in_ready;
    logic [SEQ_W-1:0] in_pixel_index;
    logic [7:0]       in_r;
    logic [7:0]       in_g;
    logic [7:0]       in_b;

    logic [S_AXI_ADDR_W-1:0]     s00_axi_awaddr;
    logic [2:0]                  s00_axi_awprot;
    logic                        s00_axi_awvalid;
    logic                        s00_axi_awready;
    logic [S_AXI_DATA_W-1:0]     s00_axi_wdata;
    logic [(S_AXI_DATA_W/8)-1:0] s00_axi_wstrb;
    logic                        s00_axi_wvalid;
    logic                        s00_axi_wready;
    logic [1:0]                  s00_axi_bresp;
    logic                        s00_axi_bvalid;
    logic                        s00_axi_bready;
    logic [S_AXI_ADDR_W-1:0]     s00_axi_araddr;
    logic [2:0]                  s00_axi_arprot;
    logic                        s00_axi_arvalid;
    logic                        s00_axi_arready;
    logic [S_AXI_DATA_W-1:0]     s00_axi_rdata;
    logic [1:0]                  s00_axi_rresp;
    logic                        s00_axi_rvalid;
    logic                        s00_axi_rready;

    logic [M_AXI_ADDR_W-1:0]     m00_axi_awaddr;
    logic [7:0]                  m00_axi_awlen;
    logic [2:0]                  m00_axi_awsize;
    logic [1:0]                  m00_axi_awburst;
    logic [2:0]                  m00_axi_awprot;
    logic [3:0]                  m00_axi_awcache;
    logic                        m00_axi_awlock;
    logic [3:0]                  m00_axi_awqos;
    logic                        m00_axi_awvalid;
    logic                        m00_axi_awready;

    logic [M_AXI_DATA_W-1:0]     m00_axi_wdata;
    logic [(M_AXI_DATA_W/8)-1:0] m00_axi_wstrb;
    logic                        m00_axi_wlast;
    logic                        m00_axi_wvalid;
    logic                        m00_axi_wready;

    logic [1:0]                  m00_axi_bresp;
    logic                        m00_axi_bvalid;
    logic                        m00_axi_bready;

    logic [M_AXI_ADDR_W-1:0]     m00_axi_araddr;
    logic [7:0]                  m00_axi_arlen;
    logic [2:0]                  m00_axi_arsize;
    logic [1:0]                  m00_axi_arburst;
    logic [2:0]                  m00_axi_arprot;
    logic [3:0]                  m00_axi_arcache;
    logic                        m00_axi_arlock;
    logic [3:0]                  m00_axi_arqos;
    logic                        m00_axi_arvalid;
    logic                        m00_axi_arready;

    logic [M_AXI_DATA_W-1:0]     m00_axi_rdata;
    logic [1:0]                  m00_axi_rresp;
    logic                        m00_axi_rlast;
    logic                        m00_axi_rvalid;
    logic                        m00_axi_rready;

    int unsigned tests;
    int unsigned fails;

    pixel_write_engine_top #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .SEQ_W(SEQ_W),
        .X_RES(X_RES),
        .Y_RES(Y_RES),
        .FRAME_PIXELS(FRAME_PIXELS),
        .C_S00_AXI_DATA_WIDTH(S_AXI_DATA_W),
        .C_S00_AXI_ADDR_WIDTH(S_AXI_ADDR_W),
        .C_M00_AXI_ADDR_WIDTH(M_AXI_ADDR_W),
        .C_M00_AXI_DATA_WIDTH(M_AXI_DATA_W)
    ) dut (
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_pixel_index(in_pixel_index),
        .in_r(in_r),
        .in_g(in_g),
        .in_b(in_b),

        .s00_axi_aclk(clk),
        .s00_axi_aresetn(rst_n),
        .s00_axi_awaddr(s00_axi_awaddr),
        .s00_axi_awprot(s00_axi_awprot),
        .s00_axi_awvalid(s00_axi_awvalid),
        .s00_axi_awready(s00_axi_awready),
        .s00_axi_wdata(s00_axi_wdata),
        .s00_axi_wstrb(s00_axi_wstrb),
        .s00_axi_wvalid(s00_axi_wvalid),
        .s00_axi_wready(s00_axi_wready),
        .s00_axi_bresp(s00_axi_bresp),
        .s00_axi_bvalid(s00_axi_bvalid),
        .s00_axi_bready(s00_axi_bready),
        .s00_axi_araddr(s00_axi_araddr),
        .s00_axi_arprot(s00_axi_arprot),
        .s00_axi_arvalid(s00_axi_arvalid),
        .s00_axi_arready(s00_axi_arready),
        .s00_axi_rdata(s00_axi_rdata),
        .s00_axi_rresp(s00_axi_rresp),
        .s00_axi_rvalid(s00_axi_rvalid),
        .s00_axi_rready(s00_axi_rready),

        .m00_axi_awaddr(m00_axi_awaddr),
        .m00_axi_awlen(m00_axi_awlen),
        .m00_axi_awsize(m00_axi_awsize),
        .m00_axi_awburst(m00_axi_awburst),
        .m00_axi_awprot(m00_axi_awprot),
        .m00_axi_awcache(m00_axi_awcache),
        .m00_axi_awlock(m00_axi_awlock),
        .m00_axi_awqos(m00_axi_awqos),
        .m00_axi_awvalid(m00_axi_awvalid),
        .m00_axi_awready(m00_axi_awready),
        .m00_axi_wdata(m00_axi_wdata),
        .m00_axi_wstrb(m00_axi_wstrb),
        .m00_axi_wlast(m00_axi_wlast),
        .m00_axi_wvalid(m00_axi_wvalid),
        .m00_axi_wready(m00_axi_wready),
        .m00_axi_bresp(m00_axi_bresp),
        .m00_axi_bvalid(m00_axi_bvalid),
        .m00_axi_bready(m00_axi_bready),
        .m00_axi_araddr(m00_axi_araddr),
        .m00_axi_arlen(m00_axi_arlen),
        .m00_axi_arsize(m00_axi_arsize),
        .m00_axi_arburst(m00_axi_arburst),
        .m00_axi_arprot(m00_axi_arprot),
        .m00_axi_arcache(m00_axi_arcache),
        .m00_axi_arlock(m00_axi_arlock),
        .m00_axi_arqos(m00_axi_arqos),
        .m00_axi_arvalid(m00_axi_arvalid),
        .m00_axi_arready(m00_axi_arready),
        .m00_axi_rdata(m00_axi_rdata),
        .m00_axi_rresp(m00_axi_rresp),
        .m00_axi_rlast(m00_axi_rlast),
        .m00_axi_rvalid(m00_axi_rvalid),
        .m00_axi_rready(m00_axi_rready)
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

    // -------------------------------------------------------------------------
    // AXI-Lite master tasks
    // -------------------------------------------------------------------------

    task automatic axi_lite_write(
        input logic [S_AXI_ADDR_W-1:0] addr,
        input logic [31:0]             data
    );
        int cycles;
        begin
            @(negedge clk);
            s00_axi_awaddr  = addr;
            s00_axi_awprot  = 3'b000;
            s00_axi_awvalid = 1'b1;
            s00_axi_wdata   = data;
            s00_axi_wstrb   = 4'hF;
            s00_axi_wvalid  = 1'b1;
            s00_axi_bready  = 1'b1;

            cycles = 0;
            while (!(s00_axi_awready && s00_axi_wready) && (cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;
                cycles++;
            end
            tb_check(cycles < TIMEOUT_CYCLES, $sformatf("AXI-Lite write address/data ready timeout addr=0x%02h", addr));

            @(posedge clk);
            #1;
            s00_axi_awvalid = 1'b0;
            s00_axi_wvalid  = 1'b0;

            cycles = 0;
            while (!s00_axi_bvalid && (cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;
                cycles++;
            end
            tb_check(cycles < TIMEOUT_CYCLES, $sformatf("AXI-Lite write response timeout addr=0x%02h", addr));
            tb_check(s00_axi_bresp == 2'b00, $sformatf("AXI-Lite write BRESP not OKAY addr=0x%02h", addr));

            @(posedge clk);
            #1;
            s00_axi_bready = 1'b0;
        end
    endtask

    task automatic axi_lite_read(
        input  logic [S_AXI_ADDR_W-1:0] addr,
        output logic [31:0]             data
    );
        int cycles;
        begin
            @(negedge clk);
            s00_axi_araddr  = addr;
            s00_axi_arprot  = 3'b000;
            s00_axi_arvalid = 1'b1;
            s00_axi_rready  = 1'b1;

            cycles = 0;
            while (!s00_axi_arready && (cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;
                cycles++;
            end
            tb_check(cycles < TIMEOUT_CYCLES, $sformatf("AXI-Lite read address ready timeout addr=0x%02h", addr));

            @(posedge clk);
            #1;
            s00_axi_arvalid = 1'b0;

            cycles = 0;
            while (!s00_axi_rvalid && (cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;
                cycles++;
            end
            tb_check(cycles < TIMEOUT_CYCLES, $sformatf("AXI-Lite read data timeout addr=0x%02h", addr));
            tb_check(s00_axi_rresp == 2'b00, $sformatf("AXI-Lite read RRESP not OKAY addr=0x%02h", addr));
            data = s00_axi_rdata;

            @(posedge clk);
            #1;
            s00_axi_rready = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Lightweight AXI write target
    // -------------------------------------------------------------------------

    logic [31:0] mem       [0:FRAME_PIXELS-1];
    logic        mem_valid [0:FRAME_PIXELS-1];

    logic model_reset;
    logic hold_b_response;
    logic [31:0] cycle_count;
    logic have_aw_q;
    logic have_w_q;
    logic resp_active_q;
    logic [1:0] b_delay_q;
    logic [M_AXI_ADDR_W-1:0] captured_awaddr_q;
    logic [31:0] captured_wdata_q;
    logic [3:0] captured_wstrb_q;

    int unsigned axi_write_count;
    int signed error_on_write;

    wire aw_allow = ((cycle_count % 5) != 2);
    wire w_allow  = ((cycle_count % 7) != 3) && ((cycle_count % 7) != 4);

    assign m00_axi_awready = rst_n && !model_reset && !have_aw_q && !resp_active_q && !m00_axi_bvalid && aw_allow;
    assign m00_axi_wready  = rst_n && !model_reset && !have_w_q  && !resp_active_q && !m00_axi_bvalid && w_allow;

    assign m00_axi_arready = 1'b1;
    assign m00_axi_rdata   = '0;
    assign m00_axi_rresp   = 2'b00;
    assign m00_axi_rlast   = 1'b0;
    assign m00_axi_rvalid  = 1'b0;

    task automatic store_axi_write(
        input logic [M_AXI_ADDR_W-1:0] addr,
        input logic [31:0]             data,
        input logic [3:0]              strb
    );
        logic [M_AXI_ADDR_W-1:0] offset;
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
            m00_axi_bvalid    <= 1'b0;
            m00_axi_bresp     <= 2'b00;
            axi_write_count   <= 0;

            for (int i = 0; i < FRAME_PIXELS; i++) begin
                mem[i]       <= 32'hDEAD_BEEF;
                mem_valid[i] <= 1'b0;
            end
        end
        else begin
            cycle_count <= cycle_count + 32'd1;

            tb_check(m00_axi_arvalid == 1'b0, "top should keep AXI read address channel inactive");
            tb_check(m00_axi_rready  == 1'b0, "top should keep AXI read data channel inactive");

            if (m00_axi_awvalid && m00_axi_awready) begin
                tb_check(m00_axi_awlen   == 8'd0,   "AWLEN should be zero for single-beat write");
                tb_check(m00_axi_awsize  == 3'b010, "AWSIZE should be 4 bytes");
                tb_check(m00_axi_awburst == 2'b01,  "AWBURST should be INCR");
                tb_check(m00_axi_awprot  == 3'b000, "AWPROT tie-off mismatch");
                tb_check(m00_axi_awcache == 4'b0011, "AWCACHE tie-off mismatch");
                tb_check(m00_axi_awlock  == 1'b0,   "AWLOCK tie-off mismatch");
                tb_check(m00_axi_awqos   == 4'b0000, "AWQOS tie-off mismatch");
                captured_awaddr_q <= m00_axi_awaddr;
                have_aw_q <= 1'b1;
            end

            if (m00_axi_wvalid && m00_axi_wready) begin
                tb_check(m00_axi_wlast == 1'b1, "WLAST should be asserted for single-beat write");
                captured_wdata_q <= m00_axi_wdata;
                captured_wstrb_q <= m00_axi_wstrb;
                have_w_q <= 1'b1;
            end

            if (m00_axi_bvalid && m00_axi_bready) begin
                m00_axi_bvalid  <= 1'b0;
                m00_axi_bresp   <= 2'b00;
                resp_active_q   <= 1'b0;
                have_aw_q       <= 1'b0;
                have_w_q        <= 1'b0;
                axi_write_count <= axi_write_count + 1;
            end
            else if (resp_active_q && !m00_axi_bvalid) begin
                if (!hold_b_response) begin
                    if (b_delay_q == 0) begin
                        m00_axi_bvalid <= 1'b1;
                        if (int'(axi_write_count) == error_on_write) begin
                            m00_axi_bresp <= 2'b10;
                        end
                        else begin
                            m00_axi_bresp <= 2'b00;
                        end
                    end
                    else begin
                        b_delay_q <= b_delay_q - 1'b1;
                    end
                end
            end
            else if (have_aw_q && have_w_q && !resp_active_q && !m00_axi_bvalid) begin
                store_axi_write(captured_awaddr_q, captured_wdata_q, captured_wstrb_q);
                resp_active_q <= 1'b1;
                b_delay_q <= axi_write_count[1:0];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    task automatic apply_reset;
        logic [31:0] rd;
        begin
            rst_n = 1'b0;
            model_reset = 1'b1;
            hold_b_response = 1'b0;
            error_on_write = -1;

            in_valid = 1'b0;
            in_pixel_index = '0;
            in_r = '0;
            in_g = '0;
            in_b = '0;

            s00_axi_awaddr = '0;
            s00_axi_awprot = '0;
            s00_axi_awvalid = 1'b0;
            s00_axi_wdata = '0;
            s00_axi_wstrb = '0;
            s00_axi_wvalid = 1'b0;
            s00_axi_bready = 1'b0;
            s00_axi_araddr = '0;
            s00_axi_arprot = '0;
            s00_axi_arvalid = 1'b0;
            s00_axi_rready = 1'b0;

            repeat (5) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            #1;
            model_reset = 1'b0;

            axi_lite_read(A_STATUS, rd);
            tb_check(rd[3] == 1'b1, "status.idle should be high after reset");
            tb_check(rd[2:0] == 3'b000, "busy/done/error should be clear after reset");

            axi_lite_read(A_FRAME_PIXELS, rd);
            tb_check(rd == FRAME_PIXELS, $sformatf("FRAME_PIXELS readback expected %0d got %0d", FRAME_PIXELS, rd));

            axi_lite_read(A_GEOMETRY, rd);
            tb_check(rd == EXPECTED_GEOMETRY,
                     $sformatf("GEOMETRY readback mismatch expected=0x%08h got=0x%08h", EXPECTED_GEOMETRY, rd));
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

    task automatic configure_base_and_enable;
        logic [31:0] rd;
        begin
            axi_lite_write(A_FRAMEBUFFER_BASE, FRAMEBUFFER_BASE);
            axi_lite_read(A_FRAMEBUFFER_BASE, rd);
            tb_check(rd == FRAMEBUFFER_BASE, $sformatf("FRAMEBUFFER_BASE readback mismatch got 0x%08h", rd));

            axi_lite_write(A_CONTROL, 32'h0000_0002);
            axi_lite_read(A_CONTROL, rd);
            tb_check(rd[1] == 1'b1, "CONTROL enable bit should read back high");
            tb_check(rd[0] == 1'b0, "CONTROL start bit should read back as zero");
        end
    endtask

    task automatic start_writer_with_enable(input bit enable_value);
        logic [31:0] rd;
        begin
            axi_lite_write(A_CONTROL, enable_value ? 32'h0000_0003 : 32'h0000_0001);
            repeat (3) @(posedge clk);
            #1;
            axi_lite_read(A_STATUS, rd);
            tb_check(rd[0] == 1'b1, "status.busy should be high after start");
            tb_check(rd[1] == 1'b0, "status.done should be low immediately after start");
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

    task automatic wait_for_done(input string label, input bit expect_error, input int unsigned exp_errors);
        int cycles;
        logic [31:0] status;
        logic [31:0] rd;
        bit seen_done;
        begin
            cycles = 0;
            seen_done = 1'b0;

            while (!seen_done && (cycles < TIMEOUT_CYCLES)) begin
                axi_lite_read(A_STATUS, status);
                if (status[1]) begin
                    seen_done = 1'b1;
                end
                cycles++;
            end

            tb_check(seen_done, {label, ": status.done reached"});
            tb_check(status[0] == 1'b0, {label, ": status.busy should clear after done"});
            tb_check(status[2] == expect_error, {label, ": status.error mismatch"});

            axi_lite_read(A_PIXELS_ACCEPTED, rd);
            tb_check(rd == FRAME_PIXELS,
                     $sformatf("%s: PIXELS_ACCEPTED expected %0d got %0d", label, FRAME_PIXELS, rd));

            axi_lite_read(A_PIXELS_WRITTEN, rd);
            tb_check(rd == FRAME_PIXELS,
                     $sformatf("%s: PIXELS_WRITTEN expected %0d got %0d", label, FRAME_PIXELS, rd));

            axi_lite_read(A_WRITE_ERRORS, rd);
            tb_check(rd == exp_errors,
                     $sformatf("%s: WRITE_ERRORS expected %0d got %0d", label, exp_errors, rd));
        end
    endtask

    task automatic wait_for_idle(input string label);
        int cycles;
        logic [31:0] status;
        bit seen_idle;
        begin
            cycles = 0;
            seen_idle = 1'b0;

            while (!seen_idle && (cycles < TIMEOUT_CYCLES)) begin
                axi_lite_read(A_STATUS, status);
                if (status[3]) begin
                    seen_idle = 1'b1;
                end
                cycles++;
            end

            tb_check(seen_idle, {label, ": status.idle reached"});
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
            $display("Top/AXI clean unordered framebuffer write test");
            $display("------------------------------------------------------------");
            reset_axi_model(-1);
            configure_base_and_enable();
            start_writer_with_enable(1'b1);
            send_scrambled_frame("clean frame");
            wait_for_done("clean frame", 1'b0, 0);
            check_memory("clean frame");
        end
    endtask

    task automatic run_error_frame;
        begin
            $display("------------------------------------------------------------");
            $display("Top/AXI BRESP error accounting test");
            $display("------------------------------------------------------------");
            reset_axi_model(5);
            configure_base_and_enable();
            start_writer_with_enable(1'b1);
            send_scrambled_frame("error frame");
            wait_for_done("error frame", 1'b1, 1);
            check_memory("error frame");
        end
    endtask

    task automatic run_enable_gate_test;
        logic [31:0] rd;
        begin
            $display("------------------------------------------------------------");
            $display("Top/AXI enable gate test");
            $display("------------------------------------------------------------");
            reset_axi_model(-1);
            axi_lite_write(A_FRAMEBUFFER_BASE, FRAMEBUFFER_BASE);
            start_writer_with_enable(1'b0);

            repeat (5) @(posedge clk);
            #1;
            tb_check(in_ready == 1'b0, "in_ready should remain low when enable is low");
            axi_lite_read(A_PIXELS_ACCEPTED, rd);
            tb_check(rd == 32'd0, "PIXELS_ACCEPTED should stay zero while enable is low");

            axi_lite_write(A_CONTROL, 32'h0000_0002);
            axi_lite_read(A_CONTROL, rd);
            tb_check(rd[1] == 1'b1, "enable should become high after CONTROL write");

            send_scrambled_frame("enable gate frame");
            wait_for_done("enable gate frame", 1'b0, 0);
            check_memory("enable gate frame");
        end
    endtask

    task automatic run_soft_reset_drain_test;
        int cycles;
        bit response_started;
        logic [31:0] rd;
        begin
            $display("------------------------------------------------------------");
            $display("Top/AXI soft_reset drains in-flight transaction test");
            $display("------------------------------------------------------------");
            reset_axi_model(-1);
            configure_base_and_enable();
            hold_b_response = 1'b1;
            start_writer_with_enable(1'b1);
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
            tb_check(response_started, "AXI write target captured write before soft_reset command");

            axi_lite_write(A_CONTROL, 32'h0000_0006);
            axi_lite_read(A_STATUS, rd);
            tb_check(rd[0] == 1'b1, "soft_reset should not immediately abandon in-flight write");

            @(negedge clk);
            hold_b_response = 1'b0;
            wait_for_idle("soft reset drain");

            axi_lite_read(A_STATUS, rd);
            tb_check(rd[1] == 1'b0, "soft_reset should clear done");
            tb_check(rd[2] == 1'b0, "soft_reset should clear error");

            axi_lite_read(A_PIXELS_ACCEPTED, rd);
            tb_check(rd == 32'd0, "soft_reset should clear PIXELS_ACCEPTED");
            axi_lite_read(A_PIXELS_WRITTEN, rd);
            tb_check(rd == 32'd0, "soft_reset should clear PIXELS_WRITTEN");
            axi_lite_read(A_WRITE_ERRORS, rd);
            tb_check(rd == 32'd0, "soft_reset should clear WRITE_ERRORS");
        end
    endtask

    initial begin
        tests = 0;
        fails = 0;

        $display("============================================================");
        $display(" pixel_write_engine_top_tb: top + AXI-Lite + core test");
        $display(" X_RES=%0d Y_RES=%0d FRAME_PIXELS=%0d", X_RES, Y_RES, FRAME_PIXELS);
        $display("============================================================");

        apply_reset();
        run_clean_frame();
        run_error_frame();
        run_enable_gate_test();
        run_soft_reset_drain_test();

        $display("============================================================");
        $display(" pixel_write_engine_top_tb summary: tests=%0d fails=%0d", tests, fails);
        $display("============================================================");

        if (fails == 0) begin
            $display("[TB PASS] pixel_write_engine_top_tb completed successfully");
            $finish;
        end
        else begin
            $fatal(1, "[TB FAIL] pixel_write_engine_top_tb completed with %0d failure(s)", fails);
        end
    end

endmodule
