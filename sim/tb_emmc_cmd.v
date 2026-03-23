// Testbench: eMMC CMD line protocol handler
// Tests CMD send with CRC-7, response reception (R1/R2), timeout detection
// Uses a stub eMMC card model that responds on the CMD line

`timescale 1ns / 1ps

module tb_emmc_cmd;

    reg        clk;
    reg        rst_n;
    reg        clk_en;

    reg        cmd_start;
    reg  [5:0] cmd_index;
    reg [31:0] cmd_argument;
    reg        resp_type_long;
    reg        resp_expected;
    wire       cmd_done;
    wire       cmd_timeout;
    wire       cmd_crc_err;
    wire [31:0] resp_status;
    wire [127:0] resp_data;

    wire       cmd_out;
    wire       cmd_oe;

    // Bidirectional CMD line
    wire cmd_line;
    reg  cmd_card_out;
    reg  cmd_card_oe;

    // When host drives, cmd_line = cmd_out; when card drives, cmd_line = cmd_card_out
    assign cmd_line = cmd_oe ? cmd_out : (cmd_card_oe ? cmd_card_out : 1'b1);

    emmc_cmd uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .clk_en         (clk_en),
        .cmd_start      (cmd_start),
        .cmd_index      (cmd_index),
        .cmd_argument   (cmd_argument),
        .resp_type_long (resp_type_long),
        .resp_expected  (resp_expected),
        .cmd_done       (cmd_done),
        .cmd_timeout    (cmd_timeout),
        .cmd_crc_err    (cmd_crc_err),
        .resp_status    (resp_status),
        .resp_data      (resp_data),
        .cmd_out        (cmd_out),
        .cmd_oe         (cmd_oe),
        .cmd_in         (cmd_line),
        .dbg_state      ()
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    // Generate clk_en: one pulse every 4 sys_clk cycles (simulating fast eMMC clock)
    reg [1:0] clk_div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div <= 0;
            clk_en  <= 0;
        end else begin
            clk_en  <= (clk_div == 2'd3);
            clk_div <= clk_div + 1'b1;
        end
    end

    // =========================================================
    // Stub eMMC Card: monitors CMD line, sends responses
    // =========================================================

    // CRC-7 for card response
    function [6:0] calc_crc7;
        input [39:0] data; // 40 bits to CRC
        integer i;
        reg [6:0] crc;
        reg       fb;
        begin
            crc = 7'd0;
            for (i = 39; i >= 0; i = i - 1) begin
                fb = crc[6] ^ data[i];
                crc[6] = crc[5];
                crc[5] = crc[4];
                crc[4] = crc[3];
                crc[3] = crc[2] ^ fb;
                crc[2] = crc[1];
                crc[1] = crc[0];
                crc[0] = fb;
            end
            calc_crc7 = crc;
        end
    endfunction

    // Card captures 48-bit command by monitoring cmd_line
    reg [47:0]  card_rx_shift;
    reg [7:0]   card_rx_cnt;
    reg         card_rx_active;
    reg         card_rx_done;       // pulse: full command captured
    reg [135:0] card_tx_shift;
    reg [7:0]   card_tx_cnt;
    reg [7:0]   card_tx_len;
    reg         card_tx_active;
    reg         card_tx_pending;    // response generation requested TX

    // Card state machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            card_rx_shift  <= 0;
            card_rx_cnt    <= 0;
            card_rx_active <= 0;
            card_rx_done   <= 0;
            card_tx_shift  <= 0;
            card_tx_cnt    <= 0;
            card_tx_len    <= 0;
            card_tx_active <= 0;
            card_tx_pending <= 0;
            cmd_card_out   <= 1'b1;
            cmd_card_oe    <= 1'b0;
        end else if (clk_en) begin
            cmd_card_oe  <= 1'b0;
            cmd_card_out <= 1'b1;
            card_rx_done <= 1'b0;

            if (card_tx_active) begin
                // Sending response
                cmd_card_oe  <= 1'b1;
                cmd_card_out <= card_tx_shift[135];
                card_tx_shift <= {card_tx_shift[134:0], 1'b1};
                card_tx_cnt   <= card_tx_cnt + 1'b1;
                if (card_tx_cnt == card_tx_len - 1)
                    card_tx_active <= 1'b0;
            end else if (card_tx_pending) begin
                // Start sending response (1 cycle delay after pending set)
                card_tx_active  <= 1'b1;
                card_tx_pending <= 1'b0;
            end else if (card_rx_active) begin
                // Receiving command from host
                card_rx_shift <= {card_rx_shift[46:0], cmd_line};
                card_rx_cnt   <= card_rx_cnt + 1'b1;
                if (card_rx_cnt == 8'd47) begin
                    card_rx_active <= 1'b0;
                    card_rx_done   <= 1'b1;
                end
            end else begin
                // Look for start of command (CMD line goes low while host is driving)
                if (cmd_oe && cmd_line == 1'b0) begin
                    card_rx_active <= 1'b1;
                    card_rx_shift  <= {47'd0, 1'b0};
                    card_rx_cnt    <= 8'd1;
                end
            end
        end
    end

    // Card response generation — triggers on card_rx_done
    // By this time, card_rx_shift has the full 48-bit command
    always @(posedge clk) begin
        if (card_rx_done) begin
            case (card_rx_shift[45:40])
                6'd0: begin
                    // CMD0: no response
                end

                6'd1: begin
                    // CMD1: R3 response (OCR) — no CRC check
                    card_tx_shift <= {1'b0, 1'b0, 6'b111111, 32'hC0FF8000, 7'b1111111, 1'b1, 88'd0};
                    card_tx_len   <= 8'd48;
                    card_tx_pending <= 1'b1;
                    card_tx_cnt   <= 0;
                end

                6'd2: begin
                    // CMD2: R2 response (136 bits) — CID
                    card_tx_shift <= {1'b0, 1'b0, 6'b111111, 128'hDEADBEEF_CAFEBABE_12345678_AABBCCDD};
                    card_tx_len   <= 8'd136;
                    card_tx_pending <= 1'b1;
                    card_tx_cnt   <= 0;
                end

                6'd3: begin
                    // CMD3: R1 response
                    begin
                        reg [6:0] c7;
                        c7 = calc_crc7({1'b0, 1'b0, 6'd3, 32'h0000_0500});
                        card_tx_shift <= {1'b0, 1'b0, 6'd3, 32'h0000_0500, c7, 1'b1, 88'd0};
                    end
                    card_tx_len   <= 8'd48;
                    card_tx_pending <= 1'b1;
                    card_tx_cnt   <= 0;
                end

                default: begin
                    // Generic R1 response: card status = 0x00000900
                    begin
                        reg [6:0] c7;
                        c7 = calc_crc7({1'b0, 1'b0, card_rx_shift[45:40], 32'h0000_0900});
                        card_tx_shift <= {1'b0, 1'b0, card_rx_shift[45:40], 32'h0000_0900, c7, 1'b1, 88'd0};
                    end
                    card_tx_len   <= 8'd48;
                    card_tx_pending <= 1'b1;
                    card_tx_cnt   <= 0;
                end
            endcase
        end
    end

    // =========================================================
    // Test procedure
    // =========================================================

    // Wait for cmd_done or cmd_timeout
    task wait_cmd_complete(input integer max_cycles);
        integer cnt;
        begin
            for (cnt = 0; cnt < max_cycles; cnt = cnt + 1) begin
                @(posedge clk);
                if (cmd_done || cmd_timeout)
                    disable wait_cmd_complete;
            end
        end
    endtask

    // Watchdog
    initial begin
        #10_000_000;
        $display("FAIL: tb_emmc_cmd - timeout");
        $finish(1);
    end

    initial begin
        rst_n          = 0;
        cmd_start      = 0;
        cmd_index      = 0;
        cmd_argument   = 0;
        resp_type_long = 0;
        resp_expected  = 0;

        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (8) @(posedge clk);

        // ---- Test 1: CMD0 (no response) ----
        @(posedge clk);
        cmd_index     <= 6'd0;
        cmd_argument  <= 32'h0000_0000;
        resp_expected <= 1'b0;
        resp_type_long<= 1'b0;
        cmd_start     <= 1'b1;
        @(posedge clk);
        cmd_start <= 1'b0;

        wait_cmd_complete(2000);
        if (!cmd_done) begin
            $display("FAIL: CMD0 did not complete");
            errors = errors + 1;
        end
        if (cmd_timeout) begin
            $display("FAIL: CMD0 unexpected timeout");
            errors = errors + 1;
        end

        repeat (40) @(posedge clk);

        // ---- Test 2: CMD1 (R3 response, no CRC check) ----
        @(posedge clk);
        cmd_index     <= 6'd1;
        cmd_argument  <= 32'h40FF8000;
        resp_expected <= 1'b1;
        resp_type_long<= 1'b0;
        cmd_start     <= 1'b1;
        @(posedge clk);
        cmd_start <= 1'b0;

        wait_cmd_complete(4000);
        if (!cmd_done) begin
            $display("FAIL: CMD1 did not complete");
            errors = errors + 1;
        end
        // R3 response: resp_status should contain OCR (card_status bits)
        // OCR bit 31 should be set (card ready)
        if (!resp_status[31]) begin
            $display("FAIL: CMD1 resp_status[31] not set: 0x%08X", resp_status);
            errors = errors + 1;
        end

        repeat (40) @(posedge clk);

        // ---- Test 3: CMD2 (R2 response, 136-bit) ----
        @(posedge clk);
        cmd_index     <= 6'd2;
        cmd_argument  <= 32'h0;
        resp_expected <= 1'b1;
        resp_type_long<= 1'b1;
        cmd_start     <= 1'b1;
        @(posedge clk);
        cmd_start <= 1'b0;

        wait_cmd_complete(4000);
        if (!cmd_done) begin
            $display("FAIL: CMD2 did not complete");
            errors = errors + 1;
        end
        if (resp_data !== 128'hDEADBEEF_CAFEBABE_12345678_AABBCCDD) begin
            $display("FAIL: CMD2 resp_data: 0x%032X", resp_data);
            $display("      expected:       0xDEADBEEFCAFEBABE12345678AABBCCDD");
            errors = errors + 1;
        end

        repeat (40) @(posedge clk);

        // ---- Test 4: CMD3 (R1 response with CRC check) ----
        @(posedge clk);
        cmd_index     <= 6'd3;
        cmd_argument  <= 32'h0001_0000;
        resp_expected <= 1'b1;
        resp_type_long<= 1'b0;
        cmd_start     <= 1'b1;
        @(posedge clk);
        cmd_start <= 1'b0;

        wait_cmd_complete(4000);
        if (!cmd_done) begin
            $display("FAIL: CMD3 did not complete");
            errors = errors + 1;
        end
        if (cmd_crc_err) begin
            $display("FAIL: CMD3 unexpected CRC error");
            errors = errors + 1;
        end
        if (resp_status !== 32'h0000_0500) begin
            $display("FAIL: CMD3 resp_status: 0x%08X, expected 0x00000500", resp_status);
            errors = errors + 1;
        end

        repeat (40) @(posedge clk);

        // ---- Test 5: Timeout (suppress card response) ----
        force card_tx_pending = 0;
        force card_tx_active = 0;
        @(posedge clk);
        cmd_index     <= 6'd15;
        cmd_argument  <= 32'h0;
        resp_expected <= 1'b1;
        resp_type_long<= 1'b0;
        cmd_start     <= 1'b1;
        @(posedge clk);
        cmd_start <= 1'b0;

        wait_cmd_complete(200000);
        release card_tx_pending;
        release card_tx_active;

        if (!cmd_timeout) begin
            $display("FAIL: timeout not detected");
            errors = errors + 1;
        end

        // ---- Results ----
        repeat (10) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_emmc_cmd");
        else
            $display("[FAIL] tb_emmc_cmd (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
