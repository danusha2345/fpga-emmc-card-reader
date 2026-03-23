// Testbench: UART Receiver (8N1)
// Generates UART waveform on RX pin, verifies data_out and data_valid
// Tests runtime clks_per_bit switching

`timescale 1ns / 1ps

module tb_uart_rx;

    localparam CLK_FREQ  = 96_000_000;
    localparam BAUD_RATE = 3_000_000;
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // 32

    reg        clk;
    reg        rst_n;
    reg        rx;
    reg  [7:0] clks_per_bit;
    wire [7:0] data_out;
    wire       data_valid;
    wire       frame_err;

    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) uut (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx           (rx),
        .clks_per_bit (clks_per_bit),
        .data_out     (data_out),
        .data_valid   (data_valid),
        .frame_err    (frame_err)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    // Generate UART frame on rx with explicit timing
    task send_uart_byte_timed(input [7:0] b, input integer cpb);
        integer i;
        begin
            // Start bit
            rx <= 1'b0;
            repeat (cpb) @(posedge clk);
            // 8 data bits, LSB first
            for (i = 0; i < 8; i = i + 1) begin
                rx <= b[i];
                repeat (cpb) @(posedge clk);
            end
            // Stop bit
            rx <= 1'b1;
            repeat (cpb) @(posedge clk);
        end
    endtask

    // Generate UART frame on rx: start(0) + 8 data bits (LSB first) + stop(1)
    task send_uart_byte(input [7:0] b);
        begin
            send_uart_byte_timed(b, CLKS_PER_BIT);
        end
    endtask

    // Generate bad frame (no stop bit)
    task send_uart_byte_bad_stop(input [7:0] b);
        integer i;
        begin
            rx <= 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx <= b[i];
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            // Bad stop bit (low instead of high)
            rx <= 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
            rx <= 1'b1; // return to idle
        end
    endtask

    // Wait for data_valid pulse and check
    reg       got_valid;
    reg [7:0] got_data;

    task wait_for_valid(input integer max_cycles);
        integer cnt;
        begin
            got_valid = 0;
            for (cnt = 0; cnt < max_cycles && !got_valid; cnt = cnt + 1) begin
                @(posedge clk);
                if (data_valid) begin
                    got_valid = 1;
                    got_data  = data_out;
                end
            end
        end
    endtask

    // Watchdog
    initial begin
        #1000000;
        $display("FAIL: tb_uart_rx - timeout");
        $finish(1);
    end

    initial begin
        rst_n = 0;
        rx    = 1'b1; // idle
        clks_per_bit = 8'd0;  // use compile-time default

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ---- Test 1: Receive 0x55 ----
        fork
            send_uart_byte(8'h55);
            wait_for_valid(CLKS_PER_BIT * 12);
        join
        if (!got_valid) begin
            $display("FAIL: 0x55 - no data_valid");
            errors = errors + 1;
        end else if (got_data !== 8'h55) begin
            $display("FAIL: 0x55 - got 0x%02X", got_data);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 2) @(posedge clk);

        // ---- Test 2: Receive 0xAA ----
        fork
            send_uart_byte(8'hAA);
            wait_for_valid(CLKS_PER_BIT * 12);
        join
        if (!got_valid || got_data !== 8'hAA) begin
            $display("FAIL: 0xAA - got_valid=%0d data=0x%02X", got_valid, got_data);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 2) @(posedge clk);

        // ---- Test 3: Receive 0x00 ----
        fork
            send_uart_byte(8'h00);
            wait_for_valid(CLKS_PER_BIT * 12);
        join
        if (!got_valid || got_data !== 8'h00) begin
            $display("FAIL: 0x00 - got_valid=%0d data=0x%02X", got_valid, got_data);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 2) @(posedge clk);

        // ---- Test 4: Receive 0xFF ----
        fork
            send_uart_byte(8'hFF);
            wait_for_valid(CLKS_PER_BIT * 12);
        join
        if (!got_valid || got_data !== 8'hFF) begin
            $display("FAIL: 0xFF - got_valid=%0d data=0x%02X", got_valid, got_data);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 2) @(posedge clk);

        // ---- Test 5: Frame error (bad stop bit) ----
        fork
            send_uart_byte_bad_stop(8'h42);
            begin
                // Wait for frame_err
                got_valid = 0;
                begin : frame_err_wait
                    integer cnt;
                    for (cnt = 0; cnt < CLKS_PER_BIT * 12; cnt = cnt + 1) begin
                        @(posedge clk);
                        if (frame_err) begin
                            got_valid = 1;
                            disable frame_err_wait;
                        end
                    end
                end
            end
        join
        if (!got_valid) begin
            $display("FAIL: frame error not detected");
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ---- Test 6: Recovery after frame error ----
        fork
            send_uart_byte(8'h7E);
            wait_for_valid(CLKS_PER_BIT * 12);
        join
        if (!got_valid || got_data !== 8'h7E) begin
            $display("FAIL: recovery after frame_err - got_valid=%0d data=0x%02X", got_valid, got_data);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ---- Test 7: Runtime CPB switch to 16 (6M equivalent at 96M) ----
        clks_per_bit = 8'd16;
        repeat (4) @(posedge clk);

        fork
            send_uart_byte_timed(8'hA5, 16);
            wait_for_valid(16 * 12);
        join
        if (!got_valid || got_data !== 8'hA5) begin
            $display("FAIL: CPB=16 - got_valid=%0d data=0x%02X", got_valid, got_data);
            errors = errors + 1;
        end

        repeat (16 * 2) @(posedge clk);

        // ---- Test 8: Runtime CPB switch to 8 (12M equivalent at 96M) ----
        clks_per_bit = 8'd8;
        repeat (4) @(posedge clk);

        fork
            send_uart_byte_timed(8'h3C, 8);
            wait_for_valid(8 * 12);
        join
        if (!got_valid || got_data !== 8'h3C) begin
            $display("FAIL: CPB=8 - got_valid=%0d data=0x%02X", got_valid, got_data);
            errors = errors + 1;
        end

        repeat (8 * 2) @(posedge clk);

        // ---- Test 9: Switch back to default (CPB=0) ----
        clks_per_bit = 8'd0;
        repeat (4) @(posedge clk);

        fork
            send_uart_byte(8'hB7);
            wait_for_valid(CLKS_PER_BIT * 12);
        join
        if (!got_valid || got_data !== 8'hB7) begin
            $display("FAIL: CPB=0 (default) - got_valid=%0d data=0x%02X", got_valid, got_data);
            errors = errors + 1;
        end

        // ---- Results ----
        repeat (4) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_uart_rx");
        else
            $display("[FAIL] tb_uart_rx (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
