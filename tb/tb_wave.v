`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_wave.v - fast, self-checking run of all 3 precision modes, unsigned and
//             signed (INT8 / INT4 / INT2 weights), + VCD for GTKWave
// Checks the result memory directly (no UART decoding), so it finishes quickly.
// Open sim/out/tb_wave.vcd in GTKWave. Useful signals:
//   dut.u_ctrl.state, dut.u_ctrl.cnt, dut.busy, dut.done,
//   dut.u_arr.*  (a_w / p_w buses, PEs), dut.u_om.* , dut.mode_q
// -----------------------------------------------------------------------------
module tb_wave;
    localparam N     = 4;
    localparam OUT_W = 19;

    reg clk = 1'b0;
    always #18.5 clk = ~clk;                    // ~27 MHz

    reg        btn_start_n = 1'b1;
    reg        btn_mode_n  = 1'b1;
    wire       uart_tx;
    wire [5:0] led;

    adip_top #(.N(N), .UART_CLKS_PER_BIT(8), .DEBOUNCE_CYCLES(8), .AUTO_START(0)) dut (
        .clk(clk), .btn_start_n(btn_start_n), .btn_mode_n(btn_mode_n),
        .uart_tx(uart_tx), .uart_rx(1'b1), .led(led)
    );

    // ---- readable probes for GTKWave (laid out in sim/tb_wave.gtkw) ------------
    // activation entering each array row this cycle (the skew is visible)
    wire [7:0] a_in_row0 = dut.a_stream[ 7: 0];
    wire [7:0] a_in_row1 = dut.a_stream[15: 8];
    wire [7:0] a_in_row2 = dut.a_stream[23:16];
    wire [7:0] a_in_row3 = dut.a_stream[31:24];
    // shared-shifter output of each column (slot 0 = the 8x8 result; 8x4 / 8x2 use more slots)
    localparam SW = 4 * OUT_W;
    wire signed [OUT_W-1:0] c_col0_slot0 = dut.col_slots[0*SW + 0*OUT_W +: OUT_W];
    wire signed [OUT_W-1:0] c_col0_slot1 = dut.col_slots[0*SW + 1*OUT_W +: OUT_W];
    wire signed [OUT_W-1:0] c_col1_slot0 = dut.col_slots[1*SW + 0*OUT_W +: OUT_W];
    wire signed [OUT_W-1:0] c_col2_slot0 = dut.col_slots[2*SW + 0*OUT_W +: OUT_W];
    wire signed [OUT_W-1:0] c_col3_slot0 = dut.col_slots[3*SW + 0*OUT_W +: OUT_W];
    // result capture: high in the cycle column c writes row c_row_colX of C
    wire       c_write_col0 = dut.u_om.g_col[0].valid;
    wire       c_write_col1 = dut.u_om.g_col[1].valid;
    wire       c_write_col2 = dut.u_om.g_col[2].valid;
    wire       c_write_col3 = dut.u_om.g_col[3].valid;
    wire [1:0] c_row_col0   = dut.u_om.g_col[0].wrow;
    wire [1:0] c_row_col1   = dut.u_om.g_col[1].wrow;
    wire [1:0] c_row_col2   = dut.u_om.g_col[2].wrow;
    wire [1:0] c_row_col3   = dut.u_om.g_col[3].wrow;

    // Dumping starts just before the first run (not at time 0), so GTKWave opens
    // directly on it: GTKWave 4 ignores the start time stored in a save file.
    initial begin
        $dumpfile("sim/out/tb_wave.vcd");
        @(negedge btn_start_n);
        repeat (2) @(posedge clk);
        $dumpvars(1, tb_wave);
        $dumpvars(1, dut);
        $dumpvars(0, dut.u_ctrl);
        $dumpvars(0, dut.u_arr);
        $dumpvars(0, dut.u_om);
    end

    integer cur_mode = 0;
    integer errors   = 0;

    task press_start;
        begin
            btn_start_n = 1'b0; repeat (40) @(posedge clk);
            btn_start_n = 1'b1; repeat (40) @(posedge clk);
        end
    endtask

    task press_mode;
        begin
            btn_mode_n = 1'b0; repeat (40) @(posedge clk);
            btn_mode_n = 1'b1; repeat (40) @(posedge clk);
        end
    endtask

    task run_and_check;
        input integer mode;
        input integer sg;                         // 1 = signed run
        integer np, i, guard, n, mm, jj, c, k, r, bad, bits;
        integer acc, wv, av, got;
        reg [7:0]  wb;
        reg [4*OUT_W-1:0] word;
        begin
            np = (mode - cur_mode + 3) % 3;
            for (i = 0; i < np; i = i + 1) press_mode;
            cur_mode = mode;
            force dut.sign_sel = sg;              // same as sending 'I' / 'U' over UART

            press_start;
            guard = 0;
            while (dut.done !== 1'b1 && guard < 10000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            @(posedge clk);

            n = 1 << mode;
            bad = 0;
            for (mm = 0; mm < N; mm = mm + 1)
                for (jj = 0; jj < N*n; jj = jj + 1) begin
                    c = jj / n;
                    k = jj % n;
                    acc  = 0;
                    bits = 8 >> mode;
                    for (r = 0; r < N; r = r + 1) begin
                        wb = dut.u_wm.mem[r*N + c];
                        wv = (wb >> (bits*k)) & ((1 << bits) - 1);
                        if (sg && wv >= (1 << (bits-1))) wv = wv - (1 << bits);
                        av = dut.u_im.mem[mm*N + r];
                        if (sg && av >= 128) av = av - 256;
                        acc = acc + av * wv;
                    end
                    force dut.rd_row = mm;
                    force dut.rd_col = c;
                    #1;
                    word = dut.rd_data;
                    release dut.rd_row;
                    release dut.rd_col;
                    got = (word >> (k*OUT_W)) & ((1 << OUT_W) - 1);
                    if (got >= (1 << (OUT_W-1))) got = got - (1 << OUT_W);
                    if (got !== acc) begin
                        bad = bad + 1;
                        if (bad < 6)
                            $display("mode %0d C[%0d][%0d]: got=%0d exp=%0d", mode, mm, jj, got, acc);
                    end
                end

            if (bad == 0) $display("tb_wave mode %0d (8x%0d) %s: PASS, latency=%0d cycles",
                                   mode, (mode == 0) ? 8 : (mode == 1) ? 4 : 2,
                                   sg ? "signed  " : "unsigned", dut.lat);
            else          errors = errors + bad;

            // let the UART report finish before the next run
            @(posedge clk);
            guard = 0;
            while (dut.rpt_busy === 1'b1 && guard < 200000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            repeat (200) @(posedge clk);
        end
    endtask

    initial begin
        repeat (400) @(posedge clk);                // power-on reset
        run_and_check(0, 0);
        run_and_check(1, 0);
        run_and_check(2, 0);
        run_and_check(0, 1);
        run_and_check(1, 1);
        run_and_check(2, 1);
        if (errors == 0) $display("tb_wave: ALL PASS");
        else             $display("tb_wave: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("tb_wave: TIMEOUT");
        $finish;
    end
endmodule
