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
    logic signed [W-1:0]        zr2_q422_c, zi2_q422_c;
    logic signed [W:0]          two_zrzi_q523_c;
    logic                       zr2_ovf_c, zi2_ovf_c, zrzi_ovf_c;


    always_comb begin
        // add rounding bias before shifting down to Q4.22
        s2_zr2_round_c   = s2_zr2_full_r   + ROUND_BIAS;
        s2_zi2_round_c   = s2_zi2_full_r   + ROUND_BIAS;
        s2_zrzi_round_c  = s2_zrzi_full_r  + ROUND_BIAS;

        // slice the Q4.22 version
        zr2_q422_c       = s2_zr2_round_c[W+FRAC -1 : FRAC];
        zi2_q422_c       = s2_zi2_round_c[W+FRAC -1 : FRAC];
        two_zrzi_q523_c  = s2_zrzi_round_c[W+FRAC : FRAC]; // one extra bit for potential overflow

        // check overflow - bit above kept range is either all 0 or 1
        zr2_ovf_c = ~(&s2_zr2_round_c [PROD_W - 1 : W + FRAC - 1]) | ~(|s2_zr2_round_c [PROD_W - 1 : W + FRAC - 1]);

        zi2_ovf_c = ~(&s2_zi2_round_c [PROD_W - 1 : W + FRAC - 1]) | ~(|s2_zi2_round_c [PROD_W - 1 : W + FRAC - 1]);

        zrzi_ovf_c = ~(&s2_zrzi_round_c [PROD_W - 1 : W + FRAC]) | ~(|s2_zrzi_round_c [PROD_W - 1 : W + FRAC]);
    end

    // Stage 4 - combine, test for escape and decide eject vs recycle

    slot_t s4_payload_r;

    logic signed [W-1:0] s4_z_r_new_r, s4_z_i_new_r;
    logic s4_escape_r;
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
        zr_new_c = zr_new_w_c[W-1:0];
        zi_new_c = z_i_new_w_c[W-1:0];

        // overflow if discarded top bit aint the same
        s4_combine_ovf_c =  (z_r_new_w_c[W] ^ z_r_new_w_c[W-1]) | (z_i_new_w_c[W] ^ z_i_new_w_c[W-1]);

        // escape test
        escaped_c = ($signed(mag_sq_w_c) > $signed({1'b0, ESCAPE_THRESH_Q422})); // compare in 27 bits to avoid overflow

        reached_max_c = ((s3_payload_r.iter + 1'b1) == s3_payload_r.max_iter);
    end