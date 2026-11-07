module adc_vendor_adapter(
    input  wire        clk,
    input  wire        reset_n,
    input  wire        sample_request,
    output reg         sample_valid,
    output reg  [11:0] sample_data,
    output reg         request_overrun
);

    wire pll_clk;
    wire pll_locked;
    reg [1:0] lock_sync;

    adc_pll pll (
        .inclk0 (clk),
        .c0     (pll_clk),
        .locked (pll_locked)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            lock_sync <= 2'b00;
        else
            lock_sync <= {lock_sync[0], pll_locked};
    end

    wire adc_reset_n =
        reset_n && lock_sync[1] && !request_overrun;

    reg command_valid1;
    reg command_valid2;

    wire command_ready1;
    wire command_ready2;

    wire        response_valid1;
    wire [4:0]  response_channel1;
    wire [11:0] response_data1;
    wire        response_valid2;

    max10_adc_system adc_ip (
        .clk_clk               (clk),
        .reset_reset_n         (adc_reset_n),
        .adc_pll_clock_clk     (pll_clk),
        .adc_pll_locked_export (pll_locked),

        // ADC1 CH1: microphone on Arduino A0.
        .adc_command_valid         (command_valid1),
        .adc_command_channel       (5'd1),
        .adc_command_startofpacket (1'b1),
        .adc_command_endofpacket   (1'b1),
        .adc_command_ready         (command_ready1),

        .adc_response_valid         (response_valid1),
        .adc_response_channel       (response_channel1),
        .adc_response_data          (response_data1),
        .adc_response_startofpacket (),
        .adc_response_endofpacket   (),

        // ADC2 CH0: conversion partner, data discarded.
        .adc_command2_valid         (command_valid2),
        .adc_command2_channel       (5'd0),
        .adc_command2_startofpacket (1'b1),
        .adc_command2_endofpacket   (1'b1),
        .adc_command2_ready         (command_ready2),

        .adc_response2_valid         (response_valid2),
        .adc_response2_channel       (),
        .adc_response2_data          (),
        .adc_response2_startofpacket (),
        .adc_response2_endofpacket   ()
    );

    // Allow 1 ms for ADC startup at a 50 MHz system clock.
    reg [15:0] warmup_count;
    reg started;
    reg pending1;
    reg pending2;

    wire fault_now =
        (response_valid1 &&
         (!pending1 || response_channel1 != 5'd1)) ||

        (response_valid2 && !pending2) ||

        (sample_request &&
         (command_valid1 || command_valid2 ||
          (pending1 && !response_valid1) ||
          (pending2 && !response_valid2)));

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            command_valid1  <= 1'b0;
            command_valid2  <= 1'b0;
            sample_valid    <= 1'b0;
            sample_data     <= 12'd0;
            request_overrun <= 1'b0;
            warmup_count    <= 16'd0;
            started         <= 1'b0;
            pending1        <= 1'b0;
            pending2        <= 1'b0;

        end else begin
            sample_valid <= 1'b0;

            if (request_overrun) begin
                command_valid1 <= 1'b0;
                command_valid2 <= 1'b0;
                pending1       <= 1'b0;
                pending2       <= 1'b0;
                started        <= 1'b0;

            end else if (!started) begin
                // Wait for PLL and startup time, not command_ready.
                if (!lock_sync[1]) begin
                    warmup_count <= 16'd0;

                end else if (warmup_count == 16'd49999) begin
                    started <= 1'b1;

                end else begin
                    warmup_count <= warmup_count + 16'd1;
                end

            end else if (!lock_sync[1] || fault_now) begin
                // Sticky fault until KEY0 reset.
                request_overrun <= 1'b1;
                command_valid1  <= 1'b0;
                command_valid2  <= 1'b0;
                pending1        <= 1'b0;
                pending2        <= 1'b0;

            end else begin
                // Keep valid HIGH until each ADC acknowledges it.
                if (command_valid1 && command_ready1)
                    command_valid1 <= 1'b0;

                if (command_valid2 && command_ready2)
                    command_valid2 <= 1'b0;

                // Forward ADC1 samples to the audio buffer.
                if (response_valid1) begin
                    sample_data  <= response_data1;
                    sample_valid <= 1'b1;
                    pending1     <= 1'b0;
                end

                if (response_valid2)
                    pending2 <= 1'b0;

                // Launch both commands at each hardware sampling tick.
                // command_ready is allowed to be LOW at launch.
                if (sample_request) begin
                    command_valid1 <= 1'b1;
                    command_valid2 <= 1'b1;
                    pending1       <= 1'b1;
                    pending2       <= 1'b1;
                end
            end
        end
    end

endmodule