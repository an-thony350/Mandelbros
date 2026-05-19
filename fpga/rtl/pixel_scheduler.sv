`timescale 1ns / 1ps

module pixel_scheduler #(
    parameter int NUM_CORES = 32,
    parameter int W         = 26,
    parameter int SEQ_W     = 16,
    parameter int ITER_W    = 16,
    parameter int MODE_W    = 3,
    parameter int X_RES     = 1280,
    parameter int Y_RES     = 720
)(
    input logic clk,
    input logic rst,

    input logic signed [W-1:0] x_jump,
    input logic signed [W-1:0] y_jump,
    input logic signed [W-1:0] x_min,
    input logic signed [W-1:0] y_min,
    output logic               last_pixel,

    input logic signed [W-1:0] jul_c_r,
    input logic signed [W-1:0] jul_c_i,
    input logic [ITER_W-1:0]   in_max_iter,
    input logic [MODE_W-1:0]   in_mode,

    input  logic [NUM_CORES-1:0] in_ready,
    output logic [NUM_CORES-1:0] in_valid,

    output logic signed [W-1:0] c_r          [NUM_CORES],
    output logic signed [W-1:0] c_i          [NUM_CORES],
    output logic signed [W-1:0] z0_r         [NUM_CORES],
    output logic signed [W-1:0] z0_i         [NUM_CORES],
    output logic [ITER_W-1:0]   out_max_iter [NUM_CORES],
    output logic [MODE_W-1:0]   out_mode     [NUM_CORES],
    output logic [SEQ_W-1:0]    out_seq      [NUM_CORES]
);

    localparam int CORE_IDX_W = (NUM_CORES <= 1) ? 1 : $clog2(NUM_CORES);
    localparam int X_W        = (X_RES <= 1) ? 1 : $clog2(X_RES);
    localparam int Y_W        = (Y_RES <= 1) ? 1 : $clog2(Y_RES);

    localparam logic [MODE_W-1:0] MODE_JULIA = 3'd1;

    logic [CORE_IDX_W-1:0] chosen_core;
    logic                  available_core;
    logic                  dispatch;
    logic                  frame_done;

    logic signed [W-1:0] cur_c_r;
    logic signed [W-1:0] cur_c_i;

    logic signed [W-1:0] pixel_c_r;
    logic signed [W-1:0] pixel_c_i;
    logic signed [W-1:0] pixel_z0_r;
    logic signed [W-1:0] pixel_z0_i;

    logic [X_W-1:0]      x;
    logic [Y_W-1:0]      y;
    logic [SEQ_W-1:0]    seq;

    assign available_core = |in_ready;
    assign dispatch       = available_core && !frame_done;

    assign last_pixel = dispatch && (x == X_RES-1) && (y == Y_RES-1);

    always_comb begin
        chosen_core = '0;

        for (int i = 0; i < NUM_CORES; i++) begin
            if (in_ready[i]) begin
                chosen_core = i[CORE_IDX_W-1:0];
            end
        end
    end

    always_comb begin
        if (in_mode == MODE_JULIA) begin
            pixel_c_r  = jul_c_r;
            pixel_c_i  = jul_c_i;
            pixel_z0_r = cur_c_r;
            pixel_z0_i = cur_c_i;
        end
        else begin
            pixel_c_r  = cur_c_r;
            pixel_c_i  = cur_c_i;
            pixel_z0_r = '0;
            pixel_z0_i = '0;
        end
    end

    generate
        for (genvar gi = 0; gi < NUM_CORES; gi++) begin : core_parse
            localparam logic [CORE_IDX_W-1:0] CORE_ID = gi[CORE_IDX_W-1:0];

            assign c_r[gi]          = pixel_c_r;
            assign c_i[gi]          = pixel_c_i;
            assign z0_r[gi]         = pixel_z0_r;
            assign z0_i[gi]         = pixel_z0_i;
            assign out_max_iter[gi] = in_max_iter;
            assign out_mode[gi]     = in_mode;
            assign out_seq[gi]      = seq;

            assign in_valid[gi] = dispatch && (chosen_core == CORE_ID);
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            x          <= '0;
            y          <= '0;
            cur_c_r    <= x_min;
            cur_c_i    <= y_min;
            seq        <= '0;
            frame_done <= 1'b0;
        end
        else if (dispatch) begin
            seq <= seq + 1'b1;

            if ((x == X_RES-1) && (y == Y_RES-1)) begin
                frame_done <= 1'b1;
            end
            else if (x == X_RES-1) begin
                x       <= '0;
                cur_c_r <= x_min;

                y       <= y + 1'b1;
                cur_c_i <= cur_c_i + y_jump;
            end
            else begin
                x       <= x + 1'b1;
                cur_c_r <= cur_c_r + x_jump;
            end
        end
    end

endmodule