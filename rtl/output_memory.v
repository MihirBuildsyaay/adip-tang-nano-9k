// -----------------------------------------------------------------------------
// output_memory.v  -  result matrix C with de-skewing capture logic
//
// One small memory per array column (word = 4 slots x OUT_W bits).
// In cycle `cap_cnt`, column c holds the finished result of row
//        m = cap_cnt - N - c            (valid for 0 <= m < N)
// and writes it to cmem[m]. Read port: (rd_row, rd_col) -> 4-slot word.
// -----------------------------------------------------------------------------
module output_memory #(
    parameter N  = 4,
    parameter IW = 2,         // clog2(N)
    parameter CW = 4,         // clog2(3*N)
    parameter SW = 76         // slot-word width = 4*OUT_W
)(
    input  wire              clk,
    input  wire              cap_en,
    input  wire [CW-1:0]     cap_cnt,
    input  wire [N*SW-1:0]   col_slots_flat,
    input  wire [IW-1:0]     rd_row,
    input  wire [IW-1:0]     rd_col,
    output wire [SW-1:0]     rd_data
);
    wire [N*SW-1:0] rd_cols;

    genvar c;
    generate
        for (c = 0; c < N; c = c + 1) begin : g_col
            reg  [SW-1:0] cmem [0:N-1];
            wire          valid = cap_en && (cap_cnt >= N + c) && ((cap_cnt - N - c) < N);
            wire [IW-1:0] wrow  = cap_cnt - N - c;

            always @(posedge clk) begin
                if (valid) cmem[wrow] <= col_slots_flat[c*SW +: SW];
            end

            assign rd_cols[c*SW +: SW] = cmem[rd_row];
        end
    endgenerate

    assign rd_data = rd_cols[rd_col*SW +: SW];
endmodule
