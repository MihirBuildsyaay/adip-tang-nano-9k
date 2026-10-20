// -----------------------------------------------------------------------------
// input_memory.v  -  activation matrix A (N x N bytes, row-major) + skewed feeder
//
// Reset values: A[i] = i + 1  (A = 1..16 for N = 4, as in the project report).
//
// Feeder: in cycle `feed_cnt`, row r of the array receives A[feed_cnt - r][r]
// (zero outside 0..N-1). This is the input skew needed by a systolic array.
// -----------------------------------------------------------------------------
module input_memory #(
    parameter N  = 4,
    parameter AW = 4,         // clog2(N*N)
    parameter CW = 4          // clog2(3*N)
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            wr_en,
    input  wire [AW-1:0]   wr_addr,
    input  wire [7:0]      wr_data,
    input  wire            feed_en,
    input  wire [CW-1:0]   feed_cnt,
    output wire [8*N-1:0]  a_stream,
    input  wire [AW-1:0]   dbg_addr,    // UART report read port
    output wire [7:0]      dbg_data
);
    reg [7:0] mem [0:N*N-1];
    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < N*N; i = i + 1)
                mem[i] <= (i + 1) & 8'hFF;
        end else if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    assign dbg_data = mem[dbg_addr];

    genvar r;
    generate
        for (r = 0; r < N; r = r + 1) begin : g_feed
            wire          in_rng = feed_en && (feed_cnt >= r) && ((feed_cnt - r) < N);
            wire [AW-1:0] idx    = (feed_cnt - r) * N + r;
            assign a_stream[r*8 +: 8] = in_rng ? mem[idx] : 8'd0;
        end
    endgenerate
endmodule
