// -----------------------------------------------------------------------------
// adip_pe.v  -  ADiP-style reconfigurable processing element
//
//  * stationary packed weight register (8 bit = 4 x 2-bit chunks)
//  * input (activation) register passed on to the next PE to the right
//  * 16 x 2-bit multipliers (reconfigurable_multiplier)
//  * four partial-sum accumulators, one per lane (two's complement)
//
// The PE itself is precision-agnostic: the precision mode only decides how the
// four lane sums are grouped by the shared shifter at the bottom of the column
// (this is the "shared shifter/accumulator" idea of ADiP). x_s / w_s select
// signed INT8 arithmetic (see reconfigurable_multiplier.v).
// -----------------------------------------------------------------------------
module adip_pe #(
    parameter PSUM_W = 13
)(
    input  wire                clk,
    input  wire                clr,       // clears a_out + partial sums (not the weight)
    input  wire                w_load,    // load stationary weight
    input  wire [7:0]          w_in,
    input  wire                x_s,       // activations are signed INT8
    input  wire [3:0]          w_s,       // signed weight chunks (from the mode)
    input  wire [7:0]          a_in,      // activation from the left
    input  wire [4*PSUM_W-1:0] psum_in,   // 4 lanes from the PE above
    output reg  [7:0]          a_out,     // activation to the right (registered)
    output wire [4*PSUM_W-1:0] psum_out   // 4 lanes to the PE below (registered)
);
    reg  [7:0]  w_reg;
    wire [43:0] lane_p;

    always @(posedge clk) begin
        if (w_load) w_reg <= w_in;
    end

    always @(posedge clk) begin
        if (clr) a_out <= 8'd0;
        else     a_out <= a_in;
    end

    reconfigurable_multiplier u_mul (
        .x      (a_in),
        .x_s    (x_s),
        .w      (w_reg),
        .w_s    (w_s),
        .lane_p (lane_p)
    );

    genvar j;
    generate
        for (j = 0; j < 4; j = j + 1) begin : g_acc
            accumulator #(.IN_W(11), .ACC_W(PSUM_W)) u_acc (
                .clk      (clk),
                .clr      (clr),
                .psum_in  (psum_in[j*PSUM_W +: PSUM_W]),
                .prod     (lane_p[11*j +: 11]),
                .psum_out (psum_out[j*PSUM_W +: PSUM_W])
            );
        end
    endgenerate
endmodule
