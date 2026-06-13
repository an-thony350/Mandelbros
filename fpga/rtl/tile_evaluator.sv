`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: Mandelbros
// Engineer: Anthony Bartlett & Denzil Erza-Essien
// 
// Create Date: 12.06.2026 15:26:00
// Design Name: Tile Evaluator
// Module Name: tile_evaluator
// Project Name: FractalScope
// Target Devices: PYNQ-Z1
// Tool Versions: Vivado 2023.2
// Description: Evaluates if the perimeter of a tile all have the same iteration value and will output a 
//              signal if so
// 
// Dependencies: None
// 
// Revision 0.01 - File Created
// Additional Comments: None
// 
//////////////////////////////////////////////////////////////////////////////////


module tile_evaluator#(
    parameter int ITER_W    =  16,
    parameter int TILE_W    =  4
)(
    input logic  clk,
    input logic  rst_n,

    // Inputs from Arbiter
    input logic                 in_valid,
    input logic                 in_is_perimeter,
    input logic [ITER_W-1:0]    in_iter,
    input logic                 in_escaped,
    input logic [TILE_W-1:0]    in_tile_id,
    input logic                 in_ready,
    
    // Input from slv registers
    input logic [3:0]           in_scale,

    // Outputs to scheduler
    output logic                out_tile_is_uniform,
    output logic                out_eval_done,
    output logic [ITER_W-1:0]   out_eval_iter,
    output logic                out_eval_escaped
);

logic [6:0]        perimeter_val;
logic [ITER_W-1:0] latched_iter;
logic              latched_escaped;
logic              mismatch;
logic [6:0]        expected_perimeter;


assign out_eval_iter    = latched_iter;
assign out_eval_escaped = latched_escaped;

// scaling logic for progressive rendering

always_comb begin
    case(in_scale)
        4'd1:   expected_perimeter = 7'd91;
        4'd2:   expected_perimeter = 7'd43;
        4'd4:   expected_perimeter = 7'd19;
        4'd8:   expected_perimeter = 7'd7;
        default: expected_perimeter= 7'd91;
    endcase
end

always_ff @(posedge clk) begin
    if(!rst_n) begin
        perimeter_val       <=  '0;
        out_tile_is_uniform <=  1'b0;
        out_eval_done       <=  1'b0;
        latched_iter        <=  '0;
        latched_escaped     <=  '0;
        mismatch            <=  1'b1;
    end
    else begin
        out_tile_is_uniform <= 0;
        out_eval_done       <= 0;

        if(in_is_perimeter && in_valid && in_ready) begin

            if(perimeter_val == 0) begin
                latched_iter <= in_iter;
                latched_escaped <= in_escaped;
                mismatch     <= 1'b1;
                perimeter_val<= perimeter_val + 1'b1;
            end
            else begin
                if(in_iter != latched_iter || in_escaped != latched_escaped) mismatch <= 1'b0;

                if(perimeter_val == expected_perimeter) begin
                    out_eval_done <= 1'b1;
                    out_tile_is_uniform <= mismatch & (in_iter == latched_iter) & (in_escaped == latched_escaped);
                    perimeter_val <= '0;
                end
                else perimeter_val <= perimeter_val + 1'b1;
            end
        end
    end
end

endmodule
