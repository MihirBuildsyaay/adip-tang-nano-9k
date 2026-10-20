// -----------------------------------------------------------------------------
// shared_shifter.v  -  one instance per array column
//
// Combines the four lane sums of a column according to the precision mode.
//   mode 0 (8b x 8b): slot0 = L0 + L1<<2 + L2<<4 + L3<<6          (1 result)
//   mode 1 (8b x 4b): slot0 = L0 + L1<<2 ; slot1 = L2 + L3<<2     (2 results)
//   mode 2 (8b x 2b): slot k = Lk                                 (4 results)
// Unused slots are zero. Lane sums are two's complement and are sign-extended
// (in unsigned mode they are always >= 0, so this changes nothing there).
// -----------------------------------------------------------------------------
module shared_shifter #(
    parameter PSUM_W = 13,
    parameter OUT_W  = 19
)(
    input  wire [1:0]            mode,
    input  wire [4*PSUM_W-1:0]   lanes,
    output wire [4*OUT_W-1:0]    slots
);
    localparam EW = OUT_W - PSUM_W;
    wire [OUT_W-1:0] l0 = {{EW{lanes[1*PSUM_W-1]}}, lanes[0*PSUM_W +: PSUM_W]};
    wire [OUT_W-1:0] l1 = {{EW{lanes[2*PSUM_W-1]}}, lanes[1*PSUM_W +: PSUM_W]};
    wire [OUT_W-1:0] l2 = {{EW{lanes[3*PSUM_W-1]}}, lanes[2*PSUM_W +: PSUM_W]};
    wire [OUT_W-1:0] l3 = {{EW{lanes[4*PSUM_W-1]}}, lanes[3*PSUM_W +: PSUM_W]};

    wire [OUT_W-1:0] s88   = l0 + (l1 << 2) + (l2 << 4) + (l3 << 6);
    wire [OUT_W-1:0] s84_0 = l0 + (l1 << 2);
    wire [OUT_W-1:0] s84_1 = l2 + (l3 << 2);

    reg [OUT_W-1:0] o0, o1, o2, o3;
    always @* begin
        case (mode)
            2'd0:    begin o0 = s88;   o1 = {OUT_W{1'b0}}; o2 = {OUT_W{1'b0}}; o3 = {OUT_W{1'b0}}; end
            2'd1:    begin o0 = s84_0; o1 = s84_1;         o2 = {OUT_W{1'b0}}; o3 = {OUT_W{1'b0}}; end
            default: begin o0 = l0;    o1 = l1;            o2 = l2;            o3 = l3;            end
        endcase
    end

    assign slots = {o3, o2, o1, o0};
endmodule
