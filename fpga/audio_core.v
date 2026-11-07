module audio_core(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        sample_valid,
    input  wire [11:0] sample_data,

    input  wire        spi_sck,
    input  wire        spi_mosi,
    input  wire        spi_cs_n,
    output wire        spi_miso,
    output wire        block_ready,
    output reg         sample_toggle,
    output wire        buffer_overflow
);
    wire        consume_valid;
    wire        consume_sel;
    wire        wr_en0;
    wire        wr_en1;
    wire [9:0]  wr_addr;
    wire [11:0] wr_data;
    wire        ready0;
    wire        ready1;
    wire [31:0] seq0;
    wire [31:0] seq1;
    wire [31:0] dropped_blocks;
    wire [9:0]  ram_addr;
    wire [11:0] ram0_data;
    wire [11:0] ram1_data;

    assign block_ready     = ready0 | ready1;
    assign buffer_overflow = (dropped_blocks != 32'd0);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            sample_toggle <= 1'b0;
        else if (sample_valid)
            sample_toggle <= ~sample_toggle;
    end

    audio_acquisition acquisition (
        .clk            (clk),
        .reset_n        (reset_n),
        .sample_valid   (sample_valid),
        .sample_data    (sample_data),
        .consume_valid  (consume_valid),
        .consume_sel    (consume_sel),
        .wr_en0         (wr_en0),
        .wr_en1         (wr_en1),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),
        .ready0         (ready0),
        .ready1         (ready1),
        .seq0           (seq0),
        .seq1           (seq1),
        .dropped_blocks (dropped_blocks)
    );

    sample_ram ping_ram (
        .clk     (clk),
        .wr_en   (wr_en0),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_addr (ram_addr),
        .rd_data (ram0_data)
    );

    sample_ram pong_ram (
        .clk     (clk),
        .wr_en   (wr_en1),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_addr (ram_addr),
        .rd_data (ram1_data)
    );

    spi_block_slave spi_slave (
        .clk           (clk),
        .reset_n       (reset_n),
        .spi_sck       (spi_sck),
        .spi_mosi      (spi_mosi),
        .spi_cs_n      (spi_cs_n),
        .spi_miso      (spi_miso),
        .ready0        (ready0),
        .ready1        (ready1),
        .seq0          (seq0),
        .seq1          (seq1),
        .ram_addr      (ram_addr),
        .ram0_data     (ram0_data),
        .ram1_data     (ram1_data),
        .consume_valid (consume_valid),
        .consume_sel   (consume_sel)
    );
endmodule
