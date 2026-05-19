module pixel_generator#(
    parameter int W             = 26,
)   (
    input logic                 clk,
    input logic                 rst,
    input logic                 en,
    input logic                 ready,


    output logic signed [W-1:0] x,
    output logic signed [W-1:0] y,
    output logic                valid,
    output logic                sof,
    output logic                eol
);


// Parameters for HDMI resolution

localparam X_RES = 1280;
localparam Y_RES = 720;

// Temporary x and y coord registers

logic [W-1:0] x_tmp;
logic [W-1:0] y_tmp;

always_ff @(posedge clk) begin

    if(rst) begin
        x_tmp <= 0;
        y_tmp <= 0;
        valid <= 0;
    end
    else if(en) begin
        valid <= 1'b1;

        if(ready) begin
        end
    end




end



endmodule