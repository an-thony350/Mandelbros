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

// required
(* keep_hierarchy = "yes" *)
module skid_buffer_m#(
    parameter int INPUT_DATA = 90
)(
    input logic         clk,
    input logic         rst,
    
    input logic         in_valid,
    input logic         in_ready,
    input logic [INPUT_DATA-1:0]    in_data,
    
    output logic            out_valid,
    output logic            out_ready,
    output logic [INPUT_DATA-1:0]   out_data
    );
    
    
    logic [INPUT_DATA-1:0] buf_data;
    logic                  buf_valid;
    
    assign out_ready = in_ready | ~buf_valid;
    
    assign out_valid = buf_valid | in_valid;
    
    assign out_data  = buf_valid ? buf_data : in_data;

    always_ff @(posedge clk) begin
        if (rst) begin
            buf_valid <= 1'b0;
            buf_data  <= '0;
        end else begin
            // If the input is valid, but the output is stalled, we must "skid" 
            // and save the data into our holding buffer.
            if (in_valid && out_ready && !in_ready) begin
                buf_valid <= 1'b1;
                buf_data  <= in_data;
            end 
            else if (in_ready) begin
                buf_valid <= 1'b0;
            end
        end
    end
endmodule
