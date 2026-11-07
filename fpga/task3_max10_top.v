module task3_max10_top(
    input  wire       MAX10_CLK1_50,
    input  wire       KEY0,

    input  wire       SPI_SCK,
    input  wire       SPI_MOSI,
    input  wire       SPI_CS_N,
    output wire       SPI_MISO,
    output wire       BLOCK_READY,

    output wire       SAMPLE_TOGGLE,
    output wire [1:0] LEDR
);

    // Reset: assert immediately, release on the FPGA clock.
    reg [1:0] reset_sync;

    always @(posedge MAX10_CLK1_50 or negedge KEY0) begin
        if (!KEY0)
            reset_sync <= 2'b00;
        else
            reset_sync <= {reset_sync[0], 1'b1};
    end

    wire reset_n = reset_sync[1];

    wire        sample_request;
    wire        sample_valid;
    wire [11:0] sample_data;
    wire        adc_request_overrun;
    wire        buffer_overflow;

    sample_rate_gen #(
        .CLOCK_HZ  (50000000),
        .SAMPLE_HZ (16000)
    ) sampler_clock (
        .clk     (MAX10_CLK1_50),
        .reset_n (reset_n),
        .tick    (sample_request)
    );

    adc_vendor_adapter adc (
        .clk             (MAX10_CLK1_50),
        .reset_n         (reset_n),
        .sample_request  (sample_request),
        .sample_valid    (sample_valid),
        .sample_data     (sample_data),
        .request_overrun (adc_request_overrun)
    );

    audio_core core (
        .clk             (MAX10_CLK1_50),
        .reset_n         (reset_n),
        .sample_valid    (sample_valid),
        .sample_data     (sample_data),
        .spi_sck         (SPI_SCK),
        .spi_mosi        (SPI_MOSI),
        .spi_cs_n        (SPI_CS_N),
        .spi_miso        (SPI_MISO),
        .block_ready     (BLOCK_READY),
        .sample_toggle   (SAMPLE_TOGGLE),
        .buffer_overflow (buffer_overflow)
    );

    // Temporary diagnostic LEDs.
    reg [25:0] heartbeat_counter;
    reg        sample_seen;

    always @(posedge MAX10_CLK1_50 or negedge reset_n) begin
        if (!reset_n) begin
            heartbeat_counter <= 26'd0;
            sample_seen       <= 1'b0;
        end else begin
            heartbeat_counter <= heartbeat_counter + 26'd1;

            // Stay lit after receiving at least one ADC sample.
            if (sample_valid)
                sample_seen <= 1'b1;
        end
    end

    assign LEDR[0] = heartbeat_counter[25];
    assign LEDR[1] = sample_seen;

endmodule