module reset_sync (
    input  logic i_clk,
    input  logic i_async_n_reset,
    output logic o_n_reset
);
    logic ff1;
    always_ff @(posedge i_clk or negedge i_async_n_reset) begin
        if (!i_async_n_reset) begin
            ff1       <= 1'b0;
            o_n_reset <= 1'b0;
        end else begin
            ff1       <= 1'b1;
            o_n_reset <= ff1;
        end
    end
endmodule
