// Testbench: eMMC DAT0 Read/Write Handler
// Unit test for emmc_dat.v
//
// Timing architecture:
//   clk_div counts 0→1→2→3→0...
//   clk_en fires when old_div==2 (UUT reads at old_div==3)
//   Card FSM fires at old_div==1 (2 cycles before UUT)
//   This ensures dat_in_reg is stable when both UUT and CRC module read it.

`timescale 1ns / 1ps

module tb_emmc_dat;

    reg        clk;
    reg        rst_n;
    reg        clk_en;

    reg        rd_start;
    wire       rd_done;
    wire       rd_crc_err;

    reg        wr_start;
    wire       wr_done;
    wire       wr_crc_err;

    wire [7:0]  buf_wr_data;
    wire [8:0]  buf_wr_addr;
    wire        buf_wr_en;

    wire [8:0]  buf_rd_addr;
    reg  [7:0]  buf_rd_data;

    wire       dat_out;
    wire       dat_oe;
    reg        dat_in_reg;

    wire       dat_line = dat_oe ? dat_out : dat_in_reg;

    emmc_dat uut (
        .clk         (clk),
        .rst_n       (rst_n),
        .clk_en      (clk_en),
        .rd_start    (rd_start),
        .rd_done     (rd_done),
        .rd_crc_err  (rd_crc_err),
        .wr_start    (wr_start),
        .wr_done     (wr_done),
        .wr_crc_err  (wr_crc_err),
        .buf_wr_data (buf_wr_data),
        .buf_wr_addr (buf_wr_addr),
        .buf_wr_en   (buf_wr_en),
        .buf_rd_addr (buf_rd_addr),
        .buf_rd_data (buf_rd_data),
        .dat_out     (dat_out),
        .dat_oe      (dat_oe),
        .dat_in      (dat_line),
        .dbg_state   ()
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // clk_en: 1-cycle pulse every 4 sys_clk
    // clk_en fires when old clk_div == 2
    // UUT reads clk_en at old_div == 3
    reg [1:0] clk_div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div <= 0;
            clk_en  <= 0;
        end else begin
            clk_div <= clk_div + 1'b1;
            clk_en  <= (clk_div == 2'd2);
        end
    end

    // Card FSM tick: fires when clk_div == 1
    // This is 2 sys_clk cycles BEFORE UUT processes (at clk_div==3)
    // so dat_in_reg is stable for both UUT read and CRC module processing
    wire card_tick = (clk_div == 2'd1);

    // Mock BRAM
    reg [7:0] bram_mem [0:511];
    always @(posedge clk)
        buf_rd_data <= bram_mem[buf_rd_addr];

    // Capture BRAM writes
    reg [7:0] read_capture [0:511];
    always @(posedge clk)
        if (buf_wr_en)
            read_capture[buf_wr_addr] <= buf_wr_data;

    integer errors = 0;
    integer i;

    initial begin
        #50_000_000;
        $display("FAIL: tb_emmc_dat - timeout");
        $finish(1);
    end

    // CRC-16 CCITT function (same as emmc_crc16 module)
    function [15:0] crc16_bit;
        input [15:0] crc_in;
        input        bit_in;
        reg          fb;
        begin
            fb = crc_in[15] ^ bit_in;
            crc16_bit[15] = crc_in[14];
            crc16_bit[14] = crc_in[13];
            crc16_bit[13] = crc_in[12];
            crc16_bit[12] = crc_in[11] ^ fb;
            crc16_bit[11] = crc_in[10];
            crc16_bit[10] = crc_in[9];
            crc16_bit[9]  = crc_in[8];
            crc16_bit[8]  = crc_in[7];
            crc16_bit[7]  = crc_in[6];
            crc16_bit[6]  = crc_in[5];
            crc16_bit[5]  = crc_in[4] ^ fb;
            crc16_bit[4]  = crc_in[3];
            crc16_bit[3]  = crc_in[2];
            crc16_bit[2]  = crc_in[1];
            crc16_bit[1]  = crc_in[0];
            crc16_bit[0]  = fb;
        end
    endfunction

    // =========================================================
    // Card DAT0 FSM — driven by card_tick (clk_div == 1)
    // Data set here is stable at clk_div==3 when UUT reads
    // and at clk_div==0 when CRC module processes
    // =========================================================
    localparam CARD_IDLE       = 4'd0;
    localparam CARD_RD_WAIT    = 4'd1;
    localparam CARD_RD_DATA    = 4'd3;
    localparam CARD_RD_CRC     = 4'd4;
    localparam CARD_RD_END     = 4'd5;
    localparam CARD_WR_WAIT    = 4'd6;
    localparam CARD_WR_DATA    = 4'd7;
    localparam CARD_WR_CRC_RX  = 4'd8;
    localparam CARD_WR_END_RX  = 4'd9;
    localparam CARD_WR_STAT    = 4'd10;
    localparam CARD_WR_BUSY    = 4'd11;
    localparam CARD_WR_RELEASE = 4'd12;
    localparam CARD_WR_NWR_GAP = 4'd13;

    reg [3:0]  card_state;
    reg [12:0] card_bit_cnt;
    reg [8:0]  card_byte_idx;
    reg [7:0]  card_byte;
    reg [2:0]  card_bit_pos;
    reg [15:0] card_crc;
    reg [15:0] card_crc_shift;
    reg [7:0]  card_pattern_base;
    reg        card_corrupt_crc;
    reg [12:0] card_wait_cnt;

    // Card control signals (set by initial block)
    reg        card_rd_go;
    reg        card_wr_go;
    reg [2:0]  card_wr_crc_status;
    reg        card_wr_busy_timeout;
    reg [3:0]  card_wr_nwr_delay;   // Nwr gap: DAT0=1 clocks between CRC status end bit and busy

    // Write reception
    reg [7:0]  wr_captured [0:511];
    reg [15:0] wr_captured_crc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            card_state     <= CARD_IDLE;
            card_bit_cnt   <= 0;
            card_byte_idx  <= 0;
            card_byte      <= 0;
            card_bit_pos   <= 0;
            card_crc       <= 0;
            card_crc_shift <= 0;
            card_wait_cnt  <= 0;
            dat_in_reg     <= 1'b1;
        end else if (card_tick) begin
            case (card_state)
                CARD_IDLE: begin
                    dat_in_reg <= 1'b1;
                    if (card_rd_go) begin
                        card_wait_cnt <= 0;
                        card_state <= CARD_RD_WAIT;
                    end
                    if (card_wr_go) begin
                        card_state <= CARD_WR_WAIT;
                    end
                end

                // =========================================================
                // Read: card → host (send data on DAT0)
                // =========================================================
                CARD_RD_WAIT: begin
                    card_wait_cnt <= card_wait_cnt + 1'b1;
                    if (card_wait_cnt == 13'd3) begin
                        dat_in_reg    <= 1'b0;  // start bit
                        card_byte_idx <= 0;
                        card_byte     <= card_pattern_base;
                        card_bit_pos  <= 3'd7;
                        card_bit_cnt  <= 0;
                        card_crc      <= 16'd0;
                        card_state    <= CARD_RD_DATA;
                    end
                end

                CARD_RD_DATA: begin
                    dat_in_reg <= card_byte[7];
                    card_crc   <= crc16_bit(card_crc, card_byte[7]);

                    if (card_bit_pos == 3'd0) begin
                        card_byte_idx <= card_byte_idx + 1'b1;
                        card_bit_pos  <= 3'd7;
                        card_byte     <= (card_byte_idx[7:0] + 1'b1 + card_pattern_base);
                        if (card_byte_idx == 9'd511) begin
                            card_crc_shift <= card_corrupt_crc ?
                                ~crc16_bit(card_crc, card_byte[7]) :
                                crc16_bit(card_crc, card_byte[7]);
                            card_bit_cnt <= 0;
                            card_state   <= CARD_RD_CRC;
                        end
                    end else begin
                        card_byte    <= {card_byte[6:0], 1'b0};
                        card_bit_pos <= card_bit_pos - 1'b1;
                    end
                end

                CARD_RD_CRC: begin
                    dat_in_reg     <= card_crc_shift[15];
                    card_crc_shift <= {card_crc_shift[14:0], 1'b0};
                    card_bit_cnt   <= card_bit_cnt + 1'b1;
                    if (card_bit_cnt == 13'd15)
                        card_state <= CARD_RD_END;
                end

                CARD_RD_END: begin
                    dat_in_reg <= 1'b1;  // end bit
                    card_state <= CARD_IDLE;
                end

                // =========================================================
                // Write: host → card (receive data, send CRC status)
                // =========================================================
                CARD_WR_WAIT: begin
                    // Wait for start bit from host (dat_line driven by UUT)
                    if (dat_line === 1'b0) begin
                        card_byte_idx <= 0;
                        card_byte     <= 0;
                        card_bit_pos  <= 3'd7;
                        card_crc      <= 16'd0;
                        card_bit_cnt  <= 0;
                        card_state    <= CARD_WR_DATA;
                    end
                end

                CARD_WR_DATA: begin
                    card_crc  <= crc16_bit(card_crc, dat_line);
                    card_byte <= {card_byte[6:0], dat_line};

                    if (card_bit_pos == 3'd0) begin
                        wr_captured[card_byte_idx] <= {card_byte[6:0], dat_line};
                        card_byte_idx <= card_byte_idx + 1'b1;
                        card_bit_pos  <= 3'd7;
                        if (card_byte_idx == 9'd511) begin
                            card_bit_cnt <= 0;
                            card_state   <= CARD_WR_CRC_RX;
                        end
                    end else begin
                        card_bit_pos <= card_bit_pos - 1'b1;
                    end
                end

                CARD_WR_CRC_RX: begin
                    wr_captured_crc <= {wr_captured_crc[14:0], dat_line};
                    card_bit_cnt    <= card_bit_cnt + 1'b1;
                    if (card_bit_cnt == 13'd15)
                        card_state <= CARD_WR_END_RX;
                end

                CARD_WR_END_RX: begin
                    // Skip end bit, start sending CRC status
                    card_bit_cnt <= 0;
                    card_state   <= CARD_WR_STAT;
                end

                CARD_WR_STAT: begin
                    // start(0) + 3-bit status + end(1) + busy
                    case (card_bit_cnt[2:0])
                        3'd0: dat_in_reg <= 1'b0;  // start bit
                        3'd1: dat_in_reg <= card_wr_crc_status[2];
                        3'd2: dat_in_reg <= card_wr_crc_status[1];
                        3'd3: dat_in_reg <= card_wr_crc_status[0];
                        3'd4: dat_in_reg <= 1'b1;  // end bit
                        default: dat_in_reg <= 1'b0; // busy start
                    endcase
                    card_bit_cnt <= card_bit_cnt + 1'b1;
                    if (card_bit_cnt == 13'd5) begin
                        if (card_wr_nwr_delay > 0) begin
                            dat_in_reg   <= 1'b1;  // override: gap (DAT0 high)
                            card_bit_cnt <= 0;
                            card_state   <= CARD_WR_NWR_GAP;
                        end else begin
                            card_state <= CARD_WR_BUSY;
                        end
                    end
                end

                CARD_WR_NWR_GAP: begin
                    dat_in_reg <= 1'b1;  // hold DAT0 high during Nwr gap
                    if (card_bit_cnt[3:0] == card_wr_nwr_delay - 4'd1) begin
                        card_state   <= CARD_WR_BUSY;
                        card_bit_cnt <= 0;
                    end else begin
                        card_bit_cnt <= card_bit_cnt + 1'b1;
                    end
                end

                CARD_WR_BUSY: begin
                    dat_in_reg <= 1'b0;  // hold busy
                    card_bit_cnt <= card_bit_cnt + 1'b1;
                    if (!card_wr_busy_timeout && card_bit_cnt >= 13'd20) begin
                        card_state <= CARD_WR_RELEASE;
                    end
                    // If busy_timeout, never release
                end

                CARD_WR_RELEASE: begin
                    dat_in_reg <= 1'b1;
                    card_state <= CARD_IDLE;
                end
            endcase
        end
    end

    // Capture done signals (since they're 1-cycle pulses)
    reg done_seen;
    reg done_is_crc_err;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_seen <= 0;
            done_is_crc_err <= 0;
        end else begin
            if (rd_done) begin
                done_seen <= 1;
                done_is_crc_err <= rd_crc_err;
            end
            if (wr_done) begin
                done_seen <= 1;
                done_is_crc_err <= wr_crc_err;
            end
        end
    end

    task clear_done;
        begin
            @(negedge clk);
            force done_seen = 0;
            force done_is_crc_err = 0;
            @(posedge clk);
            release done_seen;
            release done_is_crc_err;
            @(posedge clk);
        end
    endtask

    task wait_done;
        input integer max_cycles;
        begin : wd
            integer cnt;
            for (cnt = 0; cnt < max_cycles; cnt = cnt + 1) begin
                @(posedge clk);
                if (done_seen) disable wd;
            end
        end
    endtask

    task pulse_rd_start;
        begin
            @(negedge clk);
            rd_start = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rd_start = 1'b0;
        end
    endtask

    task pulse_wr_start;
        begin
            @(negedge clk);
            wr_start = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            wr_start = 1'b0;
        end
    endtask

    initial begin
        rst_n      = 0;
        rd_start   = 0;
        wr_start   = 0;
        card_rd_go = 0;
        card_wr_go = 0;
        card_pattern_base = 0;
        card_corrupt_crc  = 0;
        card_wr_crc_status = 3'b010;
        card_wr_busy_timeout = 0;
        card_wr_nwr_delay    = 0;

        for (i = 0; i < 512; i = i + 1)
            bram_mem[i] = (i * 3 + 8'h42) & 8'hFF;

        repeat (16) @(posedge clk);
        #1;
        rst_n = 1;
        repeat (8) @(posedge clk);

        // ============================================================
        // Test 1: Read — CRC OK
        // ============================================================
        $display("  Test 1: Read CRC OK...");
        clear_done;
        card_pattern_base = 8'h00;
        card_corrupt_crc  = 1'b0;
        @(negedge clk);
        card_rd_go = 1'b1;
        @(posedge clk);
        pulse_rd_start;
        @(negedge clk);
        card_rd_go = 1'b0;

        wait_done(2_000_000);

        if (!done_seen) begin
            $display("FAIL: T1 rd_done not set");
            errors = errors + 1;
        end
        if (done_is_crc_err) begin
            $display("FAIL: T1 unexpected rd_crc_err");
            errors = errors + 1;
        end

        repeat (4) @(posedge clk);
        // Verify data
        begin
            reg data_ok;
            data_ok = 1;
            for (i = 0; i < 512; i = i + 1) begin
                if (read_capture[i] !== (i & 8'hFF)) begin
                    if (data_ok)
                        $display("FAIL: T1 read_capture[%0d]=0x%02X, expected 0x%02X",
                                 i, read_capture[i], i & 8'hFF);
                    data_ok = 0;
                end
            end
            if (!data_ok)
                errors = errors + 1;
        end

        repeat (20) @(posedge clk);

        // ============================================================
        // Test 2: Read — CRC mismatch
        // ============================================================
        $display("  Test 2: Read CRC mismatch...");
        clear_done;
        card_pattern_base = 8'h00;
        card_corrupt_crc  = 1'b1;
        @(negedge clk);
        card_rd_go = 1'b1;
        @(posedge clk);
        pulse_rd_start;
        @(negedge clk);
        card_rd_go = 1'b0;

        wait_done(2_000_000);

        if (!done_seen) begin
            $display("FAIL: T2 rd_done not set");
            errors = errors + 1;
        end
        if (!done_is_crc_err) begin
            $display("FAIL: T2 rd_crc_err not set");
            errors = errors + 1;
        end

        repeat (20) @(posedge clk);

        // ============================================================
        // Test 3: Read — timeout (no start bit)
        // ============================================================
        $display("  Test 3: Read timeout...");
        clear_done;
        // Don't activate card — dat_in stays high
        pulse_rd_start;

        wait_done(1_500_000);

        if (!done_seen) begin
            $display("FAIL: T3 rd_done not set after timeout");
            errors = errors + 1;
        end
        if (!done_is_crc_err) begin
            $display("FAIL: T3 rd_crc_err not set (timeout)");
            errors = errors + 1;
        end

        repeat (20) @(posedge clk);

        // ============================================================
        // Test 4: Write — CRC status OK (010)
        // ============================================================
        $display("  Test 4: Write CRC OK...");
        clear_done;
        card_wr_crc_status   = 3'b010;
        card_wr_busy_timeout = 1'b0;
        @(negedge clk);
        card_wr_go = 1'b1;
        @(posedge clk);
        pulse_wr_start;
        @(negedge clk);
        card_wr_go = 1'b0;

        wait_done(2_000_000);

        if (!done_seen) begin
            $display("FAIL: T4 wr_done not set");
            errors = errors + 1;
        end
        if (done_is_crc_err) begin
            $display("FAIL: T4 unexpected wr_crc_err");
            errors = errors + 1;
        end

        // Verify card received correct data
        begin
            reg wr_data_ok;
            reg [7:0] expected;
            wr_data_ok = 1;
            for (i = 0; i < 512; i = i + 1) begin
                expected = (i * 3 + 8'h42) & 8'hFF;
                if (wr_captured[i] !== expected) begin
                    if (wr_data_ok)
                        $display("FAIL: T4 wr_captured[%0d]=0x%02X, expected 0x%02X",
                                 i, wr_captured[i], expected);
                    wr_data_ok = 0;
                end
            end
            if (!wr_data_ok)
                errors = errors + 1;
        end

        repeat (20) @(posedge clk);

        // ============================================================
        // Test 5: Write — CRC status error (101)
        // ============================================================
        $display("  Test 5: Write CRC status error...");
        clear_done;
        card_wr_crc_status   = 3'b101;
        card_wr_busy_timeout = 1'b0;
        @(negedge clk);
        card_wr_go = 1'b1;
        @(posedge clk);
        pulse_wr_start;
        @(negedge clk);
        card_wr_go = 1'b0;

        wait_done(2_000_000);

        if (!done_seen) begin
            $display("FAIL: T5 wr_done not set");
            errors = errors + 1;
        end
        if (!done_is_crc_err) begin
            $display("FAIL: T5 wr_crc_err not set");
            errors = errors + 1;
        end

        repeat (20) @(posedge clk);

        // ============================================================
        // Test 6: Write — busy timeout
        // ============================================================
        $display("  Test 6: Write busy timeout...");
        clear_done;
        card_wr_crc_status   = 3'b010;
        card_wr_busy_timeout = 1'b1;
        @(negedge clk);
        card_wr_go = 1'b1;
        @(posedge clk);
        pulse_wr_start;
        @(negedge clk);
        card_wr_go = 1'b0;

        wait_done(2_000_000);

        if (!done_seen) begin
            $display("FAIL: T6 wr_done not set after busy timeout");
            errors = errors + 1;
        end
        if (!done_is_crc_err) begin
            $display("FAIL: T6 wr_crc_err not set after busy timeout");
            errors = errors + 1;
        end

        repeat (20) @(posedge clk);

        // ============================================================
        // Test 7: Back-to-back — read then write
        // Reset first: Test 6 leaves card FSM stuck in CARD_WR_BUSY
        // ============================================================
        $display("  Test 7: Back-to-back read then write...");
        rst_n = 0;
        card_wr_busy_timeout = 0;
        repeat (4) @(posedge clk);
        #1;
        rst_n = 1;
        repeat (8) @(posedge clk);

        // Read
        clear_done;
        card_pattern_base = 8'hAA;
        card_corrupt_crc  = 1'b0;
        @(negedge clk);
        card_rd_go = 1'b1;
        @(posedge clk);
        pulse_rd_start;
        @(negedge clk);
        card_rd_go = 1'b0;

        wait_done(2_000_000);
        if (!done_seen || done_is_crc_err) begin
            $display("FAIL: T7 read phase failed");
            errors = errors + 1;
        end

        repeat (20) @(posedge clk);

        // Write
        clear_done;
        card_wr_crc_status   = 3'b010;
        card_wr_busy_timeout = 1'b0;
        @(negedge clk);
        card_wr_go = 1'b1;
        @(posedge clk);
        pulse_wr_start;
        @(negedge clk);
        card_wr_go = 1'b0;

        wait_done(2_000_000);
        if (!done_seen || done_is_crc_err) begin
            $display("FAIL: T7 write phase failed");
            errors = errors + 1;
        end

        // ============================================================
        // Test 8: Write — Nwr gap (DAT0=1 between CRC status and busy)
        // Without busy guard fix, UUT sees dat_in=1 immediately and
        // reports false wr_done. With fix, first 3 clk_en are skipped.
        // ============================================================
        $display("  Test 8: Write Nwr gap regression...");
        clear_done;
        card_wr_crc_status   = 3'b010;
        card_wr_busy_timeout = 1'b0;
        card_wr_nwr_delay    = 4'd2;  // 2 CLK gap before busy
        @(negedge clk);
        card_wr_go = 1'b1;
        @(posedge clk);
        pulse_wr_start;
        @(negedge clk);
        card_wr_go = 1'b0;

        wait_done(2_000_000);

        if (!done_seen) begin
            $display("FAIL: T8 wr_done not set");
            errors = errors + 1;
        end
        if (done_is_crc_err) begin
            $display("FAIL: T8 unexpected wr_crc_err (Nwr gap should be tolerated)");
            errors = errors + 1;
        end

        repeat (20) @(posedge clk);

        // ============================================================
        // Test 9: Write — CRC status timeout (card never responds)
        // Card FSM stays idle, dat_in=1 forever.
        // Without timeout fix, UUT hangs in S_WR_CRC_STAT.
        // ============================================================
        $display("  Test 9: Write CRC status timeout...");
        clear_done;
        card_wr_nwr_delay = 4'd0;
        // Don't activate card — dat_in stays high, no CRC status
        pulse_wr_start;

        wait_done(1_500_000);

        if (!done_seen) begin
            $display("FAIL: T9 wr_done not set after CRC status timeout");
            errors = errors + 1;
        end
        if (!done_is_crc_err) begin
            $display("FAIL: T9 wr_crc_err not set (timeout)");
            errors = errors + 1;
        end

        repeat (20) @(posedge clk);

        // ============================================================
        // Results
        // ============================================================
        repeat (20) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_emmc_dat");
        else
            $display("[FAIL] tb_emmc_dat (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
