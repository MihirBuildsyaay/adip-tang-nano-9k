`timescale 1ns/1ps
// PE-level test: loads one packed weight, drives random activations / incoming
// partial sums and checks all four lane accumulators and the a_out register.
// Runs once unsigned and once for each signed configuration (8x8 / 8x4 / 8x2).
module tb_pe;
    localparam PSUM_W = 13;
    localparam [7:0] W_VAL = 8'hE4;          // chunks: 0,1,2,3  (11 10 01 00)

    reg                 clk = 1'b0;
    reg                 clr, w_load, x_s;
    reg  [3:0]          w_s;
    reg  [7:0]          w_in, a_in;
    reg  [4*PSUM_W-1:0] psum_in;
    wire [7:0]          a_out;
    wire [4*PSUM_W-1:0] psum_out;

    always #5 clk = ~clk;

    adip_pe #(.PSUM_W(PSUM_W)) dut (
        .clk(clk), .clr(clr), .w_load(w_load), .w_in(w_in), .x_s(x_s), .w_s(w_s),
        .a_in(a_in), .psum_in(psum_in), .a_out(a_out), .psum_out(psum_out)
    );

    integer t, k, cfg, errors, xv, wv;
    reg [PSUM_W-1:0] expv;
    reg [63:0] rnd;

    initial begin
        $dumpfile("sim/out/tb_pe.vcd");
        $dumpvars(0, tb_pe);
    end

    initial begin
        errors = 0;
        for (cfg = 0; cfg < 4; cfg = cfg + 1) begin
            x_s = (cfg != 0);
            w_s = (cfg == 0) ? 4'b0000 : (cfg == 1) ? 4'b1000 : (cfg == 2) ? 4'b1010 : 4'b1111;
            clr = 1; w_load = 0; w_in = 0; a_in = 0; psum_in = 0;
            @(negedge clk); @(negedge clk);

            clr = 0; w_load = 1; w_in = W_VAL;
            @(negedge clk);
            w_load = 0;

            for (t = 0; t < 200; t = t + 1) begin
                rnd     = {$random, $random};
                a_in    = (t == 0) ? 8'h80 : (t == 1) ? 8'h7F : (t == 2) ? 8'hFF : rnd[7:0];
                psum_in = rnd[63:12];            // 52 random bits
                @(posedge clk); #1;
                xv = (x_s && a_in[7]) ? a_in - 256 : a_in;
                for (k = 0; k < 4; k = k + 1) begin
                    wv = (W_VAL >> (2*k)) & 3;
                    if (w_s[k] && wv >= 2) wv = wv - 4;
                    expv = psum_in[PSUM_W*k +: PSUM_W] + xv * wv;   // mod 2^PSUM_W
                    if (psum_out[PSUM_W*k +: PSUM_W] !== expv) begin
                        errors = errors + 1;
                        $display("FAIL cfg %0d t=%0d lane %0d: got=%0d exp=%0d", cfg, t, k,
                                 psum_out[PSUM_W*k +: PSUM_W], expv);
                    end
                end
                if (a_out !== a_in) begin
                    errors = errors + 1;
                    $display("FAIL t=%0d a_out=%0d exp=%0d", t, a_out, a_in);
                end
                @(negedge clk);
            end

            // clear check
            clr = 1;
            @(posedge clk); #1;
            if (psum_out !== 0 || a_out !== 0) begin
                errors = errors + 1;
                $display("FAIL: clr did not clear PE state");
            end
            @(negedge clk);
        end

        if (errors == 0) $display("tb_pe: PASS");
        else             $display("tb_pe: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
