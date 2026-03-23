// Testbench: Dual-port sector buffer (1024 bytes = 2x512, ping-pong)

`timescale 1ns / 1ps

module tb_sector_buf;

    reg        clk;

    reg        buf_sel_a;
    reg  [8:0] addr_a;
    reg  [7:0] wdata_a;
    reg        we_a;
    wire [7:0] rdata_a;

    reg        buf_sel_b;
    reg  [8:0] addr_b;
    reg  [7:0] wdata_b;
    reg        we_b;
    wire [7:0] rdata_b;

    sector_buf uut (
        .clk       (clk),
        .buf_sel_a (buf_sel_a),
        .addr_a    (addr_a),
        .wdata_a   (wdata_a),
        .we_a      (we_a),
        .rdata_a   (rdata_a),
        .buf_sel_b (buf_sel_b),
        .addr_b    (addr_b),
        .wdata_b   (wdata_b),
        .we_b      (we_b),
        .rdata_b   (rdata_b)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer i;

    // Watchdog
    initial begin
        #1_000_000;
        $display("FAIL: tb_sector_buf - timeout");
        $finish(1);
    end

    initial begin
        buf_sel_a = 0; addr_a = 0; wdata_a = 0; we_a = 0;
        buf_sel_b = 0; addr_b = 0; wdata_b = 0; we_b = 0;

        repeat (4) @(posedge clk);

        // ---- Test 1: Write via port A (buf 0), read via port B ----
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            buf_sel_a <= 1'b0;
            addr_a    <= i[8:0];
            wdata_a   <= i[7:0] + 8'hA0;
            we_a      <= 1'b1;
        end
        @(posedge clk);
        we_a <= 1'b0;

        // Read back via port B from buf 0
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            buf_sel_b <= 1'b0;
            addr_b    <= i[8:0];
            we_b      <= 1'b0;
            @(posedge clk); // addr applied, BRAM reads
            @(posedge clk); // rdata_b NBA resolved, now valid
            if (rdata_b !== (i[7:0] + 8'hA0)) begin
                $display("FAIL: buf0 addr %0d: got 0x%02X, expected 0x%02X",
                         i, rdata_b, i[7:0] + 8'hA0);
                errors = errors + 1;
            end
        end

        // ---- Test 2: Write via port B (buf 1), read via port A ----
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            buf_sel_b <= 1'b1;
            addr_b    <= i[8:0];
            wdata_b   <= i[7:0] + 8'hB0;
            we_b      <= 1'b1;
        end
        @(posedge clk);
        we_b <= 1'b0;

        // Read back via port A from buf 1
        for (i = 0; i < 16; i = i + 1) begin
            @(posedge clk);
            buf_sel_a <= 1'b1;
            addr_a    <= i[8:0];
            we_a      <= 1'b0;
            @(posedge clk); // addr applied, BRAM reads
            @(posedge clk); // rdata_a NBA resolved
            if (rdata_a !== (i[7:0] + 8'hB0)) begin
                $display("FAIL: buf1 addr %0d: got 0x%02X, expected 0x%02X",
                         i, rdata_a, i[7:0] + 8'hB0);
                errors = errors + 1;
            end
        end

        // ---- Test 3: Buffers are independent (buf 0 data still intact) ----
        @(posedge clk);
        buf_sel_b <= 1'b0;
        addr_b    <= 9'd0;
        we_b      <= 1'b0;
        @(posedge clk); // addr applied
        @(posedge clk); // BRAM reads
        @(posedge clk); // rdata_b valid
        if (rdata_b !== 8'hA0) begin
            $display("FAIL: buf0 not independent: got 0x%02X, expected 0xA0", rdata_b);
            errors = errors + 1;
        end

        // ---- Test 4: Write-through (on write, output = wdata) ----
        @(posedge clk);
        buf_sel_a <= 1'b0;
        addr_a    <= 9'd100;
        wdata_a   <= 8'hCD;
        we_a      <= 1'b1;
        @(posedge clk); // write happens, rdata_a <= wdata_a (NBA)
        we_a <= 1'b0;
        @(posedge clk); // rdata_a NBA resolved
        if (rdata_a !== 8'hCD) begin
            $display("FAIL: write-through: got 0x%02X, expected 0xCD", rdata_a);
            errors = errors + 1;
        end

        // ---- Test 5: Simultaneous access to different buffers ----
        @(posedge clk);
        buf_sel_a <= 1'b0;  addr_a <= 9'd0; we_a <= 1'b0;
        buf_sel_b <= 1'b1;  addr_b <= 9'd0; we_b <= 1'b0;
        @(posedge clk); // addr applied
        @(posedge clk); // BRAM reads
        @(posedge clk); // rdata valid
        if (rdata_a !== 8'hA0) begin
            $display("FAIL: concurrent read A buf0: got 0x%02X, expected 0xA0", rdata_a);
            errors = errors + 1;
        end
        if (rdata_b !== 8'hB0) begin
            $display("FAIL: concurrent read B buf1: got 0x%02X, expected 0xB0", rdata_b);
            errors = errors + 1;
        end

        // ---- Test 6: Max address (511) in buf 0 ----
        @(posedge clk);
        buf_sel_a <= 1'b0;
        addr_a    <= 9'd511;
        wdata_a   <= 8'hEF;
        we_a      <= 1'b1;
        @(posedge clk);
        we_a <= 1'b0;
        @(posedge clk);
        buf_sel_b <= 1'b0;
        addr_b    <= 9'd511;
        we_b      <= 1'b0;
        @(posedge clk); // addr applied
        @(posedge clk); // BRAM reads
        @(posedge clk); // rdata valid
        if (rdata_b !== 8'hEF) begin
            $display("FAIL: addr 511: got 0x%02X, expected 0xEF", rdata_b);
            errors = errors + 1;
        end

        // ---- Results ----
        repeat (2) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_sector_buf");
        else
            $display("[FAIL] tb_sector_buf (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
