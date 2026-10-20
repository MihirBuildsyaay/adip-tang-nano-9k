// -----------------------------------------------------------------------------
// weight_memory.v  -  N*N packed weight bytes, asynchronous read.
// Reset values are a fixed demo pattern: W[i] = (73*i + 41) mod 256.
// The same bytes are re-interpreted per precision mode (8x8: one 8-bit weight,
// 8x4: two 4-bit weights, 8x2: four 2-bit weights). Write port is for testbenches.
// -----------------------------------------------------------------------------
module weight_memory #(
    parameter N  = 4,
    parameter AW = 4          // clog2(N*N)
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          wr_en,
    input  wire [AW-1:0] wr_addr,
    input  wire [7:0]    wr_data,
    input  wire [AW-1:0] rd_addr,
    output wire [7:0]    rd_data,
    input  wire [AW-1:0] dbg_addr,    // second (UART report) read port
    output wire [7:0]    dbg_data
);
    reg [7:0] mem [0:N*N-1];
    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < N*N; i = i + 1)
                mem[i] <= (73*i + 41) & 8'hFF;
        end else if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    assign rd_data  = mem[rd_addr];
    assign dbg_data = mem[dbg_addr];
endmodule
