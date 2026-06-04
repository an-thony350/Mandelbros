`timescale 1ns / 1ps

module tile_scheduler_tb;


    parameter int NUM_CORES = 4;
    parameter int W         = 26;
    parameter int INDEX_W   = 20;
    parameter int ITER_W    = 16;
    parameter int MODE_W    = 3;
    parameter int X_RES     = 64; // Exactly 2 tiles wide (32 * 2)
    parameter int Y_RES     = 32; // Exactly 2 tiles high (16 * 2)


    logic clk;
    logic rst_n;

    logic signed [W-1:0] x_jump;
    logic signed [W-1:0] y_jump;
    logic signed [W-1:0] x_min;
    logic signed [W-1:0] y_min;
    
    logic signed [W-1:0] jul_c_r;
    logic signed [W-1:0] jul_c_i;
    logic [ITER_W-1:0]   in_max_iter;
    logic [MODE_W-1:0]   in_mode;

    logic [NUM_CORES-1:0] in_ready;
    logic [NUM_CORES-1:0] in_valid;

    logic signed [(W*NUM_CORES)-1:0] c_r;
    logic signed [(W*NUM_CORES)-1:0] c_i;
    logic signed [(W*NUM_CORES)-1:0] z0_r;
    logic signed [(W*NUM_CORES)-1:0] z0_i;
    logic [(ITER_W*NUM_CORES)-1:0]   out_max_iter;
    logic [(MODE_W*NUM_CORES)-1:0]   out_mode;
    logic [(INDEX_W*NUM_CORES)-1:0]  out_pixel_index;


    tile_scheduler #(
        .NUM_CORES(NUM_CORES),
        .W(W),
        .INDEX_W(INDEX_W),
        .ITER_W(ITER_W),
        .MODE_W(MODE_W),
        .X_RES(X_RES),
        .Y_RES(Y_RES)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .x_jump(x_jump),
        .y_jump(y_jump),
        .x_min(x_min),
        .y_min(y_min),
        .jul_c_r(jul_c_r),
        .jul_c_i(jul_c_i),
        .in_max_iter(in_max_iter),
        .in_mode(in_mode),
        .in_ready(in_ready),
        .in_valid(in_valid),
        .c_r(c_r),
        .c_i(c_i),
        .z0_r(z0_r),
        .z0_i(z0_i),
        .out_max_iter(out_max_iter),
        .out_mode(out_mode),
        .out_pixel_index(out_pixel_index)
    );


    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end


    initial begin
        // 1. Initialize Inputs
        rst_n       = 0;
        in_ready    = '0;
        
        // Mock fixed-point values for easy reading in the console
        x_min       = 26'd0;
        y_min       = 26'd0;
        x_jump      = 26'd100;  // Every X pixel adds 100
        y_jump      = 26'd1000; // Every Y pixel adds 1000
        
        jul_c_r     = 26'h000_AAAA;
        jul_c_i     = 26'h000_BBBB;
        in_max_iter = 16'd64;
        in_mode     = 3'd0; // 0 = Mandelbrot, 1 = Julia

        // 2. Apply Reset
        #20;
        rst_n = 1;
        #10;

        // 3. Enable cores (all cores ready to accept data)
        in_ready = 4'b1111; 

        // 4. Wait for the frame to finish
        wait (dut.frame_done == 1'b1);
        
        // 5. Finish simulation shortly after
        #50;
        $display("========================================");
        $display("FRAME COMPLETE DETECTED. End of test.");
        $display("========================================");
        $finish;
    end


    // This block triggers every time the scheduler successfully dispatches a pixel
    integer active_core;
    
    always @(posedge clk) begin
        if (rst_n && (|in_valid)) begin
            // Find which core got the data (priority encoder style)
            active_core = -1;
            for (int i = 0; i < NUM_CORES; i++) begin
                if (in_valid[i]) begin
                    active_core = i;
                    break;
                end
            end
            
            if (active_core != -1) begin
                // Extract the specific core's data from the flat arrays
                logic signed [W-1:0]       core_c_r;
                logic signed [W-1:0]       core_c_i;
                logic [INDEX_W-1:0]        core_idx;
                
                core_c_r = c_r[(active_core*W) +: W];
                core_c_i = c_i[(active_core*W) +: W];
                core_idx = out_pixel_index[(active_core*INDEX_W) +: INDEX_W];

                // Print the state. 
                // We also peek into the DUT's internal counters to verify the tile logic.
                $display("Time: %0t | Core: %0d | Tile(X:%0d, Y:%0d) | Local(x:%0d, y:%0d) | AbsIdx: %0d | Math: c_r=%0d, c_i=%0d", 
                          $time, active_core, dut.x, dut.y, dut.x_tile, dut.y_tile, core_idx, core_c_r, core_c_i);
            end
        end
    end

endmodule