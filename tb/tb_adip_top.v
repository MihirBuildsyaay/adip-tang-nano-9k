`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// End-to-end test of adip_top (N = 4):
//   * phases 0-3: presses the on-board buttons (mode select + start)
//   * phases 4-5: drives the board's UART RX pin like the PC app does:
//                 loads A and W, sets the mode and starts - all over UART
//   * decodes the UART text stream with a behavioural receiver
//   * compares it, character by character, with a golden report built from the
//     memory contents with a plain triple-loop matrix multiplication
//   * phases 6-9: signed INT8 mode ('I' over UART): default data, extreme
//                 values (-128 x -128, 127 x -128) and random data
// Data: 0 default, 1 all-0xFF (max values), 2-5 random. All 3 modes each.
// -----------------------------------------------------------------------------
module tb_adip_top;
    localparam N   = 4;
    localparam CPB = 16;           // fast UART for simulation
    localparam LAT = N*N + 3*N;    // expected START->DONE cycles (28)

    reg clk = 1'b0;
    always #18.5 clk = ~clk;       // ~27 MHz

    reg        btn_start_n = 1'b1;
    reg        btn_mode_n  = 1'b1;
    reg        uart_rx_line = 1'b1;      // PC -> FPGA line (idle high)
    wire       uart_tx;
    wire [5:0] led;

    adip_top #(.N(N), .UART_CLKS_PER_BIT(CPB), .DEBOUNCE_CYCLES(8), .AUTO_START(0)) dut (
        .clk(clk), .btn_start_n(btn_start_n), .btn_mode_n(btn_mode_n),
        .uart_tx(uart_tx), .uart_rx(uart_rx_line), .led(led)
    );

    // ---------------- PC -> FPGA UART sender ----------------
    task uart_send;
        input [7:0] b;
        integer k;
        begin
            uart_rx_line = 1'b0;                         // start bit
            repeat (CPB) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin          // data, LSB first
                uart_rx_line = b[k];
                repeat (CPB) @(posedge clk);
            end
            uart_rx_line = 1'b1;                         // stop bit + 1 idle bit
            repeat (2*CPB) @(posedge clk);
        end
    endtask

    // ---------------- UART receiver model ----------------
    reg [7:0] rx_buf [0:8191];
    integer   rx_n = 0;
    reg [7:0] rx_byte;
    integer   bi;
    initial begin
        forever begin
            @(negedge uart_tx);
            repeat (CPB + CPB/2) @(posedge clk);
            for (bi = 0; bi < 8; bi = bi + 1) begin
                rx_byte[bi] = uart_tx;
                repeat (CPB) @(posedge clk);
            end
            rx_buf[rx_n] = rx_byte;
            rx_n = rx_n + 1;
        end
    end

    // ---------------- golden report builder ----------------
    reg [7:0] exp_buf [0:8191];
    integer   exp_n;

    task put_c;
        input [7:0] c;
        begin
            exp_buf[exp_n] = c;
            exp_n = exp_n + 1;
        end
    endtask

    task put_hex;
        input [31:0] v;
        input integer digits;
        integer k;
        reg [3:0] nib;
        begin
            for (k = digits-1; k >= 0; k = k - 1) begin
                nib = v >> (4*k);
                put_c((nib < 10) ? (8'h30 + nib) : (8'h37 + nib));
            end
        end
    endtask

    task put_dec;                         // right-aligned signed decimal, `width` chars
        input integer v;
        input integer width;
        integer k, mag, nd, p, dg;
        begin
            mag = (v < 0) ? -v : v;
            nd  = 1;                          // number of digits
            p   = 10;
            while (mag >= p) begin nd = nd + 1; p = p * 10; end
            for (k = width - nd - ((v < 0) ? 1 : 0); k > 0; k = k - 1) put_c(" ");
            if (v < 0) put_c("-");
            for (k = nd-1; k >= 0; k = k - 1) begin
                p = 1;
                for (dg = 0; dg < k; dg = dg + 1) p = p * 10;
                put_c(8'h30 + (mag / p) % 10);
            end
        end
    endtask

    function integer s8;                  // byte as A value (signed if sg)
        input [7:0] b;
        input integer sg;
        begin s8 = (sg && b[7]) ? b - 256 : b; end
    endfunction

    function integer wval;                // logical weight k of a packed byte
        input [7:0] b;
        input integer mode, k, sg;
        integer bits;
        begin
            bits = 8 >> mode;
            wval = (b >> (bits*k)) & ((1 << bits) - 1);
            if (sg && wval >= (1 << (bits-1))) wval = wval - (1 << bits);
        end
    endfunction

    task put_str;                         // up to 24 chars, NUL padded on the left
        input [8*24-1:0] str;
        integer k;
        begin
            for (k = 23; k >= 0; k = k - 1)
                if (str[8*k +: 8] != 8'h00) put_c(str[8*k +: 8]);
        end
    endtask

    task put_crlf;
        begin put_c(8'h0D); put_c(8'h0A); end
    endtask

    task build_expected;
        input integer mode;
        input integer sg;                 // signed INT8 run
        integer r, c, k, n, mm, jj, a_w, wb_w, wc_w, acc;
        reg [7:0]  wb, mch;
        begin
            exp_n = 0;
            n    = 1 << mode;
            mch  = (mode == 0) ? "8" : (mode == 1) ? "4" : "2";
            a_w  = 3 + sg;                // signed: one char wider for '-'
            wb_w = ((mode == 0) ? 3 : (mode == 1) ? 2 : 1) + sg;
            wc_w = ((mode == 0) ? 6 : (mode == 1) ? 5 : 4) + sg;

            put_str("ADiP MODE=8x"); put_c(mch);
            if (sg) put_str(" SIGNED");
            put_crlf;

            put_str("A matrix:"); put_crlf;
            for (mm = 0; mm < N; mm = mm + 1)
                for (jj = 0; jj < N; jj = jj + 1) begin
                    put_dec(s8(dut.u_im.mem[mm*N + jj], sg), a_w);
                    if (jj == N-1) put_crlf; else put_c(" ");
                end

            put_crlf; put_str("B matrix ("); put_c(mch); put_str("-bit):"); put_crlf;
            for (mm = 0; mm < N; mm = mm + 1)
                for (jj = 0; jj < N*n; jj = jj + 1) begin
                    wb = dut.u_wm.mem[mm*N + jj/n];
                    put_dec(wval(wb, mode, jj % n, sg), wb_w);
                    if (jj == N*n-1) put_crlf; else put_c(" ");
                end

            put_crlf; put_str("C = A x B:"); put_crlf;
            for (mm = 0; mm < N; mm = mm + 1)
                for (jj = 0; jj < N*n; jj = jj + 1) begin
                    c = jj / n;
                    k = jj % n;
                    acc = 0;
                    for (r = 0; r < N; r = r + 1)
                        acc = acc + s8(dut.u_im.mem[mm*N + r], sg)
                                  * wval(dut.u_wm.mem[r*N + c], mode, k, sg);
                    put_dec(acc, wc_w);
                    if (jj == N*n-1) put_crlf; else put_c(" ");
                end

            put_crlf; put_str("LAT=0x"); put_hex(LAT, 3); put_str(" cycles"); put_crlf;
            put_str("DONE"); put_crlf; put_crlf;
        end
    endtask

    // ---------------- stimulus helpers ----------------
    integer cur_mode;
    integer cur_sign;
    integer errors;

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

    task run_mode;
        input integer mode;
        input integer phase;
        input integer via_uart;       // 0: buttons, 1: 'M' <m> 'S', 2: '<digit>' 's'
        input integer sg;             // 0: unsigned, 1: signed ('I' / 'u' sent when it changes)
        integer guard, i, bad, np;
        begin
            if (sg != cur_sign) begin
                uart_send(sg ? "I" : "u");
                cur_sign = sg;
            end
            rx_n = 0;
            if (via_uart == 0) begin
                np = (mode - cur_mode + 3) % 3;
                for (i = 0; i < np; i = i + 1) press_mode;
                press_start;
            end else if (via_uart == 1) begin
                uart_send("M"); uart_send(mode);
                uart_send("S");
            end else begin
                uart_send(8'h30 + mode);
                uart_send("s");
            end
            cur_mode = mode;
            build_expected(mode, sg);

            guard = 0;
            while (rx_n < exp_n && guard < 6000000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            repeat (CPB*4) @(posedge clk);

            bad = 0;
            if (rx_n !== exp_n) begin
                bad = bad + 1;
                $display("phase %0d mode %0d: length mismatch rx=%0d exp=%0d", phase, mode, rx_n, exp_n);
            end
            for (i = 0; i < exp_n && i < rx_n; i = i + 1)
                if (rx_buf[i] !== exp_buf[i]) begin
                    bad = bad + 1;
                    if (bad < 6)
                        $display("phase %0d mode %0d: char %0d got 0x%02h exp 0x%02h",
                                 phase, mode, i, rx_buf[i], exp_buf[i]);
                end
            if (led[0] !== 1'b0) begin
                bad = bad + 1;
                $display("phase %0d mode %0d: DONE LED not lit", phase, mode);
            end
            // phase 0 / 6 = default demo data: show the text exactly as the PC terminal will
            if (phase == 0 || (phase == 6 && mode == 0)) begin
                $display("");
                $display("----- UART text received in simulation (what the board will print) -----");
                for (i = 0; i < rx_n; i = i + 1)
                    if (rx_buf[i] != 8'h0D) $write("%c", rx_buf[i]);
                $display("-------------------------------------------------------------------------");
            end
            if (bad == 0) $display("phase %0d mode %0d (8x%0d)%s%s: PASS  (%0d chars)",
                                   phase, mode, (mode == 0) ? 8 : (mode == 1) ? 4 : 2,
                                   sg ? " SIGNED" : "",
                                   (via_uart != 0) ? " via UART commands" : "", rx_n);
            else          errors = errors + bad;
        end
    endtask

    // load A and W over UART (like the PC app) and check they arrived
    reg [7:0] ta [0:N*N-1];
    reg [7:0] tw [0:N*N-1];
    task uart_load_matrices;
        input integer phase;
        integer q, bad;
        begin
            for (q = 0; q < N*N; q = q + 1) begin
                ta[q] = $random;
                tw[q] = $random;
            end
            uart_send("A");
            for (q = 0; q < N*N; q = q + 1) uart_send(ta[q]);
            uart_send("W");
            for (q = 0; q < N*N; q = q + 1) uart_send(tw[q]);
            repeat (10) @(posedge clk);
            bad = 0;
            for (q = 0; q < N*N; q = q + 1)
                if (dut.u_im.mem[q] !== ta[q] || dut.u_wm.mem[q] !== tw[q]) bad = bad + 1;
            if (bad == 0) $display("phase %0d: A and W loaded over UART: PASS", phase);
            else begin
                $display("phase %0d: A/W UART load FAIL (%0d bytes wrong)", phase, bad);
                errors = errors + bad;
            end
        end
    endtask

    integer ph, ii;
    initial begin
        if ($test$plusargs("dump")) begin       // vvp sim/out/tb_top.vvp +dump
            $dumpfile("sim/out/tb_top.vcd");
            $dumpvars(1, tb_adip_top);
            $dumpvars(0, dut.u_ctrl);
            $dumpvars(1, dut.u_rpt);
            $dumpvars(1, dut.u_rpt.u_tx);
            $dumpvars(1, dut.u_rx);
            $dumpvars(1, dut.u_cmd);
        end
        errors = 0;
        cur_mode = 0;
        cur_sign = 0;
        repeat (400) @(posedge clk);                 // power-on reset

        for (ph = 0; ph < 4; ph = ph + 1) begin
            if (ph == 1) begin                       // maximum unsigned values
                for (ii = 0; ii < N*N; ii = ii + 1) begin
                    dut.u_im.mem[ii] = 8'hFF;
                    dut.u_wm.mem[ii] = 8'hFF;
                end
            end else if (ph >= 2) begin              // random data
                for (ii = 0; ii < N*N; ii = ii + 1) begin
                    dut.u_im.mem[ii] = $random;
                    dut.u_wm.mem[ii] = $random;
                end
            end
            run_mode(0, ph, 0, 0);
            run_mode(1, ph, 0, 0);
            run_mode(2, ph, 0, 0);
        end

        // ---- phases 4 and 5: everything driven from the PC side over UART ----
        uart_load_matrices(4);
        run_mode(2, 4, 1, 0);
        run_mode(0, 4, 1, 0);
        run_mode(1, 4, 1, 0);
        uart_load_matrices(5);
        run_mode(1, 5, 2, 0);
        run_mode(2, 5, 2, 0);
        run_mode(0, 5, 2, 0);

        // ---- phases 6-9: signed INT8 ----
        for (ii = 0; ii < N*N; ii = ii + 1) begin    // 6: default demo data
            dut.u_im.mem[ii] = (ii + 1) & 8'hFF;
            dut.u_wm.mem[ii] = (73*ii + 41) & 8'hFF;
        end
        run_mode(0, 6, 1, 1);
        run_mode(1, 6, 1, 1);
        run_mode(2, 6, 1, 1);
        for (ii = 0; ii < N*N; ii = ii + 1) begin    // 7: -128 x most negative weights
            dut.u_im.mem[ii] = 8'h80;                //    (largest positive C)
            dut.u_wm.mem[ii] = ii[0] ? 8'h88 : 8'hAA;
        end
        run_mode(0, 7, 0, 1);
        run_mode(1, 7, 0, 1);
        run_mode(2, 7, 0, 1);
        for (ii = 0; ii < N*N; ii = ii + 1) begin    // 8: 127 x -128 (largest negative C)
            dut.u_im.mem[ii] = 8'h7F;
            dut.u_wm.mem[ii] = 8'h80;
        end
        run_mode(0, 8, 2, 1);
        run_mode(1, 8, 2, 1);
        run_mode(2, 8, 2, 1);
        uart_load_matrices(9);                       // 9: random, loaded over UART
        run_mode(1, 9, 1, 1);
        run_mode(0, 9, 2, 1);
        run_mode(2, 9, 0, 1);
        run_mode(0, 9, 1, 0);                        // and back to unsigned

        if (errors == 0) $display("tb_adip_top: ALL PASS");
        else             $display("tb_adip_top: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #600_000_000;
        $display("tb_adip_top: TIMEOUT");
        $finish;
    end
endmodule
