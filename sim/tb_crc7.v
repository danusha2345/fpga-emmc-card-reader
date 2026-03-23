// Testbench: CRC-7 (eMMC CMD line)
// Polynomial: x^7 + x^3 + 1 (0x09), init=0, serial bit-by-bit

`timescale 1ns / 1ps

module tb_crc7;

    reg        clk;
    reg        rst_n;
    reg        clear;
    reg        enable;
    reg        bit_in;
    wire [6:0] crc_out;

    emmc_crc7 uut (
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

    // Feed one bit on posedge clk
    task feed_bit(input b);
        begin
            @(posedge clk);
            bit_in <= b;
            enable <= 1'b1;
            @(posedge clk);
            enable <= 1'b0;
        end
    endtask

    // Feed a byte MSB-first (8 bits)
    task feed_byte(input [7:0] b);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1)
                feed_bit(b[i]);
        end
    endtask

    task check_crc(input [6:0] expected, input [255:0] label);
        begin
            @(posedge clk);
            if (crc_out !== expected) begin
                $display("FAIL: %0s: got 0x%02X, expected 0x%02X", label, crc_out, expected);
                errors = errors + 1;
            end
        end
    endtask

    // Watchdog
    initial begin
        #500000;
        $display("FAIL: tb_crc7 - timeout");
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

        // ---- Test 1: CMD0 (GO_IDLE_STATE) ----
        // 48-bit frame: start=0, tx=1, index=000000, arg=00000000
        // CRC covers first 40 bits: 0x40 0x00 0x00 0x00 0x00
        // Expected CRC7 = 0x4A
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h40);  // 01 000000
        feed_byte(8'h00);
        feed_byte(8'h00);
        feed_byte(8'h00);
        feed_byte(8'h00);
        check_crc(7'h4A, "CMD0");

        // ---- Test 2: CMD1 (SEND_OP_COND, arg=0x40FF8000) ----
        // 0x41 0x40 0xFF 0x80 0x00
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h41);
        feed_byte(8'h40);
        feed_byte(8'hFF);
        feed_byte(8'h80);
        feed_byte(8'h00);
        check_crc(7'h05, "CMD1(0x40FF8000)");

        // ---- Test 3: CMD2 (ALL_SEND_CID, arg=0x00000000) ----
        // 0x42 0x00 0x00 0x00 0x00
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h42);
        feed_byte(8'h00);
        feed_byte(8'h00);
        feed_byte(8'h00);
        feed_byte(8'h00);
        check_crc(7'h26, "CMD2(0x00000000)");

        // ---- Test 4: CMD3 (SET_RELATIVE_ADDR, arg=0x00010000) ----
        // 0x43 0x00 0x01 0x00 0x00
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h43);
        feed_byte(8'h00);
        feed_byte(8'h01);
        feed_byte(8'h00);
        feed_byte(8'h00);
        check_crc(7'h3F, "CMD3(0x00010000)");

        // ---- Test 5: Verify clear resets CRC ----
        feed_byte(8'hFF); // some data
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        @(posedge clk);
        if (crc_out !== 7'h00) begin
            $display("FAIL: clear: got 0x%02X, expected 0x00", crc_out);
            errors = errors + 1;
        end

        // ---- Results ----
        repeat (2) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_crc7");
        else
            $display("[FAIL] tb_crc7 (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
