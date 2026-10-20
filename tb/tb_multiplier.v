`timescale 1ns/1ps
// Exhaustive test: 2-bit multiplier (all 64 a/b/sign cases) and the 16-multiplier
// lane block (65,536 x/w combinations, all four lanes) in the four sign
// configurations the design uses: unsigned, and signed 8x8 / 8x4 / 8x2.
module tb_multiplier;
    reg  [1:0]  a, b;
    reg         a_s, b_s;
    wire [4:0]  p;
    reg  [7:0]  x, w;
    reg         x_s;
    reg  [3:0]  w_s;
    wire [43:0] lane_p;

    multiplier_2bit            u0 (.a(a), .a_s(a_s), .b(b), .b_s(b_s), .p(p));
    reconfigurable_multiplier  u1 (.x(x), .x_s(x_s), .w(w), .w_s(w_s), .lane_p(lane_p));

    integer i, j, k, cfg, errors, av, bv, xv, wv, expv, got;

    initial begin
        errors = 0;

        for (i = 0; i < 16; i = i + 1)
            for (j = 0; j < 4; j = j + 1) begin
                a = i[1:0]; b = i[3:2]; a_s = j[0]; b_s = j[1]; #1;
                av  = (a_s && a[1]) ? a - 4 : a;
                bv  = (b_s && b[1]) ? b - 4 : b;
                got = p[4] ? p - 32 : p;
                if (got !== av * bv) begin
                    errors = errors + 1;
                    $display("FAIL 2b: %0d*%0d = %0d", av, bv, got);
                end
            end

        for (cfg = 0; cfg < 4; cfg = cfg + 1) begin
            x_s = (cfg != 0);
            w_s = (cfg == 0) ? 4'b0000 : (cfg == 1) ? 4'b1000 : (cfg == 2) ? 4'b1010 : 4'b1111;
            for (i = 0; i < 256; i = i + 1)
                for (j = 0; j < 256; j = j + 1) begin
                    x = i; w = j; #1;
                    xv = (x_s && x[7]) ? i - 256 : i;
                    for (k = 0; k < 4; k = k + 1) begin
                        wv   = (j >> (2*k)) & 3;
                        if (w_s[k] && wv >= 2) wv = wv - 4;
                        expv = xv * wv;
                        got  = lane_p[11*k +: 11];
                        if (got >= 1024) got = got - 2048;
                        if (got !== expv) begin
                            errors = errors + 1;
                            if (errors < 10)
                                $display("FAIL cfg %0d lane %0d: x=%0d w=%0d got=%0d exp=%0d",
                                         cfg, k, i, j, got, expv);
                        end
                    end
                end
        end

        if (errors == 0) $display("tb_multiplier: PASS");
        else             $display("tb_multiplier: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
