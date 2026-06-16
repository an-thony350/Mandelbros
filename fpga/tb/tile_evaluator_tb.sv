`timescale 1ns / 1ps

module tb_tile_evaluator();

    // Parameters
    localparam int ITER_W = 16;
    localparam int TILE_W = 4;
    localparam int CLK_PERIOD = 10;

    logic                 clk;
    logic                 rst_n;
    logic                 in_valid;
    logic                 in_is_perimeter;
    logic [ITER_W-1:0]    in_iter;
    logic                 in_escaped;
    logic [TILE_W-1:0]    in_tile_id;
    logic                 in_ready;
    logic [3:0]           in_scale;

    logic                 out_tile_is_uniform;
    logic                 out_eval_done;
    logic [ITER_W-1:0]    out_eval_iter;
    logic                 out_eval_escaped;

    tile_evaluator #(
        .ITER_W(ITER_W),
        .TILE_W(TILE_W)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .in_valid           (in_valid),
        .in_is_perimeter    (in_is_perimeter),
        .in_iter            (in_iter),
        .in_escaped         (in_escaped),
        .in_tile_id         (in_tile_id),
        .in_ready           (in_ready),
        .in_scale           (in_scale),
        .out_tile_is_uniform(out_tile_is_uniform),
        .out_eval_done      (out_eval_done),
        .out_eval_iter      (out_eval_iter),
        .out_eval_escaped   (out_eval_escaped)
    );

    // Clock gen
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Task to send a single perimeter pixel
    task send_pixel(input logic [ITER_W-1:0] iter, input logic escaped);
        begin
            @(posedge clk);
            in_valid        = 1'b1;
            in_is_perimeter = 1'b1;
            in_iter         = iter;
            in_escaped      = escaped;
        end
    endtask

    // Task to wait a cycle with no valid data (stall)
    task idle_cycle();
        begin
            @(posedge clk);
            in_valid        = 1'b0;
            in_is_perimeter = 1'b0;
        end
    endtask

    // Main Test Sequence
    initial begin
        // 1. Initialization
        rst_n           = 0;
        in_valid        = 0;
        in_is_perimeter = 0;
        in_iter         = 0;
        in_escaped      = 0;
        in_tile_id      = 0;
        in_ready        = 1;
        in_scale        = 4'd1;

        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        // Test Case 1: Uniform Perimeter (Scale 1 -> 92 pixels)
        // Expected behavior: out_eval_done = 1, out_tile_is_uniform = 1
        $display("Starting Test Case 1: Uniform Perimeter (Scale 1)");
        in_scale   = 4'd1;
        in_tile_id = 4'd1;
        
        for (int i = 0; i <= 91; i++) begin
            send_pixel(16'd100, 1'b1);
        end
        idle_cycle();
        
        #(CLK_PERIOD);
        if (out_eval_done && out_tile_is_uniform) 
            $display("--> [PASS] Test Case 1: Evaluated successfully.");
        else 
            $display("--> [FAIL] Test Case 1: Expected uniform output.");

        #(CLK_PERIOD * 2);

        // Test Case 2: Non-Uniform Perimeter (Scale 4 -> 20 pixels)
        // Expected behavior: out_eval_done = 1, out_tile_is_uniform = 0
        $display("Starting Test Case 2: Non-Uniform Perimeter (Scale 4)");
        in_scale   = 4'd4;
        in_tile_id = 4'd2;
        
        for (int i = 0; i <= 19; i++) begin
            if (i == 10) begin
                send_pixel(16'd50, 1'b0); // Inject a mismatch on pixel 10
            end else begin
                send_pixel(16'd100, 1'b1);
            end
        end
        idle_cycle();
        
        #(CLK_PERIOD);
        if (out_eval_done && !out_tile_is_uniform) 
            $display("--> [PASS] Test Case 2: Mismatch correctly detected.");
        else 
            $display("--> [FAIL] Test Case 2: Did not flag the mismatch.");

        #(CLK_PERIOD * 2);

        // Test Case 3: Interrupted / Stalled Valid (Scale 8 -> 8 pixels)
        // Expected behavior: out_eval_done = 1, out_tile_is_uniform = 1
        $display("Starting Test Case 3: Uniform with stalls (Scale 8)");
        in_scale   = 4'd8;
        in_tile_id = 4'd3;
        
        for (int i = 0; i <= 7; i++) begin
            send_pixel(16'd15, 1'b0);
            idle_cycle(); // Introduce a stall between each pixel
        end
        idle_cycle();

        #(CLK_PERIOD);
        if (out_eval_done && out_tile_is_uniform) 
            $display("--> [PASS] Test Case 3: Evaluated successfully with stalls.");
        else 
            $display("--> [FAIL] Test Case 3: Failed with stalls.");

        $display("Simulation Finished.");
        $finish;
    end

endmodule