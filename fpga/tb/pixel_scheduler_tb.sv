`timescale 1ns / 1ps

module pixel_scheduler_tb();

    // Note that a lower NUM_CORES and X/Y_RES are used to speed up testing
    
    localparam NUM_CORES = 4;
    localparam W         = 26;
    localparam SEQ_W     = 16;
    localparam ITER_W    = 16;
    localparam MODE_W    = 3;
    
    localparam X_RES     = 10;
    localparam Y_RES     = 10; 


    logic clk;
    logic rst;

    logic signed [W-1:0] x_jump;
    logic signed [W-1:0] y_jump;
    logic signed [W-1:0] x_min;
    logic signed [W-1:0] y_min;
    logic                last_pixel;

    logic signed [W-1:0] jul_c_r;
    logic signed [W-1:0] jul_c_i;
    logic [ITER_W-1:0]   in_max_iter;
    logic [MODE_W-1:0]   in_mode;

    logic [NUM_CORES-1:0] in_ready;
    logic [NUM_CORES-1:0] in_valid;

    logic signed [W-1:0] c_r          [NUM_CORES];
    logic signed [W-1:0] c_i          [NUM_CORES];
    logic signed [W-1:0] z0_r         [NUM_CORES];
    logic signed [W-1:0] z0_i         [NUM_CORES];
    logic [ITER_W-1:0]   out_max_iter [NUM_CORES];
    logic [MODE_W-1:0]   out_mode     [NUM_CORES];
    logic [SEQ_W-1:0]    out_seq      [NUM_CORES];

 
    pixel_scheduler #(
        .NUM_CORES(NUM_CORES),
        .W(W),
        .SEQ_W(SEQ_W),
        .ITER_W(ITER_W),
        .MODE_W(MODE_W),
        .X_RES(X_RES),
        .Y_RES(Y_RES)
    ) dut (
        .* );

  
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst = 1;
        x_min       = -32'd20000;
        y_min       = -32'd10000;
        x_jump      =  32'd100;
        y_jump      =  32'd50;
        jul_c_r     =  32'd5555;
        jul_c_i     = -32'd4444;
        in_max_iter =  16'd256;
        in_mode     =  3'd0; 

        repeat(5) @(posedge clk);
        rst = 0;
        
        $display("--- Starting Phase 1: Mandelbrot Mode ---");
        wait(last_pixel == 1'b1);
        repeat(5) @(posedge clk);
        
        $display("--- Starting Phase 2: Julia Mode ---");
        rst = 1;
        in_mode = 3'd1;
        repeat(2) @(posedge clk);
        rst = 0;
        
        wait(last_pixel == 1'b1);
        repeat(5) @(posedge clk);
        
        $display("--- TEST COMPLETE ---");
        $finish;
    end


    always_ff @(posedge clk) begin
        if (rst) begin
            in_ready <= '0;
        end else begin
            for (int i = 0; i < NUM_CORES; i++) begin
                in_ready[i] <= ($urandom_range(0, 100) < 70);
            end
        end
    end

    int expected_seq = 0;
    int expected_x = 0;
    int expected_y = 0;

    logic signed [63:0] calc_c_r;
    logic signed [63:0] calc_c_i;
    logic signed [63:0] ext_expected_x;
    logic signed [63:0] ext_expected_y;

    always @(negedge clk) begin
        if (!rst) begin
            for (int i = 0; i < NUM_CORES; i++) begin
                if (in_valid[i] && in_ready[i]) begin
                    
                    // 1. Check Sequence Number
                    if (out_seq[i] !== expected_seq) begin
                        $error("Seq Error! Expected %0d, Got %0d", expected_seq, out_seq[i]);
                    end
                    
                    // 2. Do the math securely in 64-bit space
                    ext_expected_x = expected_x;
                    ext_expected_y = expected_y;
                    calc_c_r = x_min + (ext_expected_x * x_jump);
                    calc_c_i = y_min + (ext_expected_y * y_jump);

                    // 3. Check Math and Routing
                    if (in_mode == 0) begin
                        if (c_r[i] !== calc_c_r || c_i[i] !== calc_c_i) begin
                            $error("Math Error! Expected c_r:%0d c_i:%0d, Got c_r:%0d c_i:%0d", 
                                   calc_c_r, calc_c_i, c_r[i], c_i[i]);
                        end
                        if (z0_r[i] !== 0 || z0_i[i] !== 0) begin
                            $error("Mandelbrot z0 must be 0!");
                        end
                    end 
                    else begin
                        if (c_r[i] !== jul_c_r || c_i[i] !== jul_c_i) begin
                            $error("Julia c must be constant!");
                        end
                        if (z0_r[i] !== calc_c_r || z0_i[i] !== calc_c_i) begin
                            $error("Julia Math Error! Expected z0_r:%0d z0_i:%0d", calc_c_r, calc_c_i);
                        end
                    end

                    // 4. Advance tracking
                    expected_seq++;
                    if (expected_x == X_RES - 1) begin
                        expected_x = 0;
                        if (expected_y == Y_RES - 1) begin
                            $display("Frame finished at Sequence: %0d", expected_seq);
                            expected_seq = 0;
                            expected_y = 0;
                        end else begin
                            expected_y++;
                        end
                    end else begin
                        expected_x++;
                    end
                    
                end
            end
        end
    end

endmodule