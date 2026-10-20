// -----------------------------------------------------------------------------
// uart_cmd.v  -  command parser for bytes received from the PC
//
//  'M' <m>         set precision mode, m = 0/1/2 (or ASCII '0'/'1'/'2')
//                    0 = 8b x 8b, 1 = 8b x 4b, 2 = 8b x 2b
//  '0' '1' '2'     shortcut: set mode directly (easy to type in a terminal)
//  'I'             signed arithmetic: A = INT8, B = INT8 / INT4 / INT2
//  'U'             unsigned arithmetic (power-up default)
//  'A' <N*N bytes> load activation matrix A, row-major
//  'W' <N*N bytes> load packed weight bytes, row-major (one byte per PE):
//                    8x8: the 8-bit weight
//                    8x4: two 4-bit weights  {B[r][2c+1], B[r][2c]}
//                    8x2: four 2-bit weights {B[r][4c+3], ..., B[r][4c]}
//  'S'             start the computation (result is printed over UART)
//
// Unknown bytes are ignored. If a multi-byte command stops half way, the
// parser returns to idle after TIMEOUT clocks without a byte (~50 ms).
// -----------------------------------------------------------------------------
module uart_cmd #(
    parameter N       = 4,
    parameter AW      = 4,              // clog2(N*N)
    parameter TIMEOUT = 1350000
)(
    input  wire          clk,
    input  wire          rst_n,
    input  wire          rx_valid,
    input  wire [7:0]    rx_data,
    output reg           mode_set,      // 1-cycle pulse
    output reg  [1:0]    mode_val,
    output reg           sign_set,      // 1-cycle pulse
    output reg           sign_val,      // 1 = signed
    output reg           a_we,          // 1-cycle write strobe for input memory
    output reg           w_we,          // 1-cycle write strobe for weight memory
    output reg  [AW-1:0] waddr,
    output reg  [7:0]    wdata,
    output reg           start          // 1-cycle pulse
);
    localparam [1:0] C_IDLE = 2'd0, C_MODE = 2'd1, C_A = 2'd2, C_W = 2'd3;

    reg [1:0]  st;
    reg [AW:0] cnt;
    reg [21:0] tmo;

    always @(posedge clk) begin
        if (!rst_n) begin
            st       <= C_IDLE;
            cnt      <= {(AW+1){1'b0}};
            tmo      <= 22'd0;
            mode_set <= 1'b0;
            mode_val <= 2'd0;
            sign_set <= 1'b0;
            sign_val <= 1'b0;
            a_we     <= 1'b0;
            w_we     <= 1'b0;
            waddr    <= {AW{1'b0}};
            wdata    <= 8'd0;
            start    <= 1'b0;
        end else begin
            mode_set <= 1'b0;
            sign_set <= 1'b0;
            a_we     <= 1'b0;
            w_we     <= 1'b0;
            start    <= 1'b0;

            // timeout for unfinished commands
            if (st == C_IDLE || rx_valid)  tmo <= 22'd0;
            else if (tmo == TIMEOUT - 1) begin
                tmo <= 22'd0;
                st  <= C_IDLE;
            end else tmo <= tmo + 22'd1;

            if (rx_valid) begin
                case (st)
                    C_IDLE: begin
                        case (rx_data)
                            "M", "m":           st <= C_MODE;
                            "A", "a":           begin st <= C_A; cnt <= {(AW+1){1'b0}}; end
                            "W", "w", "B", "b": begin st <= C_W; cnt <= {(AW+1){1'b0}}; end
                            "S", "s", "G", "g": start <= 1'b1;
                            "0", "1", "2":      begin mode_set <= 1'b1; mode_val <= rx_data[1:0]; end
                            "I", "i":           begin sign_set <= 1'b1; sign_val <= 1'b1; end
                            "U", "u":           begin sign_set <= 1'b1; sign_val <= 1'b0; end
                            default: ;                                   // ignore
                        endcase
                    end

                    C_MODE: begin
                        mode_set <= 1'b1;
                        mode_val <= (rx_data[1:0] == 2'd3) ? 2'd2 : rx_data[1:0];
                        st       <= C_IDLE;
                    end

                    default: begin                                       // C_A / C_W
                        if (st == C_A) a_we <= 1'b1;
                        else           w_we <= 1'b1;
                        waddr <= cnt[AW-1:0];
                        wdata <= rx_data;
                        if (cnt == N*N - 1) st <= C_IDLE;
                        cnt <= cnt + 1'b1;
                    end
                endcase
            end
        end
    end
endmodule
