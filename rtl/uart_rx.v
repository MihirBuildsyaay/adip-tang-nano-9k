// -----------------------------------------------------------------------------
// uart_rx.v  -  8N1 UART receiver (PC -> FPGA)
// Default: 27 MHz / 115200 baud = 234 clocks per bit.
// Samples each bit in its middle; `valid` pulses for one clock with `data`
// when a byte with a correct stop bit has been received.
// -----------------------------------------------------------------------------
module uart_rx #(
    parameter CLKS_PER_BIT = 234
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg        valid,
    output reg  [7:0] data
);
    localparam [1:0] R_IDLE = 2'd0, R_START = 2'd1, R_DATA = 2'd2, R_STOP = 2'd3;

    reg [1:0]  sync;        // 2-FF synchroniser (rx is asynchronous)
    reg [1:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shreg;

    wire rxs = sync[1];

    always @(posedge clk) begin
        if (!rst_n) begin
            sync    <= 2'b11;
            st      <= R_IDLE;
            cnt     <= 16'd0;
            bit_idx <= 3'd0;
            shreg   <= 8'd0;
            valid   <= 1'b0;
            data    <= 8'd0;
        end else begin
            sync  <= {sync[0], rx};
            valid <= 1'b0;
            case (st)
                R_IDLE: begin
                    cnt <= 16'd0;
                    if (!rxs) st <= R_START;               // falling edge = start bit
                end

                R_START: begin                             // check middle of start bit
                    if (cnt == CLKS_PER_BIT/2 - 1) begin
                        cnt <= 16'd0;
                        if (!rxs) begin
                            bit_idx <= 3'd0;
                            st      <= R_DATA;
                        end else begin
                            st <= R_IDLE;                  // glitch, not a start bit
                        end
                    end else cnt <= cnt + 16'd1;
                end

                R_DATA: begin                              // sample middle of each bit
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt            <= 16'd0;
                        shreg[bit_idx] <= rxs;
                        if (bit_idx == 3'd7) st <= R_STOP;
                        else                 bit_idx <= bit_idx + 3'd1;
                    end else cnt <= cnt + 16'd1;
                end

                R_STOP: begin                              // middle of stop bit
                    if (cnt == CLKS_PER_BIT - 1) begin
                        cnt <= 16'd0;
                        st  <= R_IDLE;
                        if (rxs) begin
                            valid <= 1'b1;
                            data  <= shreg;
                        end
                    end else cnt <= cnt + 16'd1;
                end
            endcase
        end
    end
endmodule
