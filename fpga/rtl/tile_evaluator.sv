module tile_evaluator#(
    parameter int ITER_W    =  16,
    parameter int TILE_W    =  10
)(
    input logic  clk,
    input logic  rst_n,

    // Inputs from Arbiter
    input logic                 in_valid,
    input logic                 in_is_perimeter,
    input logic [ITER_W-1:0]    in_iter,
    input logic [TILE_W-1:0]    in_tile_id,

    // Outputs to scheduler
    output logic out_tile_is_uniform,
    output logic out_eval_done
);

logic [6:0]        perimeter_val;
logic [ITER_W-1:0] latched_iter;
logic               mismatch;

always_ff @(posedge clk) begin
    if(!rst_n) begin
        perimeter_val       <=  '0;
        out_tile_is_uniform <=  1'b0;
        out_eval_done       <=  1'b0;
        latched_iter        <=  '0;
        mismatch            <=  1'b1;
    end
    else begin
        out_tile_is_uniform <= 0;
        out_eval_done       <= 0;

        if(in_is_perimeter && in_valid) begin

            if(perimeter_val == 0) begin
                latched_iter <= in_iter;
                mismatch     <= 1'b1;
                perimeter_val<= perimeter_val + 1'b1;
            end
            else begin
                if(in_iter != latched_iter) mismatch <= 1'b0;

                if(perimeter_val == 7'd91) begin
                    out_eval_done <= 1'b1;
                    out_tile_is_uniform <= mismatch & (in_iter == latched_iter);
                    perimeter_val <= '0;
                end
                else perimeter_val <= perimeter_val + 1'b1;
            end
        end
    end
end

endmodule
