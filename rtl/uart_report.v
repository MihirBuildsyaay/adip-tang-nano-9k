// -----------------------------------------------------------------------------
// uart_report.v  -  prints A, B and C = A x B as decimal text over UART
//
//   ADiP MODE=8x8
//   A matrix:
//     1   2   3   4
//   ...
//   B matrix (8-bit):
//   ...
//   C = A x B:
//   ...
//   LAT=0x01C cycles
//   DONE
//
// B is printed as the logical weight matrix of the selected mode
// (N x N values of 8 / 4 / 2 bit  ->  N x N, N x 2N or N x 4N columns).
// C has N x (N, 2N or 4N) values. Every value goes through bin2bcd and is
// right-aligned with leading spaces.
//
// Signed mode (sgn = 1): the header reads "ADiP MODE=8x8 SIGNED", A and B are
// printed as two's complement values, every column is one character wider and
// negative values get a '-' in front of their first digit.
// -----------------------------------------------------------------------------
module uart_report #(
    parameter N            = 4,
    parameter IW           = 2,        // clog2(N)
    parameter OUT_W        = 19,       // result width (signed)
    parameter CLKS_PER_BIT = 234
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start,     // 1-cycle pulse: print now
    input  wire [1:0]         mode,
    input  wire               sgn,       // signed INT8 run
    input  wire [11:0]        lat,
    output wire [IW-1:0]      rd_row,    // shared read address (row, column)
    output wire [IW-1:0]      rd_col,
    input  wire [4*OUT_W-1:0] rd_data,   // result word (4 slots) at (rd_row, rd_col)
    input  wire [7:0]         dbg_a,     // input_memory byte  at {rd_row, rd_col}
    input  wire [7:0]         dbg_w,     // weight_memory byte at {rd_row, rd_col}
    output wire               uart_tx,
    output wire               busy
);
    localparam BD = 7;                  // decimal digit positions per value (incl. sign)

    localparam [2:0] P_IDLE = 3'd0, P_STR = 3'd1, P_MAT = 3'd2;
    localparam [2:0] S_HDR = 3'd0, S_A = 3'd1, S_B = 3'd2,
                     S_C   = 3'd3, S_L = 3'd4, S_D = 3'd5;
    localparam [1:0] SP_CONV = 2'd0, SP_WAIT = 2'd1, SP_PRINT = 2'd2;

    reg [2:0]    ph;
    reg [2:0]    sid;
    reg [1:0]    sp;
    reg [1:0]    mx;          // 0 = A, 1 = B, 2 = C
    reg [4:0]    idx;
    reg [IW-1:0] m;
    reg [IW+2:0] j;
    reg [3:0]    d;
    reg [1:0]    mode_l;
    reg          sgn_l;
    reg [11:0]   lat_l;
    reg          send;
    reg [7:0]    data;
    reg          conv_start;
    wire         tx_busy;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk (clk), .rst_n (rst_n), .send (send), .data (data),
        .tx  (uart_tx), .busy (tx_busy)
    );

    // ---- addressing -----------------------------------------------------------
    wire [IW+2:0] j_last = (mx == 2'd0) ? (N - 1) : ((N << mode_l) - 1);
    assign rd_row = m;
    assign rd_col = (mx == 2'd0) ? j[IW-1:0] : (j >> mode_l);

    wire [1:0] k = (mode_l == 2'd0) ? 2'd0 :
                   (mode_l == 2'd1) ? {1'b0, j[0]} : j[1:0];

    // ---- current value (sign-extended in signed mode) ---------------------------
    wire [3:0] w4 = j[0] ? dbg_w[7:4] : dbg_w[3:0];
    wire [1:0] w2 = (j[1:0] == 2'd0) ? dbg_w[1:0] :
                    (j[1:0] == 2'd1) ? dbg_w[3:2] :
                    (j[1:0] == 2'd2) ? dbg_w[5:4] : dbg_w[7:6];
    wire [OUT_W-1:0] a_val = {{(OUT_W-8){sgn_l & dbg_a[7]}}, dbg_a};
    wire [OUT_W-1:0] b_val = (mode_l == 2'd0) ? {{(OUT_W-8){sgn_l & dbg_w[7]}}, dbg_w} :
                             (mode_l == 2'd1) ? {{(OUT_W-4){sgn_l & w4[3]}}, w4} :
                                                {{(OUT_W-2){sgn_l & w2[1]}}, w2};
    wire [OUT_W-1:0] c_val = rd_data[k*OUT_W +: OUT_W];
    wire [OUT_W-1:0] val   = (mx == 2'd0) ? a_val : (mx == 2'd1) ? b_val : c_val;
    wire             neg   = sgn_l & val[OUT_W-1];
    wire [OUT_W-1:0] mag   = neg ? -val : val;

    reg              neg_l;               // sign of the value being printed
    wire [4*BD-1:0]  bcd;
    wire             conv_done;
    bin2bcd #(.W(OUT_W), .D(BD)) u_b2b (
        .clk(clk), .rst_n(rst_n), .start(conv_start), .bin(mag),
        .done(conv_done), .bcd(bcd)
    );

    // first printed position (0 = most significant of BD) = BD - width;
    // signed mode is one character wider (room for '-')
    reg [2:0] dstart;
    always @* begin
        case (mx)
            2'd0:    dstart = 3'd4;                                           // A: 3 digits
            2'd1:    dstart = (mode_l == 2'd0) ? 3'd4 : (mode_l == 2'd1) ? 3'd5 : 3'd6;
            default: dstart = (mode_l == 2'd0) ? 3'd1 : (mode_l == 2'd1) ? 3'd2 : 3'd3;
        endcase
        if (sgn_l) dstart = dstart - 3'd1;
    end

    wire [3:0]       nib    = bcd[(BD-1-d)*4 +: 4];
    wire [4*BD-1:0]  upto   = bcd >> (4*BD - 4 - 4*d);     // digits 0..d
    wire [4*BD-1:0]  upto_n = bcd >> (4*BD - 8 - 4*d);     // digits 0..d+1
    wire             blank   = (upto == 0) && (d != BD-1);
    wire             blank_n = (upto_n == 0) && (d != BD-2);
    wire             minus   = neg_l && blank && !blank_n;   // '-' just before the first digit

    function [7:0] hex2ascii;
        input [3:0] n;
        begin
            hex2ascii = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);   // 'A'-10 = 0x37
        end
    endfunction

    // ---- strings ----------------------------------------------------------------
    reg [4:0] str_len;
    always @* begin
        case (sid)
            S_HDR:   str_len = sgn_l ? 5'd22 : 5'd15;
            S_A:     str_len = 5'd11;
            S_B:     str_len = 5'd21;
            S_C:     str_len = 5'd14;
            S_L:     str_len = 5'd20;
            default: str_len = 5'd8;
        endcase
    end

    wire [7:0] mode_ch = (mode_l == 2'd0) ? "8" : (mode_l == 2'd1) ? "4" : "2";

    reg [7:0] ch;
    always @* begin
        ch = 8'h3F;
        case (ph)
            P_STR: begin
                case (sid)
                    S_HDR: begin
                        case ((!sgn_l && idx >= 5'd13) ? idx + 5'd7 : idx)
                            5'd0:  ch = "A";
                            5'd1:  ch = "D";
                            5'd2:  ch = "i";
                            5'd3:  ch = "P";
                            5'd4:  ch = " ";
                            5'd5:  ch = "M";
                            5'd6:  ch = "O";
                            5'd7:  ch = "D";
                            5'd8:  ch = "E";
                            5'd9:  ch = "=";
                            5'd10: ch = "8";
                            5'd11: ch = "x";
                            5'd12: ch = mode_ch;
                            5'd13: ch = " ";
                            5'd14: ch = "S";
                            5'd15: ch = "I";
                            5'd16: ch = "G";
                            5'd17: ch = "N";
                            5'd18: ch = "E";
                            5'd19: ch = "D";
                            5'd20: ch = 8'h0D;
                            default: ch = 8'h0A;
                        endcase
                    end
                    S_A: begin
                        case (idx)
                            5'd0:  ch = "A";
                            5'd1:  ch = " ";
                            5'd2:  ch = "m";
                            5'd3:  ch = "a";
                            5'd4:  ch = "t";
                            5'd5:  ch = "r";
                            5'd6:  ch = "i";
                            5'd7:  ch = "x";
                            5'd8:  ch = ":";
                            5'd9:  ch = 8'h0D;
                            default: ch = 8'h0A;
                        endcase
                    end
                    S_B: begin
                        case (idx)
                            5'd0:  ch = 8'h0D;
                            5'd1:  ch = 8'h0A;
                            5'd2:  ch = "B";
                            5'd3:  ch = " ";
                            5'd4:  ch = "m";
                            5'd5:  ch = "a";
                            5'd6:  ch = "t";
                            5'd7:  ch = "r";
                            5'd8:  ch = "i";
                            5'd9:  ch = "x";
                            5'd10: ch = " ";
                            5'd11: ch = "(";
                            5'd12: ch = mode_ch;
                            5'd13: ch = "-";
                            5'd14: ch = "b";
                            5'd15: ch = "i";
                            5'd16: ch = "t";
                            5'd17: ch = ")";
                            5'd18: ch = ":";
                            5'd19: ch = 8'h0D;
                            default: ch = 8'h0A;
                        endcase
                    end
                    S_C: begin
                        case (idx)
                            5'd0:  ch = 8'h0D;
                            5'd1:  ch = 8'h0A;
                            5'd2:  ch = "C";
                            5'd3:  ch = " ";
                            5'd4:  ch = "=";
                            5'd5:  ch = " ";
                            5'd6:  ch = "A";
                            5'd7:  ch = " ";
                            5'd8:  ch = "x";
                            5'd9:  ch = " ";
                            5'd10: ch = "B";
                            5'd11: ch = ":";
                            5'd12: ch = 8'h0D;
                            default: ch = 8'h0A;
                        endcase
                    end
                    S_L: begin
                        case (idx)
                            5'd0:  ch = 8'h0D;
                            5'd1:  ch = 8'h0A;
                            5'd2:  ch = "L";
                            5'd3:  ch = "A";
                            5'd4:  ch = "T";
                            5'd5:  ch = "=";
                            5'd6:  ch = "0";
                            5'd7:  ch = "x";
                            5'd8:  ch = hex2ascii(lat_l[11:8]);
                            5'd9:  ch = hex2ascii(lat_l[7:4]);
                            5'd10: ch = hex2ascii(lat_l[3:0]);
                            5'd11: ch = " ";
                            5'd12: ch = "c";
                            5'd13: ch = "y";
                            5'd14: ch = "c";
                            5'd15: ch = "l";
                            5'd16: ch = "e";
                            5'd17: ch = "s";
                            5'd18: ch = 8'h0D;
                            default: ch = 8'h0A;
                        endcase
                    end
                    default: begin   // S_D
                        case (idx)
                            5'd0: ch = "D";
                            5'd1: ch = "O";
                            5'd2: ch = "N";
                            5'd3: ch = "E";
                            5'd4: ch = 8'h0D;
                            5'd5: ch = 8'h0A;
                            5'd6: ch = 8'h0D;
                            default: ch = 8'h0A;
                        endcase
                    end
                endcase
            end

            P_MAT: begin
                if (d < BD)           ch = minus ? "-" : blank ? " " : (8'h30 + nib);
                else if (j == j_last) ch = (d == BD) ? 8'h0D : 8'h0A;
                else                  ch = " ";
            end

            default: ch = 8'h3F;
        endcase
    end

    // ---- sequencer ----------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            ph         <= P_IDLE;
            sid        <= S_HDR;
            sp         <= SP_CONV;
            mx         <= 2'd0;
            idx        <= 5'd0;
            m          <= {IW{1'b0}};
            j          <= {(IW+3){1'b0}};
            d          <= 4'd0;
            mode_l     <= 2'd0;
            sgn_l      <= 1'b0;
            neg_l      <= 1'b0;
            lat_l      <= 12'd0;
            send       <= 1'b0;
            data       <= 8'd0;
            conv_start <= 1'b0;
        end else begin
            send       <= 1'b0;
            conv_start <= 1'b0;

            if (ph == P_IDLE) begin
                if (start) begin
                    ph     <= P_STR;
                    sid    <= S_HDR;
                    idx    <= 5'd0;
                    mx     <= 2'd0;
                    m      <= {IW{1'b0}};
                    j      <= {(IW+3){1'b0}};
                    mode_l <= mode;
                    sgn_l  <= sgn;
                    lat_l  <= lat;
                end

            end else if (ph == P_MAT && sp == SP_CONV) begin
                conv_start <= 1'b1;            // converter is idle here
                neg_l      <= neg;
                d          <= {1'b0, dstart};
                sp         <= SP_WAIT;

            end else if (ph == P_MAT && sp == SP_WAIT) begin
                if (conv_done) sp <= SP_PRINT;

            end else if (!tx_busy && !send) begin
                send <= 1'b1;
                data <= ch;

                if (ph == P_STR) begin
                    if (idx == str_len - 1) begin
                        idx <= 5'd0;
                        case (sid)
                            S_HDR: sid <= S_A;
                            S_A:   begin ph <= P_MAT; mx <= 2'd0; m <= {IW{1'b0}}; j <= {(IW+3){1'b0}}; sp <= SP_CONV; end
                            S_B:   begin ph <= P_MAT; mx <= 2'd1; m <= {IW{1'b0}}; j <= {(IW+3){1'b0}}; sp <= SP_CONV; end
                            S_C:   begin ph <= P_MAT; mx <= 2'd2; m <= {IW{1'b0}}; j <= {(IW+3){1'b0}}; sp <= SP_CONV; end
                            S_L:   sid <= S_D;
                            default: ph <= P_IDLE;
                        endcase
                    end else begin
                        idx <= idx + 5'd1;
                    end

                end else begin                  // P_MAT, SP_PRINT
                    if (d < BD) begin
                        d <= d + 4'd1;
                    end else if (j == j_last) begin
                        if (d == BD) begin
                            d <= d + 4'd1;      // CR sent, LF next
                        end else begin          // LF sent: row finished
                            j  <= {(IW+3){1'b0}};
                            sp <= SP_CONV;
                            if (m == N-1) begin
                                m   <= {IW{1'b0}};
                                ph  <= P_STR;
                                idx <= 5'd0;
                                sid <= (mx == 2'd0) ? S_B : (mx == 2'd1) ? S_C : S_L;
                            end else begin
                                m <= m + 1'b1;
                            end
                        end
                    end else begin              // separator sent
                        j  <= j + 1'b1;
                        sp <= SP_CONV;
                    end
                end
            end
        end
    end

    assign busy = (ph != P_IDLE);
endmodule
