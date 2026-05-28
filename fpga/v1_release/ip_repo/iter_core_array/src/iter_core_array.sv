`timescale 1ns / 1ps

(* keep_hierarchy = "yes" *)
module iter_core_array #(
    parameter int NUM_CORES = 16,
    parameter int W         = 26,
    parameter int FRAC      = 22,
    parameter int SEQ_W     = 20,
    parameter int ITER_W    = 16,
    parameter int MODE_W    = 3,
    parameter logic [W-1:0] ESCAPE_THRESH_Q422 = 26'sh100_0000 
)(
    input  wire clk,
    input  wire rst_n,

    // Inputs from Pixel Scheduler
    input  wire [NUM_CORES-1:0]          in_valid,
    input  wire [(W*NUM_CORES)-1:0]      c_r,
    input  wire [(W*NUM_CORES)-1:0]      c_i,
    input  wire [(W*NUM_CORES)-1:0]      z0_r,
    input  wire [(W*NUM_CORES)-1:0]      z0_i,
    input  wire [(ITER_W*NUM_CORES)-1:0] in_max_iter,
    input  wire [(MODE_W*NUM_CORES)-1:0] in_mode,
    input  wire [(SEQ_W*NUM_CORES)-1:0]  in_seq,

    // Outputs back to Pixel Scheduler
    output wire [NUM_CORES-1:0]          in_ready,

    // Inputs from Reorder Buffer
    input  wire                          out_ready,

    // Outputs to Reorder Buffer
    output wire               out_valid,
    output wire  [SEQ_W-1:0]  out_seq,
    output wire  [ITER_W-1:0] out_iter,
    output wire  [W-1:0]      out_z_r,
    output wire  [W-1:0]      out_z_i,
    output wire               out_escaped,
    output wire               out_overflow
);

    // By calculating the exact bit offsets, we avoid structs entirely.
    localparam int OVF_BIT  = 0;
    localparam int ESC_BIT  = 1;
    localparam int ZI_BIT   = 2;
    localparam int ZR_BIT   = ZI_BIT + W;
    localparam int ITER_BIT = ZR_BIT + W;
    localparam int SEQ_BIT  = ITER_BIT + ITER_W;
    localparam int TOTAL_W  = SEQ_BIT + SEQ_W;

    // Handshake wires
    wire [NUM_CORES-1:0] raw_out_valid;
    wire [NUM_CORES-1:0] raw_out_ready;
    wire [NUM_CORES-1:0] core_out_valid;
    wire [NUM_CORES-1:0] core_out_ready;

    // Flat arrays strictly for the Arbiter input
    wire [(SEQ_W*NUM_CORES)-1:0]  core_out_seq;
    wire [(ITER_W*NUM_CORES)-1:0] core_out_iter;
    wire [(W*NUM_CORES)-1:0]      core_out_z_r;
    wire [(W*NUM_CORES)-1:0]      core_out_z_i;
    wire [NUM_CORES-1:0]          core_out_escaped;
    wire [NUM_CORES-1:0]          core_out_overflow;
    
    // iter_core blocks
    generate
        for (genvar i = 0; i < NUM_CORES; i++) begin : core_gen
            
            // Local wires exclusively for THIS specific core
            wire [SEQ_W-1:0]  c_seq;
            wire [ITER_W-1:0] c_iter;
            wire [W-1:0]      c_z_r;
            wire [W-1:0]      c_z_i;
            wire              c_esc;
            wire              c_ovf;
            
            wire [TOTAL_W-1:0] skid_in_wire;
            wire [TOTAL_W-1:0] skid_out_wire;

            iter_core #(
                .W(W),
                .FRAC(FRAC),
                .SEQ_W(SEQ_W),
                .ITER_W(ITER_W),
                .MODE_W(MODE_W),
                .ESCAPE_THRESH_Q422(ESCAPE_THRESH_Q422)
            ) single_core (
                .clk(clk),
                .rst_n(rst_n),

                // Scheduler Handshake
                .in_ready   ( in_ready[i] ),
                .in_valid   ( in_valid[i] ),
                
                // Sliced Inputs
                .in_c_r     ( c_r[(i*W) +: W] ),
                .in_c_i     ( c_i[(i*W) +: W] ),
                .in_z0_r    ( z0_r[(i*W) +: W] ),
                .in_z0_i    ( z0_i[(i*W) +: W] ),
                .in_max_iter( in_max_iter[(i*ITER_W) +: ITER_W] ),
                .in_mode    ( in_mode[(i*MODE_W) +: MODE_W] ),
                .in_seq     ( in_seq[(i*SEQ_W) +: SEQ_W] ),

                // Handshake straight to skid buffer
                .out_ready  ( raw_out_ready[i] ),
                .out_valid  ( raw_out_valid[i] ),
                
                // Maps into local wires
                .out_seq    ( c_seq ),
                .out_iter   ( c_iter ),
                .out_z_r    ( c_z_r ),
                .out_z_i    ( c_z_i ),
                .out_escaped( c_esc ),
                .out_overflow( c_ovf )
            );
            
            // EXPLICIT COMBINATIONAL PACKING
            assign skid_in_wire[OVF_BIT]            = c_ovf;
            assign skid_in_wire[ESC_BIT]            = c_esc;
            assign skid_in_wire[ZI_BIT   +: W]      = c_z_i;
            assign skid_in_wire[ZR_BIT   +: W]      = c_z_r;
            assign skid_in_wire[ITER_BIT +: ITER_W] = c_iter;
            assign skid_in_wire[SEQ_BIT  +: SEQ_W]  = c_seq;
            
            // The Skid Buffer
            skid_buffer_m#(
                .INPUT_DATA( TOTAL_W ) 
            ) skid_inst (
                .clk(clk),
                .rst_n(rst_n), 
                .in_valid (raw_out_valid[i]),
                .in_ready(raw_out_ready[i]), // ...
                .in_data  (skid_in_wire),
                
                .out_ready (core_out_ready[i]), // ...   
                .out_valid(core_out_valid[i]),
                .out_data (skid_out_wire)      
            );
            
            // EXPLICIT COMBINATIONAL UNPACKING TO FLAT ARRAYS
            assign core_out_seq[(i*SEQ_W)  +: SEQ_W]   = skid_out_wire[SEQ_BIT  +: SEQ_W];
            assign core_out_iter[(i*ITER_W) +: ITER_W] = skid_out_wire[ITER_BIT +: ITER_W];
            assign core_out_z_r[(i*W)      +: W]       = skid_out_wire[ZR_BIT   +: W];
            assign core_out_z_i[(i*W)      +: W]       = skid_out_wire[ZI_BIT   +: W];
            assign core_out_escaped[i]                 = skid_out_wire[ESC_BIT];
            assign core_out_overflow[i]                = skid_out_wire[OVF_BIT];
        end
    endgenerate
    
    // =========================================================
    // RESULT ARBITER
    // =========================================================
    wire               arb_valid;
    wire               arb_ready;
    wire [SEQ_W-1:0]   arb_seq;
    wire [ITER_W-1:0]  arb_iter;
    wire [W-1:0]       arb_z_r;
    wire [W-1:0]       arb_z_i;
    wire               arb_escaped;
    wire               arb_overflow;

    result_arbiter#(
        .NUM_CORES(NUM_CORES),
        .W(W),
        .ITER_W(ITER_W),
        .SEQ_W(SEQ_W)
    ) arbiter(
        .clk(clk),
        .rst_n(rst_n), 
        
        .core_out_valid(core_out_valid),
        .core_out_ready(core_out_ready),
        .core_out_seq  (core_out_seq),
        .core_out_iter (core_out_iter),
        .core_out_z_r  (core_out_z_r),
        .core_out_z_i  (core_out_z_i),
        .core_out_escaped (core_out_escaped),
        .core_out_overflow(core_out_overflow),
        
        // Output to our new isolating skid buffer instead of directly out
        .rob_in_valid(arb_valid),
        .rob_in_ready(arb_ready),
        .rob_in_iter_count(arb_iter),
        .rob_in_seq_num(arb_seq),
        .rob_in_z_r(arb_z_r),
        .rob_in_z_i(arb_z_i),
        .rob_in_escaped(arb_escaped),
        .rob_in_overflow(arb_overflow)
    );

    // =========================================================
    // FINAL PIPELINE ISOLATION (The Timing Fix)
    // =========================================================
    wire [TOTAL_W-1:0] final_skid_in;
    wire [TOTAL_W-1:0] final_skid_out;

    // Pack the arbiter output
    assign final_skid_in[OVF_BIT]            = arb_overflow;
    assign final_skid_in[ESC_BIT]            = arb_escaped;
    assign final_skid_in[ZI_BIT   +: W]      = arb_z_i;
    assign final_skid_in[ZR_BIT   +: W]      = arb_z_r;
    assign final_skid_in[ITER_BIT +: ITER_W] = arb_iter;
    assign final_skid_in[SEQ_BIT  +: SEQ_W]  = arb_seq;

    // The isolating skid buffer
    skid_buffer_m#(
        .INPUT_DATA( TOTAL_W ) 
    ) final_skid (
        .clk(clk),
        .rst_n(rst_n), 
        .in_valid (arb_valid),
        .in_ready (arb_ready),
        .in_data  (final_skid_in),
        
        // Output to the Reorder Buffer
        .out_valid (out_valid),
        .out_ready (out_ready),
        .out_data  (final_skid_out)      
    );

    // Unpack directly to the module outputs
    assign out_seq      = final_skid_out[SEQ_BIT  +: SEQ_W];
    assign out_iter     = final_skid_out[ITER_BIT +: ITER_W];
    assign out_z_r      = final_skid_out[ZR_BIT   +: W];
    assign out_z_i      = final_skid_out[ZI_BIT   +: W];
    assign out_escaped  = final_skid_out[ESC_BIT];
    assign out_overflow = final_skid_out[OVF_BIT];
endmodule