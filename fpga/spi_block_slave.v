module spi_block_slave(
    input  wire        clk,
    input  wire        reset_n,

    input  wire        spi_sck,
    input  wire        spi_mosi,
    input  wire        spi_cs_n,
    output reg         spi_miso,

    input  wire        ready0,
    input  wire        ready1,
    input  wire [31:0] seq0,
    input  wire [31:0] seq1,

    output reg  [9:0]  ram_addr,
    input  wire [11:0] ram0_data,
    input  wire [11:0] ram1_data,

    output reg         consume_valid,
    output reg         consume_sel
);
    // 4-byte little-endian sequence + 1024 uint16 samples.
    // SPI Mode 0, MSB first within each byte.
    // FPGA clock: 50 MHz. SPI SCK: <= 1 MHz.
    // Master holds CS low >= 2 us before the first SCK edge.

    localparam [11:0] TOTAL_BYTES = 12'd2052;
    localparam [11:0] LAST_BYTE   = 12'd2051;

    reg sck_meta, sck_sync, sck_prev;
    reg cs_meta,  cs_sync,  cs_prev;

    wire sck_rise = !sck_prev &&  sck_sync;
    wire sck_fall =  sck_prev && !sck_sync;
    wire cs_fall  =  cs_prev  && !cs_sync;
    wire cs_rise  = !cs_prev  &&  cs_sync;

    reg        active;
    reg        selected_buffer;
    reg [31:0] seq_latched;
    reg [11:0] byte_index;
    reg [2:0]  bit_index;
    reg [7:0]  current_byte;
    reg        payload_complete;

    wire [11:0] selected_ram_data =
        selected_buffer ? ram1_data : ram0_data;

    wire [11:0] next_byte_index = byte_index + 12'd1;

    // Choose the older block when both buffers are ready.
    wire [31:0] seq_delta = seq1 - seq0;
    wire seq0_is_older = (seq_delta < 32'h80000000);

    // The master samples the last bit on a rising SCK edge.
    wire final_sample_edge =
        active && sck_rise &&
        (byte_index == LAST_BYTE) &&
        (bit_index == 3'd0);

    reg [7:0] next_byte_value;

    always @(*) begin
        case (next_byte_index)
            12'd1:
                next_byte_value = seq_latched[15:8];

            12'd2:
                next_byte_value = seq_latched[23:16];

            12'd3:
                next_byte_value = seq_latched[31:24];

            default: begin
                if ((next_byte_index >= 12'd4) &&
                    (next_byte_index < TOTAL_BYTES)) begin

                    if (!next_byte_index[0])
                        next_byte_value = selected_ram_data[7:0];
                    else
                        next_byte_value =
                            {4'b0000, selected_ram_data[11:8]};
                end else begin
                    next_byte_value = 8'h00;
                end
            end
        endcase
    end

    // Synchronize external SPI signals to the FPGA clock.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sck_meta <= 1'b0;
            sck_sync <= 1'b0;
            sck_prev <= 1'b0;

            cs_meta <= 1'b1;
            cs_sync <= 1'b1;
            cs_prev <= 1'b1;
        end else begin
            sck_meta <= spi_sck;
            sck_sync <= sck_meta;
            sck_prev <= sck_sync;

            cs_meta <= spi_cs_n;
            cs_sync <= cs_meta;
            cs_prev <= cs_sync;
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            spi_miso         <= 1'b0;
            active           <= 1'b0;
            selected_buffer  <= 1'b0;
            seq_latched      <= 32'd0;
            byte_index       <= 12'd0;
            bit_index        <= 3'd7;
            current_byte     <= 8'd0;
            ram_addr         <= 10'd0;
            payload_complete <= 1'b0;
            consume_valid    <= 1'b0;
            consume_sel      <= 1'b0;
        end else begin
            consume_valid <= 1'b0;

            // Start a new transaction.
            if (cs_fall) begin
                byte_index       <= 12'd0;
                bit_index        <= 3'd7;
                ram_addr         <= 10'd0;
                payload_complete <= 1'b0;

                if (ready0 || ready1) begin
                    active <= 1'b1;

                    if (ready0 && (!ready1 || seq0_is_older)) begin
                        selected_buffer <= 1'b0;
                        seq_latched     <= seq0;
                        current_byte    <= seq0[7:0];
                        spi_miso        <= seq0[7];
                    end else begin
                        selected_buffer <= 1'b1;
                        seq_latched     <= seq1;
                        current_byte    <= seq1[7:0];
                        spi_miso        <= seq1[7];
                    end
                end else begin
                    active       <= 1'b0;
                    current_byte <= 8'd0;
                    spi_miso     <= 1'b0;
                end

            // End the transaction.
            end else if (cs_rise) begin
                // Release only after the final bit was sampled.
                // An incomplete transfer retains the buffer for retry.
                if (active &&
                    (payload_complete || final_sample_edge)) begin
                    consume_valid <= 1'b1;
                    consume_sel   <= selected_buffer;
                end

                active   <= 1'b0;
                spi_miso <= 1'b0;

            end else if (active) begin
                if (final_sample_edge)
                    payload_complete <= 1'b1;

                // Change MISO on falling SCK edges.
                if (sck_fall) begin
                    if (payload_complete) begin
                        spi_miso <= 1'b0;

                    end else if (bit_index != 3'd0) begin
                        bit_index <= bit_index - 3'd1;
                        spi_miso <= current_byte[bit_index - 3'd1];

                    end else if (byte_index < LAST_BYTE) begin
                        bit_index    <= 3'd7;
                        byte_index   <= next_byte_index;
                        current_byte <= next_byte_value;
                        spi_miso     <= next_byte_value[7];

                        // After latching sample k's high byte,
                        // prefetch sample k+1.
                        // Increment the RAM address from 0 to 1023.
                        if ((next_byte_index >= 12'd5) &&
                            next_byte_index[0] &&
                            (next_byte_index < LAST_BYTE)) begin
                            ram_addr <= ram_addr + 10'd1;
                        end
                    end else begin
                        spi_miso <= 1'b0;
                    end
                end
            end
        end
    end

    // MOSI is unused because this protocol has no command bytes.
endmodule