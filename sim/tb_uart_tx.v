// Testbench: UART Transmitter (8N1)
// Verifies start bit, 8 data bits (LSB first), stop bit, busy signal
// Tests runtime clks_per_bit switching

`timescale 1ns / 1ps

module tb_uart_tx;

    // Use small divider for fast simulation
    localparam CLK_FREQ  = 96_000_000;
    localparam BAUD_RATE = 3_000_000;
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // 32

    reg        clk;
    reg        rst_n;
    reg  [7:0] data_in;
    reg        data_valid;
    reg  [7:0] clks_per_bit;
    wire       tx;
    wire       busy;

    uart_tx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) uut (
        .clk          (clk),
        .rst_n        (rst_n),
        .data_in      (data_in),
        .data_valid   (data_valid),
        .clks_per_bit (clks_per_bit),
        .tx           (tx),
        .busy         (busy)
    );

    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz (close enough for test)

    integer errors = 0;
    integer i;
    reg [7:0] captured_byte;

    // Sample TX line at the middle of each bit period (parameterized)
    task capture_byte_timed(input integer cpb);
        begin
            // Wait for start bit (tx goes low)
            wait (tx == 1'b0);
            // Advance to middle of start bit
            repeat (cpb / 2) @(posedge clk);
            if (tx !== 1'b0) begin
                $display("FAIL: start bit not low");
                errors = errors + 1;
            end
            // Sample 8 data bits (LSB first)
            for (i = 0; i < 8; i = i + 1) begin
                repeat (cpb) @(posedge clk);
                captured_byte[i] = tx;
            end
            // Sample stop bit
            repeat (cpb) @(posedge clk);
            if (tx !== 1'b1) begin
                $display("FAIL: stop bit not high");
                errors = errors + 1;
            end
        end
    endtask

    task capture_byte;
        begin
            capture_byte_timed(CLKS_PER_BIT);
        end
    endtask

    // Watchdog
    initial begin
        #1000000;
        $display("FAIL: tb_uart_tx - timeout");
        $finish(1);
    end

    initial begin
        rst_n      = 0;
        data_in    = 0;
        data_valid = 0;
        clks_per_bit = 8'd0;  // use compile-time default

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- Test 1: TX idle state ----
        if (tx !== 1'b1) begin
            $display("FAIL: TX not idle high");
            errors = errors + 1;
        end
        if (busy !== 1'b0) begin
            $display("FAIL: busy should be 0 in idle");
            errors = errors + 1;
        end

        // ---- Test 2: Send 0x55 (01010101) ----
        @(posedge clk);
        data_in    <= 8'h55;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;

        capture_byte;
        if (captured_byte !== 8'h55) begin
            $display("FAIL: sent 0x55, captured 0x%02X", captured_byte);
            errors = errors + 1;
        end

        // Wait for idle
        repeat (CLKS_PER_BIT * 2) @(posedge clk);

        // ---- Test 3: Send 0xAA (10101010) ----
        @(posedge clk);
        data_in    <= 8'hAA;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;

        capture_byte;
        if (captured_byte !== 8'hAA) begin
            $display("FAIL: sent 0xAA, captured 0x%02X", captured_byte);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 2) @(posedge clk);

        // ---- Test 4: Send 0x00 ----
        @(posedge clk);
        data_in    <= 8'h00;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;

        capture_byte;
        if (captured_byte !== 8'h00) begin
            $display("FAIL: sent 0x00, captured 0x%02X", captured_byte);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 2) @(posedge clk);

        // ---- Test 5: Send 0xFF ----
        @(posedge clk);
        data_in    <= 8'hFF;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;

        capture_byte;
        if (captured_byte !== 8'hFF) begin
            $display("FAIL: sent 0xFF, captured 0x%02X", captured_byte);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 2) @(posedge clk);

        // ---- Test 6: Busy signal during transmission ----
        @(posedge clk);
        data_in    <= 8'h42;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;
        @(posedge clk);
        if (busy !== 1'b1) begin
            $display("FAIL: busy should be 1 during TX");
            errors = errors + 1;
        end
        // Wait for completion
        wait (busy == 1'b0);
        repeat (2) @(posedge clk);

        // ---- Test 7: Runtime CPB switch to 16 (6M equivalent at 96M) ----
        clks_per_bit = 8'd16;
        repeat (4) @(posedge clk);

        @(posedge clk);
        data_in    <= 8'hA5;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;

        capture_byte_timed(16);
        if (captured_byte !== 8'hA5) begin
            $display("FAIL: CPB=16 sent 0xA5, captured 0x%02X", captured_byte);
            errors = errors + 1;
        end

        wait (busy == 1'b0);
        repeat (16 * 2) @(posedge clk);

        // ---- Test 8: Runtime CPB switch to 8 (12M equivalent at 96M) ----
        clks_per_bit = 8'd8;
        repeat (4) @(posedge clk);

        @(posedge clk);
        data_in    <= 8'h3C;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;

        capture_byte_timed(8);
        if (captured_byte !== 8'h3C) begin
            $display("FAIL: CPB=8 sent 0x3C, captured 0x%02X", captured_byte);
            errors = errors + 1;
        end

        wait (busy == 1'b0);
        repeat (8 * 2) @(posedge clk);

        // ---- Test 9: Switch back to default (CPB=0) ----
        clks_per_bit = 8'd0;
        repeat (4) @(posedge clk);

        @(posedge clk);
        data_in    <= 8'hB7;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;

        capture_byte;
        if (captured_byte !== 8'hB7) begin
            $display("FAIL: CPB=0 (default) sent 0xB7, captured 0x%02X", captured_byte);
            errors = errors + 1;
        end

        wait (busy == 1'b0);
        repeat (2) @(posedge clk);

        // ---- Results ----
        if (errors == 0)
            $display("[PASS] tb_uart_tx");
        else
            $display("[FAIL] tb_uart_tx (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
