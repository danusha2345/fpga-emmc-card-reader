// Testbench: 16-bank write FIFO (8192 bytes = 16x512)

`timescale 1ns / 1ps

module tb_sector_buf_wr;

    reg        clk;

    // Port A (eMMC read side)
    reg  [3:0] rd_bank;
    reg  [8:0] rd_addr;
    wire [7:0] rd_data;

    // Port B (UART write side)
    reg  [3:0] wr_bank;
    reg  [8:0] wr_addr;
    reg  [7:0] wr_data;
    reg        wr_en;

    sector_buf_wr uut (
        .clk     (clk),
        .rd_bank (rd_bank),
        .rd_addr (rd_addr),
        .rd_data (rd_data),
        .wr_bank (wr_bank),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .wr_en   (wr_en)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer i, b;
    reg [7:0] expected;

    // Watchdog
    initial begin
        #10_000_000;
        $display("FAIL: tb_sector_buf_wr - timeout");
        $finish(1);
    end

    // Helper task: set read address, wait for registered output, check value.
    // Registered output = 1-cycle latency:
    //   posedge clk #1: addr applied via NBA
    //   posedge clk #2: mem[addr] latched into rd_data via NBA
    //   posedge clk #3: rd_data NBA resolved, value visible in procedural code
    task read_and_check;
        input [3:0]  t_bank;
        input [8:0]  t_addr;
        input [7:0]  t_expected;
        input [79:0] t_label; // 10-char ASCII tag
        begin
            @(posedge clk);
            rd_bank <= t_bank;
            rd_addr <= t_addr;
            @(posedge clk); // addr applied, BRAM reads
            @(posedge clk); // rd_data NBA resolved
            if (rd_data !== t_expected) begin
                $display("FAIL: %0s bank%0d addr %0d: got 0x%02X, expected 0x%02X",
                         t_label, t_bank, t_addr, rd_data, t_expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        rd_bank = 0; rd_addr = 0;
        wr_bank = 0; wr_addr = 0; wr_data = 0; wr_en = 0;

        repeat (4) @(posedge clk);

        // ---- Test 1: Write/read one sector (512 bytes, bank 0) ----
        $display("Test 1: Write/read one sector (bank 0)");
        for (i = 0; i < 512; i = i + 1) begin
            @(posedge clk);
            wr_bank <= 4'd0;
            wr_addr <= i[8:0];
            wr_data <= i[7:0] ^ 8'h5A;
            wr_en   <= 1'b1;
        end
        @(posedge clk);
        wr_en <= 1'b0;

        // Read back via Port A
        for (i = 0; i < 512; i = i + 1) begin
            expected = i[7:0] ^ 8'h5A;
            read_and_check(4'd0, i[8:0], expected, "T1");
        end

        // ---- Test 2: Fill all 16 banks, verify independence ----
        $display("Test 2: Fill all 16 banks");
        for (b = 0; b < 16; b = b + 1) begin
            for (i = 0; i < 512; i = i + 1) begin
                @(posedge clk);
                wr_bank <= b[3:0];
                wr_addr <= i[8:0];
                wr_data <= (b[7:0] * 8'd37 + i[7:0]) ^ 8'hCC;
                wr_en   <= 1'b1;
            end
        end
        @(posedge clk);
        wr_en <= 1'b0;

        // Read back each bank — spot-check first, middle, last byte per bank
        for (b = 0; b < 16; b = b + 1) begin
            // addr 0
            expected = (b[7:0] * 8'd37) ^ 8'hCC;
            read_and_check(b[3:0], 9'd0, expected, "T2");
            // addr 255
            expected = (b[7:0] * 8'd37 + 8'd255) ^ 8'hCC;
            read_and_check(b[3:0], 9'd255, expected, "T2");
            // addr 511
            expected = (b[7:0] * 8'd37 + 9'd511) ^ 8'hCC;
            read_and_check(b[3:0], 9'd511, expected, "T2");
        end

        // ---- Test 3: Concurrent read/write different banks ----
        $display("Test 3: Concurrent read/write different banks");
        // Write to bank 5 while reading bank 3 simultaneously
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            // Write to bank 5
            wr_bank <= 4'd5;
            wr_addr <= i[8:0];
            wr_data <= i[7:0] + 8'hD0;
            wr_en   <= 1'b1;
            // Read from bank 3 simultaneously
            rd_bank <= 4'd3;
            rd_addr <= i[8:0];
        end
        @(posedge clk);
        wr_en <= 1'b0;

        // Verify bank 3 still has correct data from Test 2
        for (i = 0; i < 16; i = i + 1) begin
            expected = (8'd3 * 8'd37 + i[7:0]) ^ 8'hCC;
            read_and_check(4'd3, i[8:0], expected, "T3-rd");
        end

        // Verify bank 5 got correctly written
        for (i = 0; i < 16; i = i + 1) begin
            expected = i[7:0] + 8'hD0;
            read_and_check(4'd5, i[8:0], expected, "T3-wr");
        end

        // ---- Test 4: Wrap-around (bank 15 -> bank 0) ----
        $display("Test 4: Wrap-around bank 15 -> bank 0");
        // Write pattern to bank 15
        for (i = 0; i < 512; i = i + 1) begin
            @(posedge clk);
            wr_bank <= 4'd15;
            wr_addr <= i[8:0];
            wr_data <= i[7:0] ^ 8'hFF;
            wr_en   <= 1'b1;
        end
        // Immediately write different pattern to bank 0
        for (i = 0; i < 512; i = i + 1) begin
            @(posedge clk);
            wr_bank <= 4'd0;
            wr_addr <= i[8:0];
            wr_data <= i[7:0] ^ 8'h11;
            wr_en   <= 1'b1;
        end
        @(posedge clk);
        wr_en <= 1'b0;

        // Verify bank 15
        for (i = 0; i < 512; i = i + 1) begin
            expected = i[7:0] ^ 8'hFF;
            read_and_check(4'd15, i[8:0], expected, "T4-b15");
        end

        // Verify bank 0 (overwritten by wrap)
        for (i = 0; i < 512; i = i + 1) begin
            expected = i[7:0] ^ 8'h11;
            read_and_check(4'd0, i[8:0], expected, "T4-b0");
        end

        // ---- Test 5: Max address boundary (addr 511) in multiple banks ----
        $display("Test 5: Max address boundary (addr 511)");
        for (b = 0; b < 16; b = b + 1) begin
            @(posedge clk);
            wr_bank <= b[3:0];
            wr_addr <= 9'd511;
            wr_data <= b[7:0] + 8'hE0;
            wr_en   <= 1'b1;
        end
        @(posedge clk);
        wr_en <= 1'b0;

        // Read addr 511 from each bank
        for (b = 0; b < 16; b = b + 1) begin
            expected = b[7:0] + 8'hE0;
            read_and_check(b[3:0], 9'd511, expected, "T5");
        end

        // ---- Results ----
        repeat (2) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_sector_buf_wr");
        else
            $display("[FAIL] tb_sector_buf_wr (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
