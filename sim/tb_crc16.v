// Testbench: CRC-16 CCITT (eMMC DAT line)
// Polynomial: x^16 + x^12 + x^5 + 1 (0x1021), init=0, serial bit-by-bit

`timescale 1ns / 1ps

module tb_crc16;

    reg         clk;
    reg         rst_n;
    reg         clear;
    reg         enable;
    reg         bit_in;
    wire [15:0] crc_out;

    emmc_crc16 uut (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (clear),
        .enable  (enable),
        .bit_in  (bit_in),
        .crc_out (crc_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    task feed_bit(input b);
        begin
            @(posedge clk);
            bit_in <= b;
            enable <= 1'b1;
            @(posedge clk);
            enable <= 1'b0;
        end
    endtask

    // Feed a byte MSB-first
    task feed_byte(input [7:0] b);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1)
                feed_bit(b[i]);
        end
    endtask

    task check_crc(input [15:0] expected, input [255:0] label);
        begin
            @(posedge clk);
            if (crc_out !== expected) begin
                $display("FAIL: %0s: got 0x%04X, expected 0x%04X", label, crc_out, expected);
                errors = errors + 1;
            end
        end
    endtask

    integer j;

    // Watchdog
    initial begin
        #50_000_000;
        $display("FAIL: tb_crc16 - timeout");
        $finish(1);
    end

    initial begin
        rst_n  = 0;
        clear  = 0;
        enable = 0;
        bit_in = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- Test 1: 4-byte [01,02,03,04] ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h01);
        feed_byte(8'h02);
        feed_byte(8'h03);
        feed_byte(8'h04);
        check_crc(16'h0D03, "[01,02,03,04]");

        // ---- Test 2: Single byte 0x55 ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h55);
        check_crc(16'h0A50, "[55]");

        // ---- Test 3: 512 bytes all-zeros ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        for (j = 0; j < 512; j = j + 1)
            feed_byte(8'h00);
        check_crc(16'h0000, "512x 0x00");

        // ---- Test 4: 512 bytes all-FF ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        for (j = 0; j < 512; j = j + 1)
            feed_byte(8'hFF);
        check_crc(16'h7FA1, "512x 0xFF");

        // ---- Test 5: Verify clear ----
        feed_byte(8'hAB);
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        @(posedge clk);
        if (crc_out !== 16'h0000) begin
            $display("FAIL: clear: got 0x%04X, expected 0x0000", crc_out);
            errors = errors + 1;
        end

        // ---- Results ----
        repeat (2) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_crc16");
        else
            $display("[FAIL] tb_crc16 (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
