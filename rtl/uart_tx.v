// -----------------------------------------------------------------------------
// uart_tx.v  -  8N1 UART transmitter
// Default: 27 MHz / 115200 baud = 234 clocks per bit (0.16 % error).
// `send` is accepted only while idle (busy = 0); data is latched on acceptance.
// -----------------------------------------------------------------------------
module uart_tx #(
    parameter CLKS_PER_BIT = 234
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       send,
    input  wire [7:0] data,
    output reg        tx,
    output wire       busy
);
    localparam [1:0] T_IDLE = 2'd0, T_START = 2'd1, T_DATA = 2'd2, T_STOP = 2'd3;

    reg [1:0]  st;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shreg;

    always @(posedge clk) begin
        if (!rst_n) begin
            st      <= T_IDLE;
            tx      <= 1'b1;
            clk_cnt <= 16'd0;
            bit_idx <= 3'd0;
            shreg   <= 8'd0;
        end else begin
            case (st)
                T_IDLE: begin
                    tx      <= 1'b1;
                    clk_cnt <= 16'd0;
                    bit_idx <= 3'd0;
                    if (send) begin
                        shreg <= data;
                        st    <= T_START;
                    end
                end

                T_START: begin
                    tx <= 1'b0;
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
                        st      <= T_DATA;
                    end else clk_cnt <= clk_cnt + 16'd1;
                end

                T_DATA: begin
                    tx <= shreg[bit_idx];
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
                        if (bit_idx == 3'd7) st <= T_STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else clk_cnt <= clk_cnt + 16'd1;
                end

                T_STOP: begin
                    tx <= 1'b1;
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
                        st      <= T_IDLE;
                    end else clk_cnt <= clk_cnt + 16'd1;
                end
            endcase
        end
    end

    assign busy = (st != T_IDLE);
endmodule
