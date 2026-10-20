`timescale 1ns/1ps
// 4x4 array test (mode-0 style recombination done in the testbench):
// loads random weights, streams skewed random activations and compares the
// de-skewed column results against a plain A*W matrix product.
// Trials 0-19 unsigned, 20-39 signed INT8 x INT8 (trial 20: all -128).
module tb_systolic_array;
    localparam N      = 4;
    localparam IW     = 2;
    localparam PSUM_W = 13;
    localparam OUT_W  = 19;
    localparam LW     = 4*PSUM_W;

    reg                clk = 1'b0;
    reg                clr, w_load_en, x_s;
    reg  [3:0]         w_s;
    reg  [IW-1:0]      w_row, w_col;
    reg  [7:0]         w_data;
    reg  [8*N-1:0]     a_in_flat;
    wire [N*LW-1:0]    col_psum;

    always #5 clk = ~clk;

    systolic_array #(.N(N), .IW(IW), .PSUM_W(PSUM_W)) dut (
        .clk(clk), .clr(clr),
        .w_load_en(w_load_en), .w_load_row(w_row), .w_load_col(w_col),
        .w_load_data(w_data), .x_s(x_s), .w_s(w_s), .a_in_flat(a_in_flat), .col_psum_flat(col_psum)
    );

    reg [7:0] Am [0:N*N-1];
    reg [7:0] Wm [0:N*N-1];
    integer   errors, trial, r, c, m, t, idx, sg;
    integer   expv, got, av, wv;
    reg [LW-1:0] lanes;

    function integer sx;                 // sign-extend a lane sum
        input [PSUM_W-1:0] v;
        begin sx = v[PSUM_W-1] ? v - (1 << PSUM_W) : v; end
    endfunction

    initial begin
        $dumpfile("sim/out/tb_array.vcd");
        $dumpvars(0, tb_systolic_array);
    end

    initial begin
        errors = 0;
        for (trial = 0; trial < 40; trial = trial + 1) begin
            sg  = (trial >= 20);
            x_s = sg;
            w_s = sg ? 4'b1000 : 4'b0000;
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                Am[idx] = (trial == 0) ? 8'hFF : (trial == 20) ? 8'h80 : $random;
                Wm[idx] = (trial == 0) ? 8'hFF : (trial == 20) ? 8'h80 : $random;
            end

            // ---- LOAD phase (clr high) ----
            clr = 1; w_load_en = 0; a_in_flat = 0; w_row = 0; w_col = 0; w_data = 0;
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                @(negedge clk);
                w_load_en = 1; w_row = idx / N; w_col = idx % N; w_data = Wm[idx];
            end
            @(negedge clk);
            w_load_en = 0; clr = 0;

            // ---- COMPUTE phase: cnt = 0 .. 3N-2 ----
            for (t = 0; t <= 3*N-2; t = t + 1) begin
                // (negedge already reached for t = 0; otherwise wait)
                if (t != 0) @(negedge clk);
                for (r = 0; r < N; r = r + 1)
                    a_in_flat[r*8 +: 8] = (t - r >= 0 && t - r < N) ? Am[(t-r)*N + r] : 8'd0;
                #2;   // outputs of the previous clock edge are stable here
                for (c = 0; c < N; c = c + 1) begin
                    m = t - N - c;
                    if (m >= 0 && m < N) begin
                        lanes = col_psum[c*LW +: LW];
                        got = sx(lanes[0*PSUM_W +: PSUM_W])
                            + sx(lanes[1*PSUM_W +: PSUM_W]) * 4
                            + sx(lanes[2*PSUM_W +: PSUM_W]) * 16
                            + sx(lanes[3*PSUM_W +: PSUM_W]) * 64;
                        expv = 0;
                        for (r = 0; r < N; r = r + 1) begin
                            av = Am[m*N + r];
                            wv = Wm[r*N + c];
                            if (sg && av >= 128) av = av - 256;
                            if (sg && wv >= 128) wv = wv - 256;
                            expv = expv + av * wv;
                        end
                        if (got !== expv) begin
                            errors = errors + 1;
                            $display("FAIL trial %0d C[%0d][%0d]: got=%0d exp=%0d",
                                     trial, m, c, got, expv);
                        end
                    end
                end
            end
            a_in_flat = 0;
            @(negedge clk);
        end

        if (errors == 0) $display("tb_systolic_array: PASS");
        else             $display("tb_systolic_array: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
