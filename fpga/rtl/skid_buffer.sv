`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 24.05.2026 15:35:21
// Design Name: 
// Module Name: skid_buffer
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

`timescale 1ns / 1ps

(* keep_hierarchy = "yes" *)
module skid_buffer_m #(
    parameter int INPUT_DATA = 90
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // Upstream (To/From iter_core)
    input  logic                  in_valid,
    output logic                  in_ready,
    input  logic [INPUT_DATA-1:0] in_data,

    // Downstream (To/From result_arbiter)
    output logic                  out_valid,
    input  logic                  out_ready,
    output logic [INPUT_DATA-1:0] out_data
);

    // 2-Deep Memory Array
    logic [INPUT_DATA-1:0] fifo [0:1];
    
    // Pointers and Tracking
    logic       wr_ptr;
    logic       rd_ptr;
    logic [1:0] count;

    // -------------------------------------------------------------------------
    // THE TIMING FIX: 
    // in_ready and out_valid are now driven purely by a local flip-flop (count).
    // There is ZERO combinational path between the Arbiter and the Iter Cores.
    // -------------------------------------------------------------------------
    assign in_ready  = (count < 2'd2);
    assign out_valid = (count > 2'd0);
    assign out_data  = fifo[rd_ptr];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= 1'b0;
            rd_ptr <= 1'b0;
            count  <= 2'd0;
        end
        else begin
            case ({in_valid & in_ready, out_valid & out_ready})
                2'b10: begin // Write only
                    fifo[wr_ptr] <= in_data;
                    wr_ptr       <= ~wr_ptr;
                    count        <= count + 2'd1;
                end
                2'b01: begin // Read only
                    rd_ptr       <= ~rd_ptr;
                    count        <= count - 2'd1;
                end
                2'b11: begin // Simultaneous Write and Read
                    fifo[wr_ptr] <= in_data;
                    wr_ptr       <= ~wr_ptr;
                    rd_ptr       <= ~rd_ptr;
                    // Count remains unchanged
                end
                default: ; // Do nothing
            endcase
        end
    end
endmodule