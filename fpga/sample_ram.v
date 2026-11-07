module sample_ram(
    input  wire        clk,
    input  wire        wr_en,
    input  wire [9:0]  wr_addr,
    input  wire [11:0] wr_data,
    input  wire [9:0]  rd_addr,
    output reg  [11:0] rd_data
);
    // MAX 10 M9K memory: 1024 samples, 12 bits each.
    // Simple dual-port RAM with a common clock.
    (* ramstyle = "M9K" *) reg [11:0] mem [0:1023];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;

        // Synchronous read.
        rd_data <= mem[rd_addr];
    end
endmodule