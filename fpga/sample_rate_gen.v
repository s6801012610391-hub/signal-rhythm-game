module sample_rate_gen #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer SAMPLE_HZ = 16000
)(
    input  wire clk,
    input  wire reset_n,
    output reg  tick
);
    localparam integer DIVIDER = CLOCK_HZ / SAMPLE_HZ; // 3125 for 50 MHz / 16 kHz
    reg [15:0] counter;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            counter <= 16'd0;
            tick    <= 1'b0;
        end else begin
            tick <= 1'b0;
            if (counter == DIVIDER - 1) begin
                counter <= 16'd0;
                tick    <= 1'b1;
            end else begin
                counter <= counter + 16'd1;
            end
        end
    end
endmodule
