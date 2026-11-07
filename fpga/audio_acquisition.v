module audio_acquisition(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        sample_valid,
    input  wire [11:0] sample_data,

    input  wire        consume_valid,
    input  wire        consume_sel,

    output reg         wr_en0,
    output reg         wr_en1,
    output reg  [9:0]  wr_addr,
    output reg  [11:0] wr_data,

    output reg         ready0,
    output reg         ready1,
    output reg  [31:0] seq0,
    output reg  [31:0] seq1,
    output reg  [31:0] dropped_blocks
);
    reg        write_sel;
    reg [9:0]  sample_index;
    reg        dropping;
    reg [9:0]  drop_index;
    reg [31:0] next_sequence;

    wire ready0_effective = ready0 && !(consume_valid && (consume_sel == 1'b0));
    wire ready1_effective = ready1 && !(consume_valid && (consume_sel == 1'b1));

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wr_en0         <= 1'b0;
            wr_en1         <= 1'b0;
            wr_addr        <= 10'd0;
            wr_data        <= 12'd0;
            ready0         <= 1'b0;
            ready1         <= 1'b0;
            seq0           <= 32'd0;
            seq1           <= 32'd0;
            write_sel      <= 1'b0;
            sample_index   <= 10'd0;
            dropping       <= 1'b0;
            drop_index     <= 10'd0;
            next_sequence  <= 32'd0;
            dropped_blocks <= 32'd0;
        end else begin
            wr_en0 <= 1'b0;
            wr_en1 <= 1'b0;

            if (consume_valid) begin
                if (consume_sel == 1'b0)
                    ready0 <= 1'b0;
                else
                    ready1 <= 1'b0;
            end

            if (sample_valid) begin
                if (!dropping) begin
                    wr_addr <= sample_index;
                    wr_data <= sample_data;
                    if (write_sel == 1'b0)
                        wr_en0 <= 1'b1;
                    else
                        wr_en1 <= 1'b1;

                    if (sample_index == 10'd1023) begin
                        if (write_sel == 1'b0) begin
                            ready0 <= 1'b1;
                            seq0   <= next_sequence;
                        end else begin
                            ready1 <= 1'b1;
                            seq1   <= next_sequence;
                        end
                        next_sequence <= next_sequence + 32'd1;
                        sample_index  <= 10'd0;

                        if (write_sel == 1'b0) begin
                            if (!ready1_effective) begin
                                write_sel <= 1'b1;
                            end else begin
                                dropping   <= 1'b1;
                                drop_index <= 10'd0;
                            end
                        end else begin
                            if (!ready0_effective) begin
                                write_sel <= 1'b0;
                            end else begin
                                dropping   <= 1'b1;
                                drop_index <= 10'd0;
                            end
                        end
                    end else begin
                        sample_index <= sample_index + 10'd1;
                    end
                end else begin
                    // Both application buffers were busy. Keep ADC timing running,
                    // discard complete 1024-sample blocks, and preserve sequence gaps
                    // so the host can detect that loss occurred.
                    if (drop_index == 10'd1023) begin
                        drop_index     <= 10'd0;
                        next_sequence  <= next_sequence + 32'd1;
                        dropped_blocks <= dropped_blocks + 32'd1;

                        if (!ready0_effective) begin
                            write_sel    <= 1'b0;
                            dropping     <= 1'b0;
                            sample_index <= 10'd0;
                        end else if (!ready1_effective) begin
                            write_sel    <= 1'b1;
                            dropping     <= 1'b0;
                            sample_index <= 10'd0;
                        end
                    end else begin
                        drop_index <= drop_index + 10'd1;
                    end
                end
            end
        end
    end
endmodule
