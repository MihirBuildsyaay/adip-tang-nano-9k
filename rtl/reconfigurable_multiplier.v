// -----------------------------------------------------------------------------
// reconfigurable_multiplier.v
// Sixteen 2-bit multipliers organised as four "lanes" (groups of four), exactly
// like the ADiP reconfigurable PE.
//
//   x      : 8-bit activation           = x3.x2.x1.x0  (2-bit chunks)
//   w      : 8-bit packed weight word   = w3.w2.w1.w0  (2-bit chunks)
//   lane j : x * w_j   (8b x 2b -> 11b signed)
//          = sum_i (x_i * w_j) << 2i
//
// Signed (INT8) support: x is two's complement when x_s = 1 (only chunk x3 is
// signed); chunk w_j is the signed top chunk of a weight when w_s[j] = 1.
// With x_s = 0 and w_s = 0 everything is unsigned (results are >= 0).
//
// The lanes are NOT combined here. Combining them (shift & add) is done once per
// column in shared_shifter.v, selected by the precision mode:
//   8b x 8b : weight = w3.w2.w1.w0   -> 1 weight  per 8-bit word
//   8b x 4b : weights = (w3.w2),(w1.w0) -> 2 weights per word
//   8b x 2b : weights = w3,w2,w1,w0 -> 4 weights per word
// -----------------------------------------------------------------------------
module reconfigurable_multiplier (
    input  wire [7:0]  x,
    input  wire        x_s,       // x is signed INT8
    input  wire [7:0]  w,
    input  wire [3:0]  w_s,       // chunk w_j is a signed top chunk
    output wire [43:0] lane_p     // {lane3, lane2, lane1, lane0}, 11 bits each, signed
);
    genvar i, j;
    generate
        for (j = 0; j < 4; j = j + 1) begin : g_lane
            wire [19:0] pp;       // four 5-bit signed partial products
            wire [10:0] sum;
            for (i = 0; i < 4; i = i + 1) begin : g_mul
                multiplier_2bit u_m2 (
                    .a   (x[2*i +: 2]),
                    .a_s ((i == 3) ? x_s : 1'b0),
                    .b   (w[2*j +: 2]),
                    .b_s (w_s[j]),
                    .p   (pp[5*i +: 5])
                );
            end
            assign sum = {{6{pp[4]}},  pp[4:0]}
                       + {{4{pp[9]}},  pp[9:5],   2'b0}
                       + {{2{pp[14]}}, pp[14:10], 4'b0}
                       + {             pp[19:15], 6'b0};
            assign lane_p[11*j +: 11] = sum;
        end
    endgenerate
endmodule
