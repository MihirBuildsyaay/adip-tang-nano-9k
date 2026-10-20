// -----------------------------------------------------------------------------
// adip_controller.v  -  IDLE -> LOAD -> COMPUTE -> STORE -> DONE
//
//  LOAD    : N*N cycles, one stationary weight per cycle into the PE array
//            (datapath registers are cleared with `clr` meanwhile)
//  COMPUTE : 3N-1 cycles (cnt = 0 .. 3N-2); activations are fed with skew and
//            finished results are captured/de-skewed into the output memory
//  STORE   : 1 cycle
//  DONE    : result valid, waiting for the next `start`
//
// Latency START -> DONE = N*N + (3N-1) + 1 = N*N + 3N cycles (28 for N = 4).
// -----------------------------------------------------------------------------
module adip_controller #(
    parameter N  = 4,
    parameter IW = 2,         // clog2(N)
    parameter CW = 4          // clog2(3*N)
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              start,
    input  wire [1:0]        mode,         // 0: 8x8, 1: 8x4, 2: 8x2

    output wire              busy,
    output wire              done,
    output reg               done_pulse,   // 1 cycle, first cycle of DONE

    output wire              clr,
    output wire              w_load_en,
    output wire [IW-1:0]     w_row,
    output wire [IW-1:0]     w_col,
    output wire [2*IW-1:0]   wmem_addr,

    output wire              feed_en,
    output wire              cap_en,
    output wire [CW-1:0]     cnt_out,

    output wire [1:0]        mode_q_out,   // mode latched at start
    output wire [11:0]       lat_out       // START->DONE cycle count
);
    localparam [2:0] S_IDLE    = 3'd0,
                     S_LOAD    = 3'd1,
                     S_COMPUTE = 3'd2,
                     S_STORE   = 3'd3,
                     S_DONE    = 3'd4;

    localparam [CW-1:0] LAST = 3*N - 2;

    reg [2:0]    state;
    reg [IW-1:0] r_cnt, c_cnt;
    reg [CW-1:0] cnt;
    reg [1:0]    mode_q;
    reg [11:0]   lat;

    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            r_cnt      <= {IW{1'b0}};
            c_cnt      <= {IW{1'b0}};
            cnt        <= {CW{1'b0}};
            mode_q     <= 2'd0;
            lat        <= 12'd0;
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= (state == S_STORE);
            case (state)
                S_IDLE, S_DONE: begin
                    if (start) begin
                        mode_q <= (mode == 2'd3) ? 2'd2 : mode;
                        r_cnt  <= {IW{1'b0}};
                        c_cnt  <= {IW{1'b0}};
                        cnt    <= {CW{1'b0}};
                        lat    <= 12'd0;
                        state  <= S_LOAD;
                    end
                end

                S_LOAD: begin
                    lat <= lat + 12'd1;
                    if (c_cnt == N-1) begin
                        c_cnt <= {IW{1'b0}};
                        if (r_cnt == N-1) begin
                            r_cnt <= {IW{1'b0}};
                            cnt   <= {CW{1'b0}};
                            state <= S_COMPUTE;
                        end else begin
                            r_cnt <= r_cnt + 1'b1;
                        end
                    end else begin
                        c_cnt <= c_cnt + 1'b1;
                    end
                end

                S_COMPUTE: begin
                    lat <= lat + 12'd1;
                    if (cnt == LAST) state <= S_STORE;
                    else             cnt   <= cnt + 1'b1;
                end

                S_STORE: begin
                    lat   <= lat + 12'd1;
                    state <= S_DONE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign busy       = (state == S_LOAD) || (state == S_COMPUTE) || (state == S_STORE);
    assign done       = (state == S_DONE);
    assign clr        = (state == S_LOAD);
    assign w_load_en  = (state == S_LOAD);
    assign w_row      = r_cnt;
    assign w_col      = c_cnt;
    assign wmem_addr  = {r_cnt, c_cnt};
    assign feed_en    = (state == S_COMPUTE);
    assign cap_en     = (state == S_COMPUTE);
    assign cnt_out    = cnt;
    assign mode_q_out = mode_q;
    assign lat_out    = lat;
endmodule
