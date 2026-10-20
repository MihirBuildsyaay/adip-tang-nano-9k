// -----------------------------------------------------------------------------
// accumulator.v
// Registered partial-sum accumulator used four times per PE (one per lane).
//   psum_out <= psum_in + prod      (psum_in comes from the PE above)
// Two's complement: prod is sign-extended.
// -----------------------------------------------------------------------------
module accumulator #(
    parameter IN_W  = 11,
    parameter ACC_W = 13
)(
    input  wire             clk,
    input  wire             clr,
    input  wire [ACC_W-1:0] psum_in,
    input  wire [IN_W-1:0]  prod,
    output reg  [ACC_W-1:0] psum_out
);
    always @(posedge clk) begin
        if (clr) psum_out <= {ACC_W{1'b0}};
        else     psum_out <= psum_in + {{(ACC_W-IN_W){prod[IN_W-1]}}, prod};
    end
endmodule
