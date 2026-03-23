// Testbench: CRC-8 (UART protocol)
// Polynomial: x^8 + x^2 + x + 1 (0x07), init=0, parallel byte processing

`timescale 1ns / 1ps

module tb_crc8;

    reg        clk;
    reg        rst_n;
    reg        clear;
    reg        enable;
    reg  [7:0] data_in;
    wire [7:0] crc_out;

    crc8 uut (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (clear),
        .enable  (enable),
        .data_in (data_in),
        .crc_out (crc_out)
    );

    // Clock: 10 ns period
    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    task feed_byte(input [7:0] b);
        begin
            @(posedge clk);
            data_in <= b;
            enable  <= 1'b1;
            @(posedge clk);
            enable  <= 1'b0;
        end
    endtask

    task check_crc(input [7:0] expected, input [255:0] label);
        begin
            @(posedge clk); // allow output to settle
            if (crc_out !== expected) begin
                $display("FAIL: %0s: got 0x%02X, expected 0x%02X", label, crc_out, expected);
                errors = errors + 1;
            end
        end
    endtask

    // Watchdog
    initial begin
        #100000;
        $display("FAIL: tb_crc8 - timeout");
        $finish(1);
    end

    initial begin
        rst_n   = 0;
        clear   = 0;
        enable  = 0;
        data_in = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- Test 1: Single byte 0x01 ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h01);
        check_crc(8'h07, "single 0x01");

        // ---- Test 2: PING packet payload [0x01, 0x00, 0x00] ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h01);
        feed_byte(8'h00);
        feed_byte(8'h00);
        check_crc(8'h6B, "PING [01,00,00]");

        // ---- Test 3: GET_INFO [0x02, 0x00, 0x00] ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h02);
        feed_byte(8'h00);
        feed_byte(8'h00);
        check_crc(8'hD6, "GET_INFO [02,00,00]");

        // ---- Test 4: Unknown command [0xFF, 0x00, 0x00] ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'hFF);
        feed_byte(8'h00);
        feed_byte(8'h00);
        check_crc(8'h2B, "unknown [FF,00,00]");

        // ---- Test 5: Response [0x01, 0x00, 0x00, 0x00] ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h01);
        feed_byte(8'h00);
        feed_byte(8'h00);
        feed_byte(8'h00);
        check_crc(8'h16, "PING resp [01,00,00,00]");

        // ---- Test 6: CRC of 0x55 ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'h55);
        check_crc(8'hAC, "single 0x55");

        // ---- Test 7: CRC of 0xAA ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'hAA);
        check_crc(8'h5F, "single 0xAA");

        // ---- Test 8: Verify clear works mid-stream ----
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        feed_byte(8'hFF);
        // Now clear and check it's back to 0
        clear <= 1'b1;
        @(posedge clk);
        clear <= 1'b0;
        @(posedge clk);
        if (crc_out !== 8'h00) begin
            $display("FAIL: clear mid-stream: got 0x%02X, expected 0x00", crc_out);
            errors = errors + 1;
        end

        // ---- Results ----
        repeat (2) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_crc8");
        else
            $display("[FAIL] tb_crc8 (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
