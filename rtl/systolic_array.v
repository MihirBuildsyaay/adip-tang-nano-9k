// -----------------------------------------------------------------------------
// systolic_array.v  -  N x N weight-stationary array of adip_pe
//
//  * weights are loaded one PE per cycle (w_load_row / w_load_col)
//  * activations enter on the left of every row and move one PE per clock
//  * 4-lane partial sums move one PE per clock from top to bottom
//  * col_psum_flat = registered bottom-row lane sums of every column
//
//  (File name kept short; for the report this is the "4x4 array" with N = 4.)
// -----------------------------------------------------------------------------
module systolic_array #(
    parameter N      = 4,
    parameter IW     = 2,            // clog2(N)
    parameter PSUM_W = 13            // 11 + clog2(N)
)(
    input  wire                      clk,
    input  wire                      clr,
    input  wire                      w_load_en,
    input  wire [IW-1:0]             w_load_row,
    input  wire [IW-1:0]             w_load_col,
    input  wire [7:0]                w_load_data,
    input  wire                      x_s,             // signed activations
    input  wire [3:0]                w_s,             // signed weight chunks
    input  wire [8*N-1:0]            a_in_flat,       // one activation per row
    output wire [N*4*PSUM_W-1:0]     col_psum_flat    // 4 lanes per column
);
    localparam LW = 4 * PSUM_W;

    wire [8*N*(N+1)-1:0] a_w;        // activation wires  [row][0..N]
    wire [LW*N*(N+1)-1:0] p_w;       // psum wires        [0..N][col]

    genvar r, c;
    generate
        for (c = 0; c < N; c = c + 1) begin : g_top
            assign p_w[(0*N + c)*LW +: LW] = {LW{1'b0}};
            assign col_psum_flat[c*LW +: LW] = p_w[(N*N + c)*LW +: LW];
        end

        for (r = 0; r < N; r = r + 1) begin : g_row
            assign a_w[(r*(N+1))*8 +: 8] = a_in_flat[r*8 +: 8];
            for (c = 0; c < N; c = c + 1) begin : g_col
                adip_pe #(.PSUM_W(PSUM_W)) u_pe (
                    .clk      (clk),
                    .clr      (clr),
                    .w_load   (w_load_en && (w_load_row == r) && (w_load_col == c)),
                    .w_in     (w_load_data),
                    .x_s      (x_s),
                    .w_s      (w_s),
                    .a_in     (a_w[(r*(N+1) + c)*8 +: 8]),
                    .psum_in  (p_w[(r*N + c)*LW +: LW]),
                    .a_out    (a_w[(r*(N+1) + c + 1)*8 +: 8]),
                    .psum_out (p_w[((r+1)*N + c)*LW +: LW])
                );
            end
        end
    endgenerate
endmodule
