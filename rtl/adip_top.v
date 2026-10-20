// -----------------------------------------------------------------------------
// adip_top.v  -  ADiP-inspired adaptive-precision systolic array, Tang Nano 9K
//
//   S1 (btn_start_n) : start a computation + UART report
//   S2 (btn_mode_n)  : cycle precision mode 8x8 -> 8x4 -> 8x2 -> 8x8 ...
//   UART RX (from PC): set mode, signed/unsigned, load A and B, start (uart_cmd.v)
//   LED0 DONE, LED1 BUSY, LED2 8x8, LED3 8x4, LED4 8x2, LED5 UART printing
//   (LEDs are active-low on the board; handled here)
//
// A computation also starts automatically once after power-up (AUTO_START).
// N must be a power of two (4 or 8).
// -----------------------------------------------------------------------------
module adip_top #(
    parameter N                 = 4,
    parameter UART_CLKS_PER_BIT = 234,      // 27 MHz / 115200
    parameter DEBOUNCE_CYCLES   = 270000,   // ~10 ms
    parameter AUTO_START        = 1,
    parameter CMD_TIMEOUT       = 1350000   // ~50 ms
)(
    input  wire       clk,            // 27 MHz on-board oscillator
    input  wire       btn_start_n,
    input  wire       btn_mode_n,
    output wire       uart_tx,
    input  wire       uart_rx,
    output wire [5:0] led
);
    // ---- derived widths -------------------------------------------------------
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            clog2 = 0;
            while (v > 0) begin
                clog2 = clog2 + 1;
                v = v >> 1;
            end
        end
    endfunction

    localparam IW     = clog2(N);
    localparam AW     = 2 * IW;
    localparam CW     = clog2(3 * N);
    localparam PSUM_W = 11 + IW;     // signed lane sums
    localparam OUT_W  = 17 + IW;     // signed results
    localparam LW     = 4 * PSUM_W;
    localparam SW     = 4 * OUT_W;

    // ---- power-on reset -------------------------------------------------------
    reg [7:0] por_cnt = 8'd0;
    wire rst_n = &por_cnt;
    always @(posedge clk) if (!rst_n) por_cnt <= por_cnt + 8'd1;

    // ---- buttons / mode / start ----------------------------------------------
    wire start_btn, mode_btn;
    button_filter #(.CYCLES(DEBOUNCE_CYCLES)) u_bf_start (.clk(clk), .rst_n(rst_n), .btn_n(btn_start_n), .pulse(start_btn));
    button_filter #(.CYCLES(DEBOUNCE_CYCLES)) u_bf_mode  (.clk(clk), .rst_n(rst_n), .btn_n(btn_mode_n),  .pulse(mode_btn));

    // ---- commands from the PC over UART ----------------------------------------
    wire          rx_valid;
    wire [7:0]    rx_data;
    wire          cmd_mode_set, cmd_sign_set, cmd_sign_val, cmd_a_we, cmd_w_we, cmd_start;
    wire [1:0]    cmd_mode;
    wire [AW-1:0] cmd_addr;
    wire [7:0]    cmd_data;

    uart_rx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst_n(rst_n), .rx(uart_rx), .valid(rx_valid), .data(rx_data)
    );

    uart_cmd #(.N(N), .AW(AW), .TIMEOUT(CMD_TIMEOUT)) u_cmd (
        .clk(clk), .rst_n(rst_n), .rx_valid(rx_valid), .rx_data(rx_data),
        .mode_set(cmd_mode_set), .mode_val(cmd_mode),
        .sign_set(cmd_sign_set), .sign_val(cmd_sign_val),
        .a_we(cmd_a_we), .w_we(cmd_w_we), .waddr(cmd_addr), .wdata(cmd_data),
        .start(cmd_start)
    );

    reg [1:0] mode_sel = 2'd0;
    always @(posedge clk) begin
        if (!rst_n)            mode_sel <= 2'd0;
        else if (cmd_mode_set) mode_sel <= cmd_mode;
        else if (mode_btn)     mode_sel <= (mode_sel == 2'd2) ? 2'd0 : mode_sel + 2'd1;
    end

    reg sign_sel = 1'b0;                 // 0 = unsigned, 1 = signed INT8
    always @(posedge clk) begin
        if (!rst_n)            sign_sel <= 1'b0;
        else if (cmd_sign_set) sign_sel <= cmd_sign_val;
    end

    reg auto_done = 1'b0;
    always @(posedge clk) if (rst_n) auto_done <= 1'b1;
    wire auto_start = (AUTO_START != 0) && rst_n && !auto_done;

    // A start request (button, power-up or PC) is held until the design is free,
    // so a request that arrives while a result is still being printed is not lost.
    wire rpt_busy;
    wire busy, done_pulse;
    reg  start_req = 1'b0;
    wire start = (start_btn | auto_start | cmd_start | start_req)
                 & ~rpt_busy & ~busy & ~done_pulse;
    always @(posedge clk) begin
        if (!rst_n)                                start_req <= 1'b0;
        else if (start)                            start_req <= 1'b0;
        else if (start_btn | auto_start | cmd_start) start_req <= 1'b1;
    end

    // ---- control --------------------------------------------------------------
    wire done, clr, w_load_en, feed_en, cap_en;
    wire [IW-1:0]  w_row, w_col;
    wire [AW-1:0]  wmem_addr;
    wire [CW-1:0]  cnt;
    wire [1:0]     mode_q;
    wire [11:0]    lat;

    adip_controller #(.N(N), .IW(IW), .CW(CW)) u_ctrl (
        .clk(clk), .rst_n(rst_n), .start(start), .mode(mode_sel),
        .busy(busy), .done(done), .done_pulse(done_pulse),
        .clr(clr), .w_load_en(w_load_en), .w_row(w_row), .w_col(w_col),
        .wmem_addr(wmem_addr), .feed_en(feed_en), .cap_en(cap_en),
        .cnt_out(cnt), .mode_q_out(mode_q), .lat_out(lat)
    );

    // signedness is latched at start, like the mode (mode_q)
    reg sign_q = 1'b0;
    always @(posedge clk) begin
        if (!rst_n)     sign_q <= 1'b0;
        else if (start) sign_q <= sign_sel;
    end

    // signed weight chunks = the top chunk of every weight in the current mode
    wire [3:0] w_s = !sign_q          ? 4'b0000 :
                     (mode_q == 2'd0) ? 4'b1000 :
                     (mode_q == 2'd1) ? 4'b1010 : 4'b1111;

    // ---- memories -------------------------------------------------------------
    wire [7:0]    w_data;
    wire [7:0]    dbg_a, dbg_w;
    wire [IW-1:0] rd_row, rd_col;       // shared read address of the UART report
    wire [8*N-1:0] a_stream;

    weight_memory #(.N(N), .AW(AW)) u_wm (
        .clk(clk), .rst_n(rst_n),
        .wr_en(cmd_w_we), .wr_addr(cmd_addr), .wr_data(cmd_data),
        .rd_addr(wmem_addr), .rd_data(w_data),
        .dbg_addr({rd_row, rd_col}), .dbg_data(dbg_w)
    );

    input_memory #(.N(N), .AW(AW), .CW(CW)) u_im (
        .clk(clk), .rst_n(rst_n),
        .wr_en(cmd_a_we), .wr_addr(cmd_addr), .wr_data(cmd_data),
        .feed_en(feed_en), .feed_cnt(cnt), .a_stream(a_stream),
        .dbg_addr({rd_row, rd_col}), .dbg_data(dbg_a)
    );

    // ---- systolic array + shared shifters -------------------------------------
    wire [N*LW-1:0] col_psum;
    wire [N*SW-1:0] col_slots;

    systolic_array #(.N(N), .IW(IW), .PSUM_W(PSUM_W)) u_arr (
        .clk(clk), .clr(clr),
        .w_load_en(w_load_en), .w_load_row(w_row), .w_load_col(w_col), .w_load_data(w_data),
        .x_s(sign_q), .w_s(w_s),
        .a_in_flat(a_stream), .col_psum_flat(col_psum)
    );

    genvar c;
    generate
        for (c = 0; c < N; c = c + 1) begin : g_sh
            shared_shifter #(.PSUM_W(PSUM_W), .OUT_W(OUT_W)) u_sh (
                .mode(mode_q),
                .lanes(col_psum[c*LW +: LW]),
                .slots(col_slots[c*SW +: SW])
            );
        end
    endgenerate

    // ---- result memory + UART report ------------------------------------------
    wire [SW-1:0] rd_data;

    output_memory #(.N(N), .IW(IW), .CW(CW), .SW(SW)) u_om (
        .clk(clk), .cap_en(cap_en), .cap_cnt(cnt), .col_slots_flat(col_slots),
        .rd_row(rd_row), .rd_col(rd_col), .rd_data(rd_data)
    );

    uart_report #(.N(N), .IW(IW), .OUT_W(OUT_W), .CLKS_PER_BIT(UART_CLKS_PER_BIT)) u_rpt (
        .clk(clk), .rst_n(rst_n), .start(done_pulse), .mode(mode_q), .sgn(sign_q), .lat(lat),
        .rd_row(rd_row), .rd_col(rd_col), .rd_data(rd_data),
        .dbg_a(dbg_a), .dbg_w(dbg_w),
        .uart_tx(uart_tx), .busy(rpt_busy)
    );

    // ---- LEDs (active low) ----------------------------------------------------
    wire [5:0] led_on = {rpt_busy, (mode_sel == 2'd2), (mode_sel == 2'd1),
                         (mode_sel == 2'd0), busy, done};
    assign led = ~led_on;
endmodule
