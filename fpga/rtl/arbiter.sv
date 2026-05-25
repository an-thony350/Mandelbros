`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 23.05.2026 12:34:37
// Design Name: 
// Module Name: arbiter
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


(* keep_hierarchy = "yes" *)
module result_arbiter #(
    parameter int NUM_CORES = 16,
    parameter int W         = 26,
    parameter int ITER_W    = 16,
    parameter int SEQ_W     = 20
)(
    input logic clk,
    input logic rst_n,

    // Inputs from all iter_cores
    input  logic [NUM_CORES-1:0]                core_out_valid,
    output logic [NUM_CORES-1:0]                core_out_ready,

    input  logic [(SEQ_W*NUM_CORES)-1:0]        core_out_seq,
    input  logic [(ITER_W*NUM_CORES)-1:0]       core_out_iter,
    input  logic signed [(W*NUM_CORES)-1:0]     core_out_z_r,
    input  logic signed [(W*NUM_CORES)-1:0]     core_out_z_i,
    input  logic [NUM_CORES-1:0]                core_out_escaped,
    input  logic [NUM_CORES-1:0]                core_out_overflow,

    // Output to reorder_buffer
    output logic                                rob_in_valid,
    input  logic                                rob_in_ready,

    output logic [ITER_W-1:0]                   rob_in_iter_count,
    output logic [SEQ_W-1:0]                    rob_in_seq_num,
    output logic signed [W-1:0]                 rob_in_z_r,
    output logic signed [W-1:0]                 rob_in_z_i,
    output logic                                rob_in_escaped,
    output logic                                rob_in_overflow
);

    localparam int CORE_IDX_W = (NUM_CORES <= 1) ? 1 : $clog2(NUM_CORES);

    logic [CORE_IDX_W-1:0] rr_ptr;

    logic [CORE_IDX_W-1:0] grant_idx;
    logic                  grant_valid;

    logic [CORE_IDX_W-1:0] hold_idx;
    logic                  hold_valid;

    logic [CORE_IDX_W-1:0] selected_idx;
    logic                  selected_valid;

    // -------------------------------------------------------------------------
    // VIVADO BUG FIX: Unpack flat 1D arrays into 2D arrays using constant indexing
    // -------------------------------------------------------------------------
    logic [SEQ_W-1:0]    seq_2d  [NUM_CORES];
    logic [ITER_W-1:0]   iter_2d [NUM_CORES];
    logic signed [W-1:0] z_r_2d  [NUM_CORES];
    logic signed [W-1:0] z_i_2d  [NUM_CORES];

    always_comb begin
        for (int i = 0; i < NUM_CORES; i++) begin
            seq_2d[i]  = core_out_seq[(i*SEQ_W) +: SEQ_W];
            iter_2d[i] = core_out_iter[(i*ITER_W) +: ITER_W];
            z_r_2d[i]  = core_out_z_r[(i*W) +: W];
            z_i_2d[i]  = core_out_z_i[(i*W) +: W];
        end
    end

    // -------------------------------------------------------------------------
    // Round-robin grant selection (Optimized for Timing)
    // -------------------------------------------------------------------------
    logic [NUM_CORES-1:0] masked_req;
    
    always_comb begin
        // Mask out cores that have lower priority than the current rr_ptr
        for (int i = 0; i < NUM_CORES; i++) begin
            masked_req[i] = core_out_valid[i] & (i >= rr_ptr);
        end
        
        grant_valid = 1'b0;
        grant_idx   = '0;

        // 1st Priority Tree: Look at masked requests (equal or higher than pointer)
        if (|masked_req) begin
            grant_valid = 1'b1;
            for (int i = 0; i < NUM_CORES; i++) begin
                if (masked_req[i]) begin
                    grant_idx = i[CORE_IDX_W-1:0];
                    break;
                end
            end
        end 
        // 2nd Priority Tree: Wrap around and look at unmasked requests
        else if (|core_out_valid) begin
            grant_valid = 1'b1;
            for (int i = 0; i < NUM_CORES; i++) begin
                if (core_out_valid[i]) begin
                    grant_idx = i[CORE_IDX_W-1:0];
                    break;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Hold/Grant Selection
    // -------------------------------------------------------------------------
    always_comb begin
        if (hold_valid) begin
            selected_valid = 1'b1;
            selected_idx   = hold_idx;
        end
        else begin
            selected_valid = grant_valid;
            selected_idx   = grant_idx;
        end
    end

    // -------------------------------------------------------------------------
    // DATA MUX: Safely index the 2D arrays (No variable part-selects!)
    // -------------------------------------------------------------------------
    always_comb begin
        rob_in_valid      = selected_valid;

        rob_in_iter_count = '0;
        rob_in_seq_num    = '0;
        rob_in_z_r        = '0;
        rob_in_z_i        = '0;
        rob_in_escaped    = 1'b0;
        rob_in_overflow   = 1'b0;

        if (selected_valid) begin
            rob_in_iter_count = iter_2d[selected_idx];
            rob_in_seq_num    = seq_2d[selected_idx];
            rob_in_z_r        = z_r_2d[selected_idx];
            rob_in_z_i        = z_i_2d[selected_idx];
            rob_in_escaped    = core_out_escaped[selected_idx];
            rob_in_overflow   = core_out_overflow[selected_idx];
        end
    end

    // -------------------------------------------------------------------------
    // READY DEMUX: Explicit assignment to prevent synthesizer loops
    // -------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < NUM_CORES; i++) begin
            if (selected_valid && (selected_idx == i)) begin
                core_out_ready[i] = rob_in_ready;
            end else begin
                core_out_ready[i] = 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sequential state
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rr_ptr     <= '0;
            hold_idx   <= '0;
            hold_valid <= 1'b0;
        end
        else begin
            if (selected_valid && rob_in_ready) begin
                // Successful transfer to reorder buffer.
                hold_valid <= 1'b0;

                if (selected_idx == NUM_CORES-1) begin
                    rr_ptr <= '0;
                end
                else begin
                    rr_ptr <= (CORE_IDX_W)'(selected_idx + 1'b1);
                end
            end
            else if (!hold_valid && grant_valid && !rob_in_ready) begin
                // Reorder buffer could not accept this result.
                // Keep presenting the same core next cycle.
                hold_valid <= 1'b1;
                hold_idx   <= grant_idx;
            end
        end
    end

endmodule