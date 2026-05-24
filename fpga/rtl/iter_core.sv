`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 21.05.2026 16:44:53
// Design Name: 
// Module Name: iter_core
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


// 7-stage pipelined fixed-point fractal iteration core.
// Computes either Tricorn, Burning Ship, Mandelbrot, or Julia iterations based on the mode field
// Iteration terminates when |z|^2 > 4 (escape) or iter == max_iter (in set).
// i know the variable naming conventions are a bit suspect, but they make sense if you think hard enough


module iter_core #(
    parameter int W       = 26,    
    parameter int FRAC    = 22,    
    parameter int SEQ_W   = 20,    
    parameter int ITER_W  = 16,    
    parameter int MODE_W  = 3,     
    parameter logic [W-1:0] ESCAPE_THRESH_Q422 = 26'sh100_0000  
) (
    input  logic                 clk,
    input  logic                 rst_n,

    // input handshake (from scheduler) 
    output logic                 in_ready,
    input  logic                 in_valid,
    input  logic signed [W-1:0]  in_c_r,
    input  logic signed [W-1:0]  in_c_i,
    input  logic signed [W-1:0]  in_z0_r,
    input  logic signed [W-1:0]  in_z0_i,
    input  logic [ITER_W-1:0]    in_max_iter,
    input  logic [MODE_W-1:0]    in_mode,
    input  logic [SEQ_W-1:0]     in_seq,

    // output handshake (to reorder buffer) 
    input  logic                 out_ready,
    output logic                 out_valid,
    output logic [SEQ_W-1:0]     out_seq,
    output logic [ITER_W-1:0]    out_iter,
    output logic signed [W-1:0]  out_z_r,
    output logic signed [W-1:0]  out_z_i,
    output logic                 out_escaped,
    output logic                 out_overflow
);

    // Mode enum (must match what the scheduler / regfile produces)

    localparam logic [MODE_W-1:0] MODE_MANDEL  = 3'd0;
    localparam logic [MODE_W-1:0] MODE_JULIA   = 3'd1;
    localparam logic [MODE_W-1:0] MODE_BURNING = 3'd2;
    localparam logic [MODE_W-1:0] MODE_TRICORN = 3'd3;
    
    localparam int PROD_W = 2*W;   // 52 for W=26

    // Slot payload carried through the pipeline
    typedef struct packed {
        logic                  valid;     // 0 = bubble
        logic [SEQ_W-1:0]      seq;
        logic [MODE_W-1:0]     mode;
        logic [ITER_W-1:0]     max_iter;
        logic [ITER_W-1:0]     iter;      // iterations completed so far
        logic signed [W-1:0]   c_r;
        logic signed [W-1:0]   c_i;
        logic signed [W-1:0]   z_r;
        logic signed [W-1:0]   z_i;
        logic                  overflow;  // sticky over this pixel's life
    } slot_t;

    // Pipeline registers
    slot_t s0_r;

    slot_t s1_payload_r;
    logic signed [W-1:0] s1_zm_r, s1_zm_i;

    // Multiply M register (specify DSP for synthesis)
    slot_t s2_payload_r;
     logic signed [PROD_W-1:0] s2_zr2_m_r;
     logic signed [PROD_W-1:0] s2_zi2_m_r;
     logic signed [PROD_W-1:0] s2_zrzi_m_r;

    // Multiply P register (specify DSP for synthesis)
    slot_t s3_payload_r;
    logic signed [PROD_W-1:0] s3_zr2_p_r;
    logic signed [PROD_W-1:0] s3_zi2_p_r;
    logic signed [PROD_W-1:0] s3_zrzi_p_r;

    // Rounded-back-to-Q4.22 squares + sticky overflow flag
    slot_t s4_payload_r;
    logic signed [W-1:0] s4_zr2_r;
    logic signed [W-1:0] s4_zi2_r;
    logic signed [W:0]   s4_two_zrzi_r;
    logic                s4_ovf_r;

    // Partial sums for z_new and |z|^2
    slot_t s5_payload_r;
    logic signed [W:0]   s5_z_r_new_full_r;   // zr2 - zi2 + c_r, 27-bit signed
    logic signed [W:0]   s5_z_i_new_full_r;   // 2*zr*zi + c_i,   27-bit signed
    logic signed [W:0]   s5_mag_sq_r;         // zr2 + zi2,       27-bit signed
    logic                s5_ovf_r;            // s4_ovf carried forward
    logic                s5_combine_ovf_r;    // truncation overflow on z_r_new / z_i_new

    // Final stage: post-escape decision
    slot_t s6_r;
    logic  s6_escaped_r;
    logic  s6_reached_max_r;

    // Stage 0 combinational : mode transform
    logic signed [W-1:0] s0_zm_r, s0_zm_i;

    always_comb begin
        unique case (s0_r.mode)
            MODE_MANDEL, MODE_JULIA: begin
                s0_zm_r = s0_r.z_r;
                s0_zm_i = s0_r.z_i;
            end
            MODE_BURNING: begin
                s0_zm_r = s0_r.z_r[W-1] ? -s0_r.z_r : s0_r.z_r;
                s0_zm_i = s0_r.z_i[W-1] ? -s0_r.z_i : s0_r.z_i;
            end
            MODE_TRICORN: begin
                s0_zm_r =  s0_r.z_r;
                s0_zm_i = -s0_r.z_i;
            end
            default: begin
                s0_zm_r = s0_r.z_r;
                s0_zm_i = s0_r.z_i;
            end
        endcase
    end

    // Stage 4 combinational : round Q8.44 product to Q4.22, ovf flags
    localparam logic signed [PROD_W-1:0] ROUND_BIAS = (1 <<< (FRAC - 1));

    logic signed [PROD_W-1:0] s3_zr2_round_c, s3_zi2_round_c, s3_zrzi_round_c;
    logic signed [W-1:0]      zr2_q422_c, zi2_q422_c, zrzi_q422_c;
    logic signed [W:0]        two_zrzi_q523_c;
    logic                     zr2_ovf_c, zi2_ovf_c, zrzi_ovf_c;

    logic zr2_upper_all_ones,  zr2_upper_all_zeros;
    logic zi2_upper_all_ones,  zi2_upper_all_zeros;
    logic zrzi_upper_all_ones, zrzi_upper_all_zeros;

    always_comb begin
        // Round-to-nearest by adding 2^(FRAC-1) before truncation
        s3_zr2_round_c  = s3_zr2_p_r  + ROUND_BIAS;
        s3_zi2_round_c  = s3_zi2_p_r  + ROUND_BIAS;
        s3_zrzi_round_c = s3_zrzi_p_r + ROUND_BIAS;

        // Slice back to Q4.22
        zr2_q422_c  = s3_zr2_round_c [W+FRAC-1 : FRAC];
        zi2_q422_c  = s3_zi2_round_c [W+FRAC-1 : FRAC];
        zrzi_q422_c = s3_zrzi_round_c[W+FRAC-1 : FRAC];

        // 2*zr*zi as Q5.22 (one extra bit because of the <<1)
        two_zrzi_q523_c = $signed({zrzi_q422_c[W-1], zrzi_q422_c}) <<< 1;

        // Overflow if discarded upper bits are mixed (not all 0 and not all 1)
        zr2_upper_all_ones  =  &s3_zr2_round_c [PROD_W-1 : W+FRAC-1];
        zr2_upper_all_zeros = ~|s3_zr2_round_c [PROD_W-1 : W+FRAC-1];
        zr2_ovf_c           = ~(zr2_upper_all_ones | zr2_upper_all_zeros);

        zi2_upper_all_ones  =  &s3_zi2_round_c [PROD_W-1 : W+FRAC-1];
        zi2_upper_all_zeros = ~|s3_zi2_round_c [PROD_W-1 : W+FRAC-1];
        zi2_ovf_c           = ~(zi2_upper_all_ones | zi2_upper_all_zeros);

        zrzi_upper_all_ones  =  &s3_zrzi_round_c[PROD_W-1 : W+FRAC-1];
        zrzi_upper_all_zeros = ~|s3_zrzi_round_c[PROD_W-1 : W+FRAC-1];
        zrzi_ovf_c           = ~(zrzi_upper_all_ones | zrzi_upper_all_zeros);
    end

    // Stage 5 combinational : partial sums + combine-overflow detect
    logic signed [W:0] s4_zr2_minus_zi2_c;
    logic signed [W:0] s4_z_r_new_full_c, s4_z_i_new_full_c, s4_mag_sq_c;
    logic              s4_combine_ovf_c;

    always_comb begin
        // 27-bit signed to safely absorb sign/integer growth
        s4_zr2_minus_zi2_c = $signed({s4_zr2_r[W-1], s4_zr2_r})
                           - $signed({s4_zi2_r[W-1], s4_zi2_r});

        s4_z_r_new_full_c  = s4_zr2_minus_zi2_c
                           + $signed({s4_payload_r.c_r[W-1], s4_payload_r.c_r});

        s4_z_i_new_full_c  = s4_two_zrzi_r
                           + $signed({s4_payload_r.c_i[W-1], s4_payload_r.c_i});

        s4_mag_sq_c        = $signed({s4_zr2_r[W-1], s4_zr2_r})
                           + $signed({s4_zi2_r[W-1], s4_zi2_r});

        // Truncation back to W bits overflows if top sign-extended bit differs from W-1
        s4_combine_ovf_c   = (s4_z_r_new_full_c[W] ^ s4_z_r_new_full_c[W-1])
                           | (s4_z_i_new_full_c[W] ^ s4_z_i_new_full_c[W-1]);
    end

    // Stage 6 combinational : escape compare, truncate, reached_max test
    logic                s5_escaped_c;
    logic                s5_reached_max_c;
    logic signed [W-1:0] s5_z_r_new_trunc_c, s5_z_i_new_trunc_c;

    always_comb begin
        // Sticky overflow forces escape (so the pixel exits)
        s5_escaped_c     = s5_ovf_r
                         | ($signed(s5_mag_sq_r) > $signed({1'b0, ESCAPE_THRESH_Q422}));

        s5_reached_max_c = ((s5_payload_r.iter + 1'b1) == s5_payload_r.max_iter);

        s5_z_r_new_trunc_c = s5_z_r_new_full_r[W-1:0];
        s5_z_i_new_trunc_c = s5_z_i_new_full_r[W-1:0];
    end

    // Eject / recycle / stall handshake
    logic s6_done_c, s6_eject_now_c, s6_stall_c;
    logic advance;

    assign s6_done_c      = s6_r.valid & (s6_escaped_r | s6_reached_max_r);
    assign s6_eject_now_c = s6_done_c & out_ready;
    assign s6_stall_c     = s6_done_c & ~out_ready;
    assign advance        = ~s6_stall_c;
    assign in_ready       = advance & (s6_eject_now_c | ~s6_r.valid);

    // Outputs
    assign out_valid    = s6_done_c;
    assign out_seq      = s6_r.seq;
    assign out_iter     = s6_r.iter;
    assign out_z_r      = s6_r.z_r;
    assign out_z_i      = s6_r.z_i;
    assign out_escaped  = s6_escaped_r;
    assign out_overflow = s6_r.overflow;

    // s0 next-state mux : accept new input, recycle from s6, or bubble
    slot_t s0_next_c;

    always_comb begin
        s0_next_c = '0;   // default: bubble

        if (~advance) begin
            s0_next_c = s0_r;   // hold when stage 6 is stalled
        end
        else if (s6_eject_now_c | ~s6_r.valid) begin
            if (in_valid) begin
                s0_next_c.valid    = 1'b1;
                s0_next_c.seq      = in_seq;
                s0_next_c.mode     = in_mode;
                s0_next_c.max_iter = in_max_iter;
                s0_next_c.iter     = '0;
                s0_next_c.c_r      = in_c_r;
                s0_next_c.c_i      = in_c_i;
                s0_next_c.z_r      = in_z0_r;
                s0_next_c.z_i      = in_z0_i;
                s0_next_c.overflow = 1'b0;
            end
            // else: bubble (already '0 from default)
        end
        else begin
            // recycle the in-flight pixel from s6 for another iteration
            s0_next_c.valid    = 1'b1;
            s0_next_c.seq      = s6_r.seq;
            s0_next_c.mode     = s6_r.mode;
            s0_next_c.max_iter = s6_r.max_iter;
            s0_next_c.iter     = s6_r.iter;     // already incremented at s6
            s0_next_c.c_r      = s6_r.c_r;
            s0_next_c.c_i      = s6_r.c_i;
            s0_next_c.z_r      = s6_r.z_r;      // already updated at s6
            s0_next_c.z_i      = s6_r.z_i;
            s0_next_c.overflow = s6_r.overflow;
        end
    end

    // Pipeline register updates
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s0_r              <= '0;
            s1_payload_r      <= '0;
            s1_zm_r           <= '0;
            s1_zm_i           <= '0;
            s2_payload_r      <= '0;
            s2_zr2_m_r        <= '0;
            s2_zi2_m_r        <= '0;
            s2_zrzi_m_r       <= '0;
            s3_payload_r      <= '0;
            s3_zr2_p_r        <= '0;
            s3_zi2_p_r        <= '0;
            s3_zrzi_p_r       <= '0;
            s4_payload_r      <= '0;
            s4_zr2_r          <= '0;
            s4_zi2_r          <= '0;
            s4_two_zrzi_r     <= '0;
            s4_ovf_r          <= '0;
            s5_payload_r      <= '0;
            s5_z_r_new_full_r <= '0;
            s5_z_i_new_full_r <= '0;
            s5_mag_sq_r       <= '0;
            s5_ovf_r          <= '0;
            s5_combine_ovf_r  <= '0;
            s6_r              <= '0;
            s6_escaped_r      <= '0;
            s6_reached_max_r  <= '0;
        end
        else if (advance) begin
            // s0 takes from the input/recycle/bubble mux
            s0_r <= s0_next_c;

            // s0 -> s1 : register modified z operands and carry payload
            s1_payload_r <= s0_r;
            s1_zm_r      <= s0_zm_r;
            s1_zm_i      <= s0_zm_i;

            // s1 -> s2 : compute the three full products (DSP M register)
            s2_payload_r <= s1_payload_r;
            s2_zr2_m_r   <= s1_zm_r * s1_zm_r;
            s2_zi2_m_r   <= s1_zm_i * s1_zm_i;
            s2_zrzi_m_r  <= s1_zm_r * s1_zm_i;

            // s2 -> s3 : DSP P register; pure register-to-register move
            s3_payload_r <= s2_payload_r;
            s3_zr2_p_r   <= s2_zr2_m_r;
            s3_zi2_p_r   <= s2_zi2_m_r;
            s3_zrzi_p_r  <= s2_zrzi_m_r;

            // s3 -> s4 : round to Q4.22, latch sticky overflow
            s4_payload_r  <= s3_payload_r;
            s4_zr2_r      <= zr2_q422_c;
            s4_zi2_r      <= zi2_q422_c;
            s4_two_zrzi_r <= two_zrzi_q523_c;
            s4_ovf_r      <= s3_payload_r.overflow | zr2_ovf_c | zi2_ovf_c | zrzi_ovf_c;

            // s4 -> s5 : partial sums and combine-overflow flag
            s5_payload_r      <= s4_payload_r;
            s5_z_r_new_full_r <= s4_z_r_new_full_c;
            s5_z_i_new_full_r <= s4_z_i_new_full_c;
            s5_mag_sq_r       <= s4_mag_sq_c;
            s5_ovf_r          <= s4_ovf_r;
            s5_combine_ovf_r  <= s4_combine_ovf_c;

            // s5 -> s6 : escape compare, escape mux on z, iter increment
            s6_r.valid    <= s5_payload_r.valid;
            s6_r.seq      <= s5_payload_r.seq;
            s6_r.mode     <= s5_payload_r.mode;
            s6_r.max_iter <= s5_payload_r.max_iter;
            s6_r.c_r      <= s5_payload_r.c_r;
            s6_r.c_i      <= s5_payload_r.c_i;

            if (s5_escaped_c) begin
                // Current z has already escaped; do not count another iteration.
                s6_r.iter <= s5_payload_r.iter;
                s6_r.z_r  <= s5_payload_r.z_r;
                s6_r.z_i  <= s5_payload_r.z_i;
            end
            else begin
                // Not escaped: commit one more iteration.
                s6_r.iter <= s5_payload_r.iter + 1'b1;
                s6_r.z_r  <= s5_z_r_new_trunc_c;
                s6_r.z_i  <= s5_z_i_new_trunc_c;
            end

            s6_r.overflow    <= s5_ovf_r | s5_combine_ovf_r;
            s6_escaped_r     <= s5_escaped_c;
            s6_reached_max_r <= ~s5_escaped_c & s5_reached_max_c;
        end
        // else: advance == 0, pipeline holds; no register updates.
    end

endmodule
