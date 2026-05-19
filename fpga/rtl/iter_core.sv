// 5-stage pipelined fixed-point fractal iteration core.
// Computes either Tricorn, Burning Ship, Mandelbrot, or Julia iterations based on the mode field
// Iteration terminates when |z|^2 > 4 (escape) or iter == max_iter (in set).
// i know the variable naming conventions are a bit suspect, but they make sense if you think hard enough

`default_nettype none

module iter_core #(
    parameter int W       = 26,    
    parameter int FRAC    = 22,    
    parameter int SEQ_W   = 16,    
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

    // Pipeline registers: slot[0] = stage 0 input, ..., slot[4] = stage 4
    slot_t s0_r, s1_r, s2_r, s3_r, s4_r;
    logic signed [W-1:0] s0_zm_r, s0_zm_i;

    // STAGE 0 : apply mode transform to z, prepare multiplier operands

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

    // STAGE 1 : hold the modified z operands

    slot_t s1_payload_r;
    logic signed [W-1:0] s1_zm_r, s1_zm_i;


    localparam int PROD_W = 2*W; // 52

    // Stage 2 registers for the products

    slot_t s2_payload_r;

    logic signed [PROD_W-1:0]    s2_zr2_full_r;   // z_r * z_r  (always >= 0)
    logic signed [PROD_W-1:0]    s2_zi2_full_r;   // z_i * z_i  (always >= 0)
    logic signed [PROD_W-1:0]    s2_zrzi_full_r;  // z_r * z_i  (signed)

    // Stage 3 registers for the products shifted down to Q4.22

    slot_t s3_payload_r;

    logic signed [W-1:0] s3_zr2_r;   // z_r^2 in Q4.22
    logic signed [W-1:0] s3_zi2_r;   // z_i^2 in Q4.22
    logic signed [W:0]   s3_two_zrzi_r;  // one bit larger as it can overflow
    logic                s3_ovf_r; // sticky overflow flag for this pixel

    // combinational logic for stage 3 outputs

    localparam logic signed [PROD_W-1:0] ROUND_BIAS = (1 <<< (FRAC - 1)); // for rounding the products when shifting down

    logic signed [PROD_W-1:0]   s2_zr2_round_c, s2_zi2_round_c, s2_zrzi_round_c;
    logic signed [W-1:0]        zr2_q422_c, zi2_q422_c, zrzi_q422_c;
    logic signed [W:0]          two_zrzi_q523_c;
    logic                       zr2_ovf_c, zi2_ovf_c, zrzi_ovf_c;

    logic zr2_upper_all_ones, zr2_upper_all_zeros;
    logic zi2_upper_all_ones, zi2_upper_all_zeros;
    logic zrzi_upper_all_ones, zrzi_upper_all_zeros;

always_comb begin
    // add rounding bias before shifting down to Q4.22
    s2_zr2_round_c   = s2_zr2_full_r   + ROUND_BIAS;
    s2_zi2_round_c   = s2_zi2_full_r   + ROUND_BIAS;
    s2_zrzi_round_c  = s2_zrzi_full_r  + ROUND_BIAS;

    // slice the Q4.22 version
    zr2_q422_c       = s2_zr2_round_c[W+FRAC-1 : FRAC];
    zi2_q422_c       = s2_zi2_round_c[W+FRAC-1 : FRAC];
    zrzi_q422_c      = s2_zrzi_round_c[W+FRAC-1 : FRAC];
    
    two_zrzi_q523_c  = $signed({zrzi_q422_c[W-1], zrzi_q422_c}) <<< 1;

    // overflow if discarded upper bits are mixed
    // no overflow if they are all 0 or all 1
    zr2_upper_all_ones  =  &s2_zr2_round_c[PROD_W-1 : W+FRAC-1];
    zr2_upper_all_zeros = ~|s2_zr2_round_c[PROD_W-1 : W+FRAC-1];
    zr2_ovf_c           = ~(zr2_upper_all_ones | zr2_upper_all_zeros);

    zi2_upper_all_ones  =  &s2_zi2_round_c[PROD_W-1 : W+FRAC-1];
    zi2_upper_all_zeros = ~|s2_zi2_round_c[PROD_W-1 : W+FRAC-1];
    zi2_ovf_c           = ~(zi2_upper_all_ones | zi2_upper_all_zeros);

    zrzi_upper_all_ones  =  &s2_zrzi_round_c[PROD_W-1 : W+FRAC-1];
    zrzi_upper_all_zeros = ~|s2_zrzi_round_c[PROD_W-1 : W+FRAC-1];
    zrzi_ovf_c           = ~(zrzi_upper_all_ones | zrzi_upper_all_zeros);
end

    // Stage 4 - combine, test for escape and decide eject vs recycle

    slot_t s4_payload_r;

    logic signed [W-1:0] s4_z_r_new_r, s4_z_i_new_r;
    logic s4_escaped_r;
    logic s4_reached_max_r;
    logic s4_ovf_r;

    // combinational logic for stage 4 outputs
    logic signed [W:0] zr2_minus_zi2_c, z_r_new_w_c, z_i_new_w_c, mag_sq_w_c;
    logic escaped_c, reached_max_c, s4_combine_ovf_c;

    logic signed [W-1:0] z_r_new_c, z_i_new_c;

    always_comb begin
        // do add/subs in 27-bit signed to be safe
        zr2_minus_zi2_c = $signed({s3_zr2_r[W-1], s3_zr2_r}) - $signed({s3_zi2_r[W-1], s3_zi2_r});

        z_r_new_w_c = zr2_minus_zi2_c + $signed({s3_payload_r.c_r[W-1], s3_payload_r.c_r});

        z_i_new_w_c = s3_two_zrzi_r + $signed({s3_payload_r.c_i[W-1], s3_payload_r.c_i});

        mag_sq_w_c = $signed({s3_zr2_r[W-1], s3_zr2_r}) + $signed({s3_zi2_r[W-1], s3_zi2_r});

        //truncate back down to 26 bits, saturating to max magnitude if overflow
        z_r_new_c = z_r_new_w_c[W-1:0];
        z_i_new_c = z_i_new_w_c[W-1:0];

        // overflow if discarded top bit aint the same
        s4_combine_ovf_c =  (z_r_new_w_c[W] ^ z_r_new_w_c[W-1]) | (z_i_new_w_c[W] ^ z_i_new_w_c[W-1]);

        // escape test
        escaped_c = s3_ovf_r | ($signed(mag_sq_w_c) > $signed({1'b0, ESCAPE_THRESH_Q422})); // compare in 27 bits to avoid overflow

        reached_max_c = ((s3_payload_r.iter + 1'b1) == s3_payload_r.max_iter);
    end

    // recycle / ejecct decision and slot[0] next state

    // either eject if escape or max reached, or recycle for another iter

    logic s4_done_c;
    logic s4_eject_now_c;
    logic s4_stall_c;

    assign s4_done_c     = s4_r.valid & (s4_escaped_r | s4_reached_max_r);
    assign s4_eject_now_c = s4_done_c & out_ready;
    assign s4_stall_c    = s4_done_c & ~out_ready;

    logic advance;
    assign advance = ~s4_stall_c; // can advance if not stalled in stage 4
    assign in_ready = advance & (s4_eject_now_c | ~s4_r.valid);
    
    assign out_valid = s4_done_c;
    assign out_seq = s4_r.seq;
    assign out_iter = s4_r.iter;
    assign out_z_r = s4_r.z_r;
    assign out_z_i = s4_r.z_i;
    assign out_escaped = s4_escaped_r;
    assign out_overflow = s4_r.overflow;

    // s0 next-state logic

    slot_t s0_next_c;

    always_comb begin
        if (~advance) begin
            s0_next_c = s0_r; // hold if stage 4 is stalled
        end 
        else if (s4_eject_now_c | ~s4_r.valid) begin
            if (in_valid) begin
                s0_next_c.valid = 1'b1;
                s0_next_c.seq = in_seq;
                s0_next_c.mode = in_mode;
                s0_next_c.max_iter = in_max_iter;
                s0_next_c.iter = '0;
                s0_next_c.c_r = in_c_r;
                s0_next_c.c_i = in_c_i;
                s0_next_c.z_r = in_z0_r;
                s0_next_c.z_i = in_z0_i;
                s0_next_c.overflow = 1'b0; // no overflow at the start
            end 
            else begin
                s0_next_c.valid = 1'b0; // bubble
            end
        end
        else begin
            s0_next_c.valid    = 1'b1;
            s0_next_c.seq      = s4_r.seq;
            s0_next_c.mode     = s4_r.mode;
            s0_next_c.max_iter = s4_r.max_iter;
            s0_next_c.iter     = s4_r.iter;    // already incremented at s4
            s0_next_c.c_r      = s4_r.c_r;
            s0_next_c.c_i      = s4_r.c_i;
            s0_next_c.z_r      = s4_r.z_r;     // already updated at s4
            s0_next_c.z_i      = s4_r.z_i;
            s0_next_c.overflow = s4_r.overflow;
        end
    end

    // pip reg updates

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s0_r          <= '0;
            s1_payload_r  <= '0;
            s1_zm_r       <= '0;
            s1_zm_i       <= '0;
            s2_payload_r  <= '0;
            s2_zr2_full_r <= '0;
            s2_zi2_full_r <= '0;
            s2_zrzi_full_r<= '0;
            s3_payload_r  <= '0;
            s3_zr2_r      <= '0;
            s3_zi2_r      <= '0;
            s3_two_zrzi_r <= '0;
            s3_ovf_r      <= '0;
            s4_r          <= '0;
            s4_z_r_new_r  <= '0;
            s4_z_i_new_r  <= '0;
            s4_escaped_r  <= '0;
            s4_reached_max_r <= '0;
            s4_ovf_r      <= '0;
        end
        else if (advance) begin
            // s0 takes from the mux above
            s0_r <= s0_next_c;
 
            // s0 -> s1: register modified z operands and carry payload
            s1_payload_r <= s0_r;
            s1_zm_r      <= s0_zm_r;
            s1_zm_i      <= s0_zm_i;
 
            // s1 -> s2: compute the three full products
            s2_payload_r   <= s1_payload_r;
            s2_zr2_full_r  <= s1_zm_r * s1_zm_r;
            s2_zi2_full_r  <= s1_zm_i * s1_zm_i;
            s2_zrzi_full_r <= s1_zm_r * s1_zm_i;
 
            // s2 -> s3: round to Q4.22, latch overflow flags
            s3_payload_r  <= s2_payload_r;
            s3_zr2_r      <= zr2_q422_c;
            s3_zi2_r      <= zi2_q422_c;
            s3_two_zrzi_r <= two_zrzi_q523_c;
            s3_ovf_r      <= s2_payload_r.overflow | zr2_ovf_c | zi2_ovf_c | zrzi_ovf_c;
 
            // s3 -> s4: combine and decide
            s4_r.valid    <= s3_payload_r.valid;
            s4_r.seq      <= s3_payload_r.seq;
            s4_r.mode     <= s3_payload_r.mode;
            s4_r.max_iter <= s3_payload_r.max_iter;
            s4_r.c_r <= s3_payload_r.c_r;
            s4_r.c_i <= s3_payload_r.c_i;
            
            if (escaped_c) begin
                // Current z has already escaped, do not count another iteration.
                s4_r.iter <= s3_payload_r.iter;
                s4_r.z_r  <= s3_payload_r.z_r;
                s4_r.z_i  <= s3_payload_r.z_i;
            end
            else begin
                // Current z has not escaped, so perform one more iteration.
                s4_r.iter <= s3_payload_r.iter + 1'b1;
                s4_r.z_r  <= z_r_new_c;
                s4_r.z_i  <= z_i_new_c;
            end
            
            s4_r.overflow <= s3_ovf_r | s4_combine_ovf_c;
            
            s4_escaped_r     <= escaped_c;
            s4_reached_max_r <= ~escaped_c & reached_max_c;
        end
        // else: advance=0, pipeline holds everything, no register updates
    end

endmodule

`default_nettype wire

