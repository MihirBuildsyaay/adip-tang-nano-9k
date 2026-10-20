// -----------------------------------------------------------------------------
// multiplier_2bit.v
// Basic building block of the ADiP reconfigurable PE: 2b x 2b -> 5b signed.
// Each 2-bit chunk is unsigned (0..3) or, if its *_s flag is set, the signed
// top chunk of a two's complement number (-2..1). Product range -6..9.
// -----------------------------------------------------------------------------
module multiplier_2bit (
    input  wire [1:0] a,
    input  wire       a_s,      // a is a signed chunk
    input  wire [1:0] b,
    input  wire       b_s,      // b is a signed chunk
    output wire [4:0] p         // signed
);
    wire signed [2:0] ae = {a_s & a[1], a};
    wire signed [2:0] be = {b_s & b[1], b};
    wire signed [4:0] pe = ae * be;
    assign p = pe;
endmodule
