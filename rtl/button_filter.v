// -----------------------------------------------------------------------------
// button_filter.v  -  synchroniser + debouncer for an active-low push button.
// `pulse` is high for one clock after the button has been stably pressed for
// CYCLES clocks (270000 cycles = 10 ms at 27 MHz).
// -----------------------------------------------------------------------------
module button_filter #(
    parameter CYCLES = 270000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire btn_n,
    output reg  pulse
);
    reg [1:0]  sync;
    reg        stable;
    reg [19:0] cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            sync   <= 2'b00;
            stable <= 1'b0;
            cnt    <= 20'd0;
            pulse  <= 1'b0;
        end else begin
            sync  <= {sync[0], ~btn_n};    // 1 = pressed
            pulse <= 1'b0;
            if (sync[1] == stable) begin
                cnt <= 20'd0;
            end else begin
                cnt <= cnt + 20'd1;
                if (cnt == CYCLES-1) begin
                    stable <= sync[1];
                    cnt    <= 20'd0;
                    if (sync[1]) pulse <= 1'b1;
                end
            end
        end
    end
endmodule
