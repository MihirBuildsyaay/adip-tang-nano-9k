// -----------------------------------------------------------------------------
// bin2bcd.v - sequential "double dabble" binary -> BCD converter
// start (1-cycle pulse, ignored while busy) latches `bin`; after W+1 cycles
// `done` pulses for one cycle and `bcd` (D digits, MSD first) stays valid until
// the next start. W = 18, D = 6 handles values up to 999999.
// -----------------------------------------------------------------------------
module bin2bcd #(
    parameter W = 18,
    parameter D = 6
)(
    input  wire           clk,
    input  wire           rst_n,
    input  wire           start,
    input  wire [W-1:0]   bin,
    output reg            done,
    output wire [4*D-1:0] bcd
);
    reg  [W+4*D-1:0] sh;
    reg  [W+4*D-1:0] adj;
    reg  [7:0]       cnt;
    reg              run;
    integer          q;

    always @* begin
        adj = sh;
        for (q = 0; q < D; q = q + 1)
            if (sh[W+4*q +: 4] >= 4'd5)
                adj[W+4*q +: 4] = sh[W+4*q +: 4] + 4'd3;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sh   <= {(W+4*D){1'b0}};
            cnt  <= 8'd0;
            run  <= 1'b0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start && !run) begin
                sh  <= {{(4*D){1'b0}}, bin};
                cnt <= 8'd0;
                run <= 1'b1;
            end else if (run) begin
                sh <= adj << 1;
                if (cnt == W-1) begin
                    run  <= 1'b0;
                    done <= 1'b1;
                end else cnt <= cnt + 8'd1;
            end
        end
    end

    assign bcd = sh[W+4*D-1 : W];
endmodule
