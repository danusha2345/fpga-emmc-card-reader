// Testbench: UART Bridge — protocol command handler
// Tests PING, GET_INFO, unknown command, CRC error, RX timeout
// Stubs eMMC controller signals

`timescale 1ns / 1ps

module tb_uart_bridge;

    localparam CLK_FREQ  = 60_000_000;
    localparam BAUD_RATE = 3_000_000;
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // 20

    reg        clk;
    reg        rst_n;

    // UART pins
    reg        uart_rx_pin;
    wire       uart_tx_pin;

    // eMMC controller stub signals
    reg        emmc_cmd_ready;
    reg  [7:0] emmc_resp_status;
    reg        emmc_resp_valid;
    reg  [7:0] emmc_rd_data;
    reg        emmc_rd_sector_ready;
    reg  [7:0] emmc_wr_data_out;   // unused, just wire
    reg        emmc_wr_en_out;
    reg [127:0] emmc_cid;
    reg [127:0] emmc_csd;
    reg         emmc_info_valid;
    reg [31:0]  emmc_card_status;
    reg [127:0] emmc_raw_resp;

    // Debug stub signals
    reg  [3:0]  emmc_dbg_init_state;
    reg  [4:0]  emmc_dbg_mc_state;
    reg         emmc_dbg_cmd_pin;
    reg         emmc_dbg_dat0_pin;
    reg  [2:0]  emmc_dbg_cmd_fsm;
    reg  [3:0]  emmc_dbg_dat_fsm;
    reg  [1:0]  emmc_dbg_partition;
    reg         emmc_dbg_use_fast_clk;
    reg         emmc_dbg_reinit_pending;
    reg  [7:0]  emmc_dbg_err_cmd_timeout;
    reg  [7:0]  emmc_dbg_err_cmd_crc;
    reg  [7:0]  emmc_dbg_err_dat_rd;
    reg  [7:0]  emmc_dbg_err_dat_wr;
    reg  [7:0]  emmc_dbg_init_retry_cnt;
    reg  [2:0]  emmc_dbg_clk_preset;

    wire       emmc_cmd_valid;
    wire [7:0] emmc_cmd_id;
    wire [31:0] emmc_cmd_lba;
    wire [15:0] emmc_cmd_count;
    wire [8:0]  emmc_rd_addr;
    wire [7:0]  emmc_wr_data;
    wire [8:0]  emmc_wr_addr;
    wire        emmc_wr_en;
    wire        emmc_wr_sector_valid;
    reg         emmc_wr_sector_ack;
    wire [3:0]  emmc_wr_bank;
    wire        emmc_rd_sector_ack;
    wire        uart_activity;
    wire        protocol_error;

    uart_bridge #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) uut (
        .clk               (clk),
        .rst_n             (rst_n),
        .uart_rx_pin       (uart_rx_pin),
        .uart_tx_pin       (uart_tx_pin),
        .emmc_cmd_valid    (emmc_cmd_valid),
        .emmc_cmd_id       (emmc_cmd_id),
        .emmc_cmd_lba      (emmc_cmd_lba),
        .emmc_cmd_count    (emmc_cmd_count),
        .emmc_cmd_ready    (emmc_cmd_ready),
        .emmc_resp_status  (emmc_resp_status),
        .emmc_resp_valid   (emmc_resp_valid),
        .emmc_rd_data      (emmc_rd_data),
        .emmc_rd_addr      (emmc_rd_addr),
        .emmc_rd_sector_ready (emmc_rd_sector_ready),
        .emmc_rd_sector_ack (emmc_rd_sector_ack),
        .emmc_wr_data      (emmc_wr_data),
        .emmc_wr_addr      (emmc_wr_addr),
        .emmc_wr_en        (emmc_wr_en),
        .emmc_wr_sector_valid (emmc_wr_sector_valid),
        .emmc_wr_sector_ack (emmc_wr_sector_ack),
        .emmc_wr_bank       (emmc_wr_bank),
        .emmc_cid          (emmc_cid),
        .emmc_csd          (emmc_csd),
        .emmc_info_valid   (emmc_info_valid),
        .emmc_card_status  (emmc_card_status),
        .emmc_raw_resp     (emmc_raw_resp),
        .emmc_dbg_init_state     (emmc_dbg_init_state),
        .emmc_dbg_mc_state       (emmc_dbg_mc_state),
        .emmc_dbg_cmd_pin        (emmc_dbg_cmd_pin),
        .emmc_dbg_dat0_pin       (emmc_dbg_dat0_pin),
        .emmc_dbg_cmd_fsm        (emmc_dbg_cmd_fsm),
        .emmc_dbg_dat_fsm        (emmc_dbg_dat_fsm),
        .emmc_dbg_partition      (emmc_dbg_partition),
        .emmc_dbg_use_fast_clk   (emmc_dbg_use_fast_clk),
        .emmc_dbg_reinit_pending (emmc_dbg_reinit_pending),
        .emmc_dbg_err_cmd_timeout(emmc_dbg_err_cmd_timeout),
        .emmc_dbg_err_cmd_crc    (emmc_dbg_err_cmd_crc),
        .emmc_dbg_err_dat_rd     (emmc_dbg_err_dat_rd),
        .emmc_dbg_err_dat_wr     (emmc_dbg_err_dat_wr),
        .emmc_dbg_init_retry_cnt (emmc_dbg_init_retry_cnt),
        .emmc_dbg_clk_preset     (emmc_dbg_clk_preset),
        .uart_activity     (uart_activity),
        .protocol_error    (protocol_error)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    // =========================================================
    // UART TX helper: send one byte as UART frame on uart_rx_pin
    // =========================================================
    task uart_send_byte(input [7:0] b);
        integer i;
        begin
            // Start bit
            uart_rx_pin <= 1'b0;
            repeat (CLKS_PER_BIT) @(posedge clk);
            // 8 data bits, LSB first
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_pin <= b[i];
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            // Stop bit
            uart_rx_pin <= 1'b1;
            repeat (CLKS_PER_BIT) @(posedge clk);
            // Inter-byte gap
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    // =========================================================
    // UART RX helper: capture one byte from uart_tx_pin
    // =========================================================
    reg [7:0] rx_captured;
    reg       rx_got_byte;

    task uart_recv_byte;
        integer i;
        begin
            rx_got_byte = 0;
            // Wait for start bit (tx_pin goes low)
            begin : wait_start
                integer cnt;
                for (cnt = 0; cnt < CLKS_PER_BIT * 300; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (uart_tx_pin == 1'b0) begin
                        disable wait_start;
                    end
                end
                // Timeout
                rx_got_byte = 0;
            end
            if (uart_tx_pin !== 1'b0) begin
                rx_got_byte = 0;
            end else begin
                // Go to middle of start bit
                repeat (CLKS_PER_BIT / 2) @(posedge clk);
                // Sample 8 data bits
                for (i = 0; i < 8; i = i + 1) begin
                    repeat (CLKS_PER_BIT) @(posedge clk);
                    rx_captured[i] = uart_tx_pin;
                end
                // Stop bit
                repeat (CLKS_PER_BIT) @(posedge clk);
                rx_got_byte = 1;
            end
        end
    endtask

    // =========================================================
    // UART TX/RX helpers with explicit timing (for baud switch tests)
    // =========================================================
    task uart_send_byte_timed(input [7:0] b, input integer cpb);
        integer i;
        begin
            // Start bit
            uart_rx_pin <= 1'b0;
            repeat (cpb) @(posedge clk);
            // 8 data bits, LSB first
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx_pin <= b[i];
                repeat (cpb) @(posedge clk);
            end
            // Stop bit
            uart_rx_pin <= 1'b1;
            repeat (cpb) @(posedge clk);
            // Inter-byte gap
            repeat (cpb) @(posedge clk);
        end
    endtask

    task uart_recv_byte_timed(input integer cpb);
        integer i;
        begin
            rx_got_byte = 0;
            // Wait for start bit (tx_pin goes low)
            begin : wait_start_timed
                integer cnt;
                for (cnt = 0; cnt < cpb * 300; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (uart_tx_pin == 1'b0) begin
                        disable wait_start_timed;
                    end
                end
                // Timeout
                rx_got_byte = 0;
            end
            if (uart_tx_pin !== 1'b0) begin
                rx_got_byte = 0;
            end else begin
                // Go to middle of start bit
                repeat (cpb / 2) @(posedge clk);
                // Sample 8 data bits
                for (i = 0; i < 8; i = i + 1) begin
                    repeat (cpb) @(posedge clk);
                    rx_captured[i] = uart_tx_pin;
                end
                // Stop bit
                repeat (cpb) @(posedge clk);
                rx_got_byte = 1;
            end
        end
    endtask

    task send_packet_timed(input [7:0] cmd, input [15:0] plen,
                           input [7:0] p0, input [7:0] crc,
                           input integer cpb);
        begin
            uart_send_byte_timed(8'hAA, cpb);
            uart_send_byte_timed(cmd, cpb);
            uart_send_byte_timed(plen[15:8], cpb);
            uart_send_byte_timed(plen[7:0], cpb);
            if (plen > 0)
                uart_send_byte_timed(p0, cpb);
            uart_send_byte_timed(crc, cpb);
        end
    endtask

    task recv_packet_timed(input integer cpb);
        integer j;
        begin
            uart_recv_byte_timed(cpb); resp_header = rx_captured;
            uart_recv_byte_timed(cpb); resp_cmd = rx_captured;
            uart_recv_byte_timed(cpb); resp_status_byte = rx_captured;
            uart_recv_byte_timed(cpb); resp_len[15:8] = rx_captured;
            uart_recv_byte_timed(cpb); resp_len[7:0] = rx_captured;
            for (j = 0; j < resp_len && j < 512; j = j + 1) begin
                uart_recv_byte_timed(cpb);
                resp_payload[j] = rx_captured;
            end
            uart_recv_byte_timed(cpb); resp_crc = rx_captured;
            resp_payload_cnt = resp_len;
        end
    endtask

    // Send a full UART protocol packet: [0xAA, cmd, len_h, len_l, payload..., crc8]
    task send_packet(input [7:0] cmd, input [15:0] plen,
                     input [7:0] p0, input [7:0] p1, input [7:0] p2, input [7:0] p3,
                     input [7:0] p4, input [7:0] p5, input [7:0] crc);
        integer j;
        begin
            uart_send_byte(8'hAA);
            uart_send_byte(cmd);
            uart_send_byte(plen[15:8]);
            uart_send_byte(plen[7:0]);
            for (j = 0; j < plen; j = j + 1) begin
                case (j)
                    0: uart_send_byte(p0);
                    1: uart_send_byte(p1);
                    2: uart_send_byte(p2);
                    3: uart_send_byte(p3);
                    4: uart_send_byte(p4);
                    5: uart_send_byte(p5);
                endcase
            end
            uart_send_byte(crc);
        end
    endtask

    // Large payload memory for auto-CRC send (WRITE_SECTOR etc.)
    reg [7:0] tx_large_payload [0:8197];  // 6 + 16*512 = 8198 max

    task send_packet_auto(input [7:0] cmd, input [15:0] plen);
        integer j;
        reg [7:0] crc;
        begin
            crc = 8'd0;
            uart_send_byte(8'hAA);
            uart_send_byte(cmd);
            crc = calc_crc8(crc, cmd);
            uart_send_byte(plen[15:8]);
            crc = calc_crc8(crc, plen[15:8]);
            uart_send_byte(plen[7:0]);
            crc = calc_crc8(crc, plen[7:0]);
            for (j = 0; j < plen; j = j + 1) begin
                uart_send_byte(tx_large_payload[j]);
                crc = calc_crc8(crc, tx_large_payload[j]);
            end
            uart_send_byte(crc);
        end
    endtask

    // Receive a full response packet: [0x55, cmd, status, len_h, len_l, payload..., crc8]
    reg [7:0] resp_header;
    reg [7:0] resp_cmd;
    reg [7:0] resp_status_byte;
    reg [15:0] resp_len;
    reg [7:0] resp_payload [0:511];
    reg [7:0] resp_crc;
    integer    resp_payload_cnt;

    task recv_packet;
        integer j;
        begin
            uart_recv_byte; resp_header = rx_captured;
            uart_recv_byte; resp_cmd = rx_captured;
            uart_recv_byte; resp_status_byte = rx_captured;
            uart_recv_byte; resp_len[15:8] = rx_captured;
            uart_recv_byte; resp_len[7:0] = rx_captured;
            for (j = 0; j < resp_len && j < 512; j = j + 1) begin
                uart_recv_byte;
                resp_payload[j] = rx_captured;
            end
            uart_recv_byte; resp_crc = rx_captured;
            resp_payload_cnt = resp_len;
        end
    endtask

    // Watchdog
    initial begin
        #1_200_000_000;  // 1.2s (WRITE/READ_SECTOR 512 bytes + RX timeout + count=0 + card_status + reinit + secure_erase + multi-write 2 sectors + multi-sector read + baud switch)
        $display("FAIL: tb_uart_bridge - timeout");
        $finish(1);
    end

    // CRC-8 calculation (matches Verilog implementation)
    function [7:0] calc_crc8;
        input [7:0] crc_in;
        input [7:0] data;
        reg [7:0] c, d, n;
        begin
            c = crc_in;
            d = data;
            n[0] = c[0] ^ c[6] ^ c[7] ^ d[0] ^ d[6] ^ d[7];
            n[1] = c[0] ^ c[1] ^ c[6] ^ d[0] ^ d[1] ^ d[6];
            n[2] = c[0] ^ c[1] ^ c[2] ^ c[6] ^ d[0] ^ d[1] ^ d[2] ^ d[6];
            n[3] = c[1] ^ c[2] ^ c[3] ^ c[7] ^ d[1] ^ d[2] ^ d[3] ^ d[7];
            n[4] = c[2] ^ c[3] ^ c[4] ^ d[2] ^ d[3] ^ d[4];
            n[5] = c[3] ^ c[4] ^ c[5] ^ d[3] ^ d[4] ^ d[5];
            n[6] = c[4] ^ c[5] ^ c[6] ^ d[4] ^ d[5] ^ d[6];
            n[7] = c[5] ^ c[6] ^ c[7] ^ d[5] ^ d[6] ^ d[7];
            calc_crc8 = n;
        end
    endfunction

    // Verify CRC of response packet
    function [7:0] compute_resp_crc;
        input [7:0] cmd;
        input [7:0] status;
        input [15:0] len;
        integer k;
        reg [7:0] crc;
        begin
            crc = 8'd0;
            crc = calc_crc8(crc, cmd);
            crc = calc_crc8(crc, status);
            crc = calc_crc8(crc, len[15:8]);
            crc = calc_crc8(crc, len[7:0]);
            for (k = 0; k < len && k < 512; k = k + 1)
                crc = calc_crc8(crc, resp_payload[k]);
            compute_resp_crc = crc;
        end
    endfunction

    initial begin
        rst_n              = 0;
        uart_rx_pin        = 1'b1;
        emmc_cmd_ready     = 1'b1;
        emmc_resp_status   = 8'h00;
        emmc_resp_valid    = 1'b0;
        emmc_rd_data       = 8'h00;
        emmc_rd_sector_ready = 1'b0;
        emmc_wr_sector_ack = 1'b0;
        emmc_cid           = 128'h11223344_55667788_99AABBCC_DDEEFF00;
        emmc_csd           = 128'hAABBCCDD_EEFF0011_22334455_66778899;
        emmc_info_valid    = 1'b1;
        emmc_card_status   = 32'h00000000;
        emmc_raw_resp      = 128'h0;

        // Debug stubs: known values for GET_STATUS test
        emmc_dbg_init_state      = 4'd12;   // SI_DONE
        emmc_dbg_mc_state        = 5'd2;    // MC_READY
        emmc_dbg_cmd_pin         = 1'b1;    // idle high
        emmc_dbg_dat0_pin        = 1'b1;    // idle high
        emmc_dbg_cmd_fsm         = 3'd0;    // S_IDLE
        emmc_dbg_dat_fsm         = 4'd0;    // S_IDLE
        emmc_dbg_partition       = 2'd0;    // user
        emmc_dbg_use_fast_clk    = 1'b1;    // fast mode
        emmc_dbg_reinit_pending  = 1'b0;
        emmc_dbg_err_cmd_timeout = 8'd3;    // 3 cmd timeouts
        emmc_dbg_err_cmd_crc     = 8'd1;    // 1 crc error
        emmc_dbg_err_dat_rd      = 8'd0;
        emmc_dbg_err_dat_wr      = 8'd2;    // 2 write errors
        emmc_dbg_init_retry_cnt  = 8'd5;    // 5 CMD1 retries
        emmc_dbg_clk_preset      = 3'd0;    // default 2 MHz

        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (8) @(posedge clk);

        // ============================================================
        // Test 1: PING
        // TX: [AA, 01, 00, 00, CRC=6B]
        // Expected RX: [55, 01, 00, 00, 00, CRC]
        // ============================================================
        $display("  Test 1: PING...");
        fork
            send_packet(8'h01, 16'd0, 0,0,0,0,0,0, 8'h6B);
            recv_packet;
        join

        if (resp_header !== 8'h55) begin
            $display("FAIL: PING header: 0x%02X", resp_header);
            errors = errors + 1;
        end
        if (resp_cmd !== 8'h01) begin
            $display("FAIL: PING cmd: 0x%02X", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: PING status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        if (resp_len !== 16'd0) begin
            $display("FAIL: PING len: %0d", resp_len);
            errors = errors + 1;
        end
        begin
            reg [7:0] expected_crc;
            expected_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== expected_crc) begin
                $display("FAIL: PING CRC: 0x%02X, expected 0x%02X", resp_crc, expected_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 2: GET_INFO (CID + CSD = 32 bytes)
        // TX: [AA, 02, 00, 00, CRC=D6]
        // Expected: [55, 02, 00, 00, 20, <32 bytes CID+CSD>, CRC]
        // ============================================================
        $display("  Test 2: GET_INFO...");
        fork
            send_packet(8'h02, 16'd0, 0,0,0,0,0,0, 8'hD6);
            recv_packet;
        join

        if (resp_cmd !== 8'h02) begin
            $display("FAIL: GET_INFO cmd: 0x%02X", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: GET_INFO status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        if (resp_len !== 16'd32) begin
            $display("FAIL: GET_INFO len: %0d", resp_len);
            errors = errors + 1;
        end else begin
            // Check first byte of CID (MSB of info_shift = MSB of CID)
            // info_shift = {emmc_cid, emmc_csd}, shifted out MSB first
            // emmc_cid[127:120] = 0x11
            if (resp_payload[0] !== 8'h11) begin
                $display("FAIL: GET_INFO CID[0]: 0x%02X, expected 0x11", resp_payload[0]);
                errors = errors + 1;
            end
            // Last byte = emmc_csd[7:0] = 0x99
            if (resp_payload[31] !== 8'h99) begin
                $display("FAIL: GET_INFO CSD[15]: 0x%02X, expected 0x99", resp_payload[31]);
                errors = errors + 1;
            end
        end
        begin
            reg [7:0] expected_crc2;
            expected_crc2 = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== expected_crc2) begin
                $display("FAIL: GET_INFO CRC: 0x%02X, expected 0x%02X", resp_crc, expected_crc2);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 3: Unknown command (0xFF)
        // TX: [AA, FF, 00, 00, CRC=2B]
        // Expected: [55, FF, 02, 00, 00, CRC]  (STATUS_ERR_CMD=0x02)
        // ============================================================
        $display("  Test 3: Unknown command...");
        fork
            send_packet(8'hFF, 16'd0, 0,0,0,0,0,0, 8'h2B);
            recv_packet;
        join

        if (resp_cmd !== 8'hFF) begin
            $display("FAIL: unknown cmd: 0x%02X", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h02) begin
            $display("FAIL: unknown status: 0x%02X, expected 0x02", resp_status_byte);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 4: CRC error (send PING with bad CRC)
        // TX: [AA, 01, 00, 00, BAD_CRC=0xFF]
        // Expected: [55, 01, 01, 00, 00, CRC]  (STATUS_ERR_CRC=0x01)
        // ============================================================
        $display("  Test 4: CRC error...");
        fork
            send_packet(8'h01, 16'd0, 0,0,0,0,0,0, 8'hFF); // bad CRC
            recv_packet;
        join

        if (resp_status_byte !== 8'h01) begin
            $display("FAIL: CRC error status: 0x%02X, expected 0x01", resp_status_byte);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 5: READ_SECTOR command (full 512-byte round-trip)
        // TX: [AA, 03, 00, 06, LBA(4), COUNT(2), CRC]
        // Expected: [55, 03, 00, 02, 00, 512 bytes, CRC]
        // ============================================================
        $display("  Test 5: READ_SECTOR...");
        begin
            reg [7:0] send_crc;
            send_crc = 8'd0;
            send_crc = calc_crc8(send_crc, 8'h03);
            send_crc = calc_crc8(send_crc, 8'h00);
            send_crc = calc_crc8(send_crc, 8'h06);
            send_crc = calc_crc8(send_crc, 8'h00); // LBA[31:24]
            send_crc = calc_crc8(send_crc, 8'h00); // LBA[23:16]
            send_crc = calc_crc8(send_crc, 8'h00); // LBA[15:8]
            send_crc = calc_crc8(send_crc, 8'h00); // LBA[7:0]
            send_crc = calc_crc8(send_crc, 8'h00); // COUNT[15:8]
            send_crc = calc_crc8(send_crc, 8'h01); // COUNT[7:0]

            fork
                // Thread 1: Send UART command packet
                send_packet(8'h03, 16'd6, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, send_crc);

                // Thread 2: Mock eMMC — wait for cmd_valid, then assert rd_sector_ready (sticky)
                begin
                    begin : wait_cmd_valid
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_cmd_valid;
                        end
                    end
                    // Brief delay before sector ready (sticky)
                    repeat (50) @(posedge clk);
                    emmc_rd_sector_ready <= 1'b1;
                    // Wait for ack from uart_bridge
                    begin : wait_rd_ack
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 600; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_rd_sector_ack) disable wait_rd_ack;
                        end
                    end
                    emmc_rd_sector_ready <= 1'b0;
                end

                // Thread 3: Receive UART response packet (header + 512 payload + crc)
                recv_packet;
            join
        end

        // Check response
        if (resp_header !== 8'h55) begin
            $display("FAIL: READ_SECTOR header: 0x%02X", resp_header);
            errors = errors + 1;
        end
        if (resp_cmd !== 8'h03) begin
            $display("FAIL: READ_SECTOR resp cmd: 0x%02X", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: READ_SECTOR status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        if (resp_len !== 16'd512) begin
            $display("FAIL: READ_SECTOR len: %0d, expected 512", resp_len);
            errors = errors + 1;
        end else begin
            begin
                integer k;
                reg [7:0] exp;
                reg data_ok;
                data_ok = 1;
                for (k = 0; k < 512; k = k + 1) begin
                    exp = (k * 5 + 8'h37) & 8'hFF;
                    if (resp_payload[k] !== exp) begin
                        if (data_ok)
                            $display("FAIL: READ_SECTOR payload[%0d]=0x%02X, expected 0x%02X",
                                     k, resp_payload[k], exp);
                        data_ok = 0;
                    end
                end
                if (!data_ok)
                    errors = errors + 1;
            end
        end

        begin
            reg [7:0] expected_crc5;
            expected_crc5 = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== expected_crc5) begin
                $display("FAIL: READ_SECTOR CRC: 0x%02X, expected 0x%02X", resp_crc, expected_crc5);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 6: RX timeout (send incomplete packet, then valid PING)
        // Send only header + cmd, wait for timeout (~87ms), then send valid PING
        // ============================================================
        $display("  Test 6: RX timeout recovery...");
        // Send partial packet (only header + cmd, no len/crc)
        uart_send_byte(8'hAA);
        uart_send_byte(8'h01);
        // Now wait for RX timeout. The counter is 23-bit at 60 MHz = ~140ms.
        // In simulation with 10ns clock, that's 8.7M ns = too long.
        // We'll check that protocol_error is set eventually, or just
        // wait a fixed amount and then send a valid PING.
        // Since the timeout is very long, let's just check recovery works
        // by waiting enough and sending a new packet.

        // Wait ~90ms worth of clocks: 96M * 0.087 = 8,352,000 clocks
        // That's too many. Let's check the protocol_error flag instead.
        // Actually we can force the timeout faster by waiting for the bit.
        begin : timeout_wait
            integer cnt;
            for (cnt = 0; cnt < 9_000_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (protocol_error)
                    disable timeout_wait;
            end
        end

        if (!protocol_error) begin
            $display("FAIL: RX timeout not triggered (protocol_error not set)");
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // Now send a valid PING — should work after timeout recovery
        fork
            send_packet(8'h01, 16'd0, 0,0,0,0,0,0, 8'h6B);
            recv_packet;
        join

        if (resp_cmd !== 8'h01 || resp_status_byte !== 8'h00) begin
            $display("FAIL: recovery after timeout: cmd=0x%02X status=0x%02X",
                     resp_cmd, resp_status_byte);
            errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 7: WRITE_SECTOR (0x04), LBA=0x00000100, COUNT=1
        // Payload: 4B LBA + 2B count + 512B data = 518 bytes
        // Pattern: (i*7+0x13) & 0xFF
        // ============================================================
        $display("  Test 7: WRITE_SECTOR...");
        wr_capture_ptr = 10'd0;  // reset capture pointer
        begin
            integer i;
            // Fill tx_large_payload: [LBA(4)] [COUNT(2)] [DATA(512)]
            tx_large_payload[0] = 8'h00; // LBA[31:24]
            tx_large_payload[1] = 8'h00; // LBA[23:16]
            tx_large_payload[2] = 8'h01; // LBA[15:8]
            tx_large_payload[3] = 8'h00; // LBA[7:0]
            tx_large_payload[4] = 8'h00; // COUNT[15:8]
            tx_large_payload[5] = 8'h01; // COUNT[7:0]
            for (i = 0; i < 512; i = i + 1)
                tx_large_payload[6 + i] = (i * 7 + 8'h13) & 8'hFF;

            fork
                // Thread 1: Send command + receive response
                begin
                    send_packet_auto(8'h04, 16'd518);
                    recv_packet;
                end

                // Thread 2: Mock eMMC — wait for cmd_valid, verify, then respond
                begin
                    begin : wait_wr_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 6000; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_wr_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h04) begin
                        $display("FAIL: WRITE_SECTOR cmd_id: 0x%02X, expected 0x04", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    if (!emmc_wr_sector_valid) begin
                        $display("FAIL: WRITE_SECTOR wr_sector_valid not asserted");
                        errors = errors + 1;
                    end
                    if (emmc_cmd_lba !== 32'h00000100) begin
                        $display("FAIL: WRITE_SECTOR LBA: 0x%08X, expected 0x00000100", emmc_cmd_lba);
                        errors = errors + 1;
                    end
                    // Wait for mock processing, then send response
                    repeat (50) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end
            join
        end

        // Verify response
        if (resp_header !== 8'h55) begin
            $display("FAIL: WRITE_SECTOR header: 0x%02X", resp_header);
            errors = errors + 1;
        end
        if (resp_cmd !== 8'h04) begin
            $display("FAIL: WRITE_SECTOR resp cmd: 0x%02X, expected 0x04", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: WRITE_SECTOR status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        // Verify captured write data matches pattern
        begin
            integer k;
            reg [7:0] wr_exp;
            reg wr_data_ok;
            wr_data_ok = 1;
            for (k = 0; k < 512; k = k + 1) begin
                wr_exp = (k * 7 + 8'h13) & 8'hFF;
                if (wr_capture_mem[k] !== wr_exp) begin
                    if (wr_data_ok)
                        $display("FAIL: WRITE_SECTOR data[%0d]=0x%02X, expected 0x%02X",
                                 k, wr_capture_mem[k], wr_exp);
                    wr_data_ok = 0;
                end
            end
            if (!wr_data_ok)
                errors = errors + 1;
        end
        // Verify response CRC
        begin
            reg [7:0] wr_resp_crc;
            wr_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== wr_resp_crc) begin
                $display("FAIL: WRITE_SECTOR CRC: 0x%02X, expected 0x%02X", resp_crc, wr_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 8: ERASE (0x05), LBA=100 (0x64), COUNT=10 (0x0A)
        // Payload: 4B LBA + 2B count = 6 bytes
        // ============================================================
        $display("  Test 8: ERASE...");
        begin
            reg [7:0] erase_crc;
            erase_crc = 8'd0;
            erase_crc = calc_crc8(erase_crc, 8'h05);       // CMD
            erase_crc = calc_crc8(erase_crc, 8'h00);       // LEN_H
            erase_crc = calc_crc8(erase_crc, 8'h06);       // LEN_L
            erase_crc = calc_crc8(erase_crc, 8'h00);       // LBA[31:24]
            erase_crc = calc_crc8(erase_crc, 8'h00);       // LBA[23:16]
            erase_crc = calc_crc8(erase_crc, 8'h00);       // LBA[15:8]
            erase_crc = calc_crc8(erase_crc, 8'h64);       // LBA[7:0]
            erase_crc = calc_crc8(erase_crc, 8'h00);       // COUNT[15:8]
            erase_crc = calc_crc8(erase_crc, 8'h0A);       // COUNT[7:0]

            fork
                // Thread 1: Send ERASE command
                send_packet(8'h05, 16'd6, 8'h00, 8'h00, 8'h00, 8'h64, 8'h00, 8'h0A, erase_crc);

                // Thread 2: Mock eMMC — wait for cmd_valid, verify, respond
                begin
                    begin : wait_erase_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_erase_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h05) begin
                        $display("FAIL: ERASE cmd_id: 0x%02X, expected 0x05", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    if (emmc_cmd_lba !== 32'h00000064) begin
                        $display("FAIL: ERASE LBA: 0x%08X, expected 0x00000064", emmc_cmd_lba);
                        errors = errors + 1;
                    end
                    if (emmc_cmd_count !== 16'h000A) begin
                        $display("FAIL: ERASE count: 0x%04X, expected 0x000A", emmc_cmd_count);
                        errors = errors + 1;
                    end
                    repeat (50) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end

                // Thread 3: Receive response
                recv_packet;
            join
        end

        if (resp_cmd !== 8'h05) begin
            $display("FAIL: ERASE resp cmd: 0x%02X, expected 0x05", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: ERASE status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        begin
            reg [7:0] erase_resp_crc;
            erase_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== erase_resp_crc) begin
                $display("FAIL: ERASE CRC: 0x%02X, expected 0x%02X", resp_crc, erase_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 9: GET_STATUS (0x06) — 12-byte extended debug status
        // Pre-set emmc_resp_status = 0x42, debug stubs set above
        // Expected: [55, 06, 00, 00, 0C, <12 bytes>, CRC]
        // Byte 0: resp_status_r (pipeline from emmc_resp_status) = 0x42
        // Byte 1: {init_state=12, 0, mc_state[4:2]=0} = 0xC0
        // Byte 2: {mc_state[1:0]=10, info_valid=1, cmd_ready=1, 0000} = 0xB0
        // Byte 3: {cmd_pin=1, dat0_pin=1, 000000} = 0xC0
        // Byte 4: {cmd_fsm=0, dat_fsm=0, use_fast_clk=1} = 0x01
        // Byte 5: {partition=0, reinit_pending=0, 00000} = 0x00
        // Byte 6: err_cmd_timeout = 3
        // Byte 7: err_cmd_crc = 1
        // Byte 8: err_dat_rd = 0
        // Byte 9: err_dat_wr = 2
        // Byte 10: init_retry_cnt = 5
        // Byte 11: reserved = 0
        // ============================================================
        $display("  Test 9: GET_STATUS (12-byte)...");
        emmc_resp_status = 8'h42;
        begin
            reg [7:0] gs_crc;
            reg [7:0] gs_expected [0:11];
            gs_crc = 8'd0;
            gs_crc = calc_crc8(gs_crc, 8'h06);  // CMD
            gs_crc = calc_crc8(gs_crc, 8'h00);  // LEN_H
            gs_crc = calc_crc8(gs_crc, 8'h00);  // LEN_L

            gs_expected[0]  = 8'h42; // resp_status
            gs_expected[1]  = 8'hC0; // {init_state=12, 0, mc_state[4:2]=000}
            gs_expected[2]  = 8'hB0; // {mc_state[1:0]=10, info_valid=1, cmd_ready=1, 0000}
            gs_expected[3]  = 8'hC0; // {cmd_pin=1, dat0_pin=1, 000000}
            gs_expected[4]  = 8'h01; // {cmd_fsm=000, dat_fsm=0000, use_fast_clk=1}
            gs_expected[5]  = 8'h00; // {partition=00, reinit_pending=0, 00000}
            gs_expected[6]  = 8'h03; // err_cmd_timeout
            gs_expected[7]  = 8'h01; // err_cmd_crc
            gs_expected[8]  = 8'h00; // err_dat_rd
            gs_expected[9]  = 8'h02; // err_dat_wr
            gs_expected[10] = 8'h05; // init_retry_cnt
            gs_expected[11] = 8'h00; // clk_preset (0 = 2 MHz)

            fork
                send_packet(8'h06, 16'd0, 0,0,0,0,0,0, gs_crc);
                recv_packet;
            join

            if (resp_cmd !== 8'h06) begin
                $display("FAIL: GET_STATUS resp cmd: 0x%02X, expected 0x06", resp_cmd);
                errors = errors + 1;
            end
            if (resp_status_byte !== 8'h00) begin
                $display("FAIL: GET_STATUS status: 0x%02X", resp_status_byte);
                errors = errors + 1;
            end
            if (resp_len !== 16'd12) begin
                $display("FAIL: GET_STATUS len: %0d, expected 12", resp_len);
                errors = errors + 1;
            end else begin
                begin
                    integer k;
                    for (k = 0; k < 12; k = k + 1) begin
                        if (resp_payload[k] !== gs_expected[k]) begin
                            $display("FAIL: GET_STATUS byte[%0d]: 0x%02X, expected 0x%02X",
                                     k, resp_payload[k], gs_expected[k]);
                            errors = errors + 1;
                        end
                    end
                end
            end
        end
        begin
            reg [7:0] gs_resp_crc;
            gs_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== gs_resp_crc) begin
                $display("FAIL: GET_STATUS CRC: 0x%02X, expected 0x%02X", resp_crc, gs_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 10: GET_EXT_CSD (0x07) — 512-byte sector response
        // Response uses cmd=0x03 (READ_SECTOR) in TX FSM for sector data
        // Data pattern: (addr*5+0x37)&0xFF from reactive provider
        // ============================================================
        $display("  Test 10: GET_EXT_CSD...");
        begin
            reg [7:0] ext_crc;
            ext_crc = 8'd0;
            ext_crc = calc_crc8(ext_crc, 8'h07);  // CMD
            ext_crc = calc_crc8(ext_crc, 8'h00);  // LEN_H
            ext_crc = calc_crc8(ext_crc, 8'h00);  // LEN_L

            fork
                // Thread 1: Send GET_EXT_CSD command
                send_packet(8'h07, 16'd0, 0,0,0,0,0,0, ext_crc);

                // Thread 2: Mock eMMC — wait for cmd_valid, then assert rd_sector_ready (sticky)
                begin
                    begin : wait_ext_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_ext_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h07) begin
                        $display("FAIL: GET_EXT_CSD cmd_id: 0x%02X, expected 0x07", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    repeat (50) @(posedge clk);
                    emmc_rd_sector_ready <= 1'b1;
                    // Wait for ack from uart_bridge
                    begin : wait_ext_ack
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 600; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_rd_sector_ack) disable wait_ext_ack;
                        end
                    end
                    emmc_rd_sector_ready <= 1'b0;
                end

                // Thread 3: Receive response
                recv_packet;
            join
        end

        // Response cmd is 0x03 (READ_SECTOR) per TX FSM logic
        if (resp_cmd !== 8'h03) begin
            $display("FAIL: GET_EXT_CSD resp cmd: 0x%02X, expected 0x03", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: GET_EXT_CSD status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        if (resp_len !== 16'd512) begin
            $display("FAIL: GET_EXT_CSD len: %0d, expected 512", resp_len);
            errors = errors + 1;
        end else begin
            begin
                integer k;
                reg [7:0] ext_exp;
                reg ext_data_ok;
                ext_data_ok = 1;
                for (k = 0; k < 512; k = k + 1) begin
                    ext_exp = (k * 5 + 8'h37) & 8'hFF;
                    if (resp_payload[k] !== ext_exp) begin
                        if (ext_data_ok)
                            $display("FAIL: GET_EXT_CSD payload[%0d]=0x%02X, expected 0x%02X",
                                     k, resp_payload[k], ext_exp);
                        ext_data_ok = 0;
                    end
                end
                if (!ext_data_ok)
                    errors = errors + 1;
            end
        end
        begin
            reg [7:0] ext_resp_crc;
            ext_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== ext_resp_crc) begin
                $display("FAIL: GET_EXT_CSD CRC: 0x%02X, expected 0x%02X", resp_crc, ext_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 11: SET_PARTITION (0x08), partition_id=0x02 (boot1)
        // Payload: 1 byte (partition ID)
        // ============================================================
        $display("  Test 11: SET_PARTITION...");
        begin
            reg [7:0] sp_crc;
            sp_crc = 8'd0;
            sp_crc = calc_crc8(sp_crc, 8'h08);  // CMD
            sp_crc = calc_crc8(sp_crc, 8'h00);  // LEN_H
            sp_crc = calc_crc8(sp_crc, 8'h01);  // LEN_L
            sp_crc = calc_crc8(sp_crc, 8'h02);  // partition_id

            fork
                // Thread 1: Send SET_PARTITION command
                send_packet(8'h08, 16'd1, 8'h02, 0,0,0,0,0, sp_crc);

                // Thread 2: Mock eMMC — wait for cmd_valid, verify, respond
                begin
                    begin : wait_sp_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_sp_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h08) begin
                        $display("FAIL: SET_PARTITION cmd_id: 0x%02X, expected 0x08", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    if (emmc_cmd_lba[7:0] !== 8'h02) begin
                        $display("FAIL: SET_PARTITION partition_id: 0x%02X, expected 0x02", emmc_cmd_lba[7:0]);
                        errors = errors + 1;
                    end
                    repeat (50) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end

                // Thread 3: Receive response
                recv_packet;
            join
        end

        if (resp_cmd !== 8'h08) begin
            $display("FAIL: SET_PARTITION resp cmd: 0x%02X, expected 0x08", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: SET_PARTITION status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        begin
            reg [7:0] sp_resp_crc;
            sp_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== sp_resp_crc) begin
                $display("FAIL: SET_PARTITION CRC: 0x%02X, expected 0x%02X", resp_crc, sp_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 12: WRITE_EXT_CSD (0x09), index=33, value=1
        // Payload: 2 bytes (index, value)
        // ============================================================
        $display("  Test 12: WRITE_EXT_CSD...");
        begin
            reg [7:0] wext_crc;
            wext_crc = 8'd0;
            wext_crc = calc_crc8(wext_crc, 8'h09);  // CMD
            wext_crc = calc_crc8(wext_crc, 8'h00);  // LEN_H
            wext_crc = calc_crc8(wext_crc, 8'h02);  // LEN_L
            wext_crc = calc_crc8(wext_crc, 8'h21);  // index=33
            wext_crc = calc_crc8(wext_crc, 8'h01);  // value=1

            fork
                // Thread 1: Send WRITE_EXT_CSD command
                send_packet(8'h09, 16'd2, 8'h21, 8'h01, 0,0,0,0, wext_crc);

                // Thread 2: Mock eMMC — wait for cmd_valid, verify, respond
                begin
                    begin : wait_wext_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_wext_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h09) begin
                        $display("FAIL: WRITE_EXT_CSD cmd_id: 0x%02X, expected 0x09", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    // Check lba encoding: [15:8]=index=33, [7:0]=value=1
                    if (emmc_cmd_lba[15:8] !== 8'h21) begin
                        $display("FAIL: WRITE_EXT_CSD index: 0x%02X, expected 0x21", emmc_cmd_lba[15:8]);
                        errors = errors + 1;
                    end
                    if (emmc_cmd_lba[7:0] !== 8'h01) begin
                        $display("FAIL: WRITE_EXT_CSD value: 0x%02X, expected 0x01", emmc_cmd_lba[7:0]);
                        errors = errors + 1;
                    end
                    repeat (50) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end

                // Thread 3: Receive response
                recv_packet;
            join
        end

        if (resp_cmd !== 8'h09) begin
            $display("FAIL: WRITE_EXT_CSD resp cmd: 0x%02X, expected 0x09", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: WRITE_EXT_CSD status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        begin
            reg [7:0] wext_resp_crc;
            wext_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== wext_resp_crc) begin
                $display("FAIL: WRITE_EXT_CSD CRC: 0x%02X, expected 0x%02X", resp_crc, wext_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 13: READ_SECTOR with count=0 (should return ERR_CMD)
        // TX: [AA, 03, 00, 06, LBA(4)=0, COUNT(2)=0, CRC]
        // Expected: [55, 03, 02, 00, 00, CRC] (STATUS_ERR_CMD=0x02)
        // ============================================================
        $display("  Test 13: READ_SECTOR count=0...");
        begin
            reg [7:0] r0_crc;
            r0_crc = 8'd0;
            r0_crc = calc_crc8(r0_crc, 8'h03);       // CMD
            r0_crc = calc_crc8(r0_crc, 8'h00);       // LEN_H
            r0_crc = calc_crc8(r0_crc, 8'h06);       // LEN_L
            r0_crc = calc_crc8(r0_crc, 8'h00);       // LBA[31:24]
            r0_crc = calc_crc8(r0_crc, 8'h00);       // LBA[23:16]
            r0_crc = calc_crc8(r0_crc, 8'h00);       // LBA[15:8]
            r0_crc = calc_crc8(r0_crc, 8'h00);       // LBA[7:0]
            r0_crc = calc_crc8(r0_crc, 8'h00);       // COUNT[15:8]
            r0_crc = calc_crc8(r0_crc, 8'h00);       // COUNT[7:0]

            fork
                // Thread 1: Send READ_SECTOR command with count=0
                send_packet(8'h03, 16'd6, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, r0_crc);

                // Thread 2: Mock eMMC — wait for cmd_valid, return ERR_CMD
                begin
                    begin : wait_r0_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_r0_cmd;
                        end
                    end
                    // Respond with ERR_CMD (0x02)
                    repeat (50) @(posedge clk);
                    emmc_resp_status = 8'h02;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end

                // Thread 3: Receive response
                recv_packet;
            join
        end

        if (resp_cmd !== 8'h03) begin
            $display("FAIL: READ count=0 resp cmd: 0x%02X, expected 0x03", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h02) begin
            $display("FAIL: READ count=0 status: 0x%02X, expected 0x02 (ERR_CMD)", resp_status_byte);
            errors = errors + 1;
        end
        if (resp_len !== 16'd0) begin
            $display("FAIL: READ count=0 len: %0d, expected 0", resp_len);
            errors = errors + 1;
        end
        begin
            reg [7:0] r0_resp_crc;
            r0_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== r0_resp_crc) begin
                $display("FAIL: READ count=0 CRC: 0x%02X, expected 0x%02X", resp_crc, r0_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 14: GET_CARD_STATUS (0x0A) — CMD13 SEND_STATUS
        // TX: [AA, 0A, 00, 00, CRC]
        // Expected: [55, 0A, 00, 00, 04, <4 bytes card_status>, CRC]
        // ============================================================
        $display("  Test 14: GET_CARD_STATUS...");
        emmc_card_status = 32'hDEADBEEF;
        begin
            reg [7:0] cs_crc;
            cs_crc = 8'd0;
            cs_crc = calc_crc8(cs_crc, 8'h0A);  // CMD
            cs_crc = calc_crc8(cs_crc, 8'h00);  // LEN_H
            cs_crc = calc_crc8(cs_crc, 8'h00);  // LEN_L

            fork
                // Thread 1: Send GET_CARD_STATUS command
                send_packet(8'h0A, 16'd0, 0,0,0,0,0,0, cs_crc);

                // Thread 2: Mock eMMC — wait for cmd_valid, respond with card_status
                begin
                    begin : wait_cs_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_cs_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h0A) begin
                        $display("FAIL: GET_CARD_STATUS cmd_id: 0x%02X, expected 0x0A", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    repeat (50) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end

                // Thread 3: Receive response
                recv_packet;
            join
        end

        if (resp_cmd !== 8'h0A) begin
            $display("FAIL: GET_CARD_STATUS resp cmd: 0x%02X, expected 0x0A", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: GET_CARD_STATUS status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        if (resp_len !== 16'd4) begin
            $display("FAIL: GET_CARD_STATUS len: %0d, expected 4", resp_len);
            errors = errors + 1;
        end else begin
            // Verify card_status bytes (big-endian in info_shift)
            if (resp_payload[0] !== 8'hDE) begin
                $display("FAIL: GET_CARD_STATUS payload[0]: 0x%02X, expected 0xDE", resp_payload[0]);
                errors = errors + 1;
            end
            if (resp_payload[1] !== 8'hAD) begin
                $display("FAIL: GET_CARD_STATUS payload[1]: 0x%02X, expected 0xAD", resp_payload[1]);
                errors = errors + 1;
            end
            if (resp_payload[2] !== 8'hBE) begin
                $display("FAIL: GET_CARD_STATUS payload[2]: 0x%02X, expected 0xBE", resp_payload[2]);
                errors = errors + 1;
            end
            if (resp_payload[3] !== 8'hEF) begin
                $display("FAIL: GET_CARD_STATUS payload[3]: 0x%02X, expected 0xEF", resp_payload[3]);
                errors = errors + 1;
            end
        end
        begin
            reg [7:0] cs_resp_crc;
            cs_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== cs_resp_crc) begin
                $display("FAIL: GET_CARD_STATUS CRC: 0x%02X, expected 0x%02X", resp_crc, cs_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 15: REINIT (0x0B) — full re-initialization
        // No payload
        // ============================================================
        $display("  Test 15: REINIT...");
        begin
            reg [7:0] ri_crc;
            ri_crc = 8'd0;
            ri_crc = calc_crc8(ri_crc, 8'h0B);  // CMD
            ri_crc = calc_crc8(ri_crc, 8'h00);  // LEN_H
            ri_crc = calc_crc8(ri_crc, 8'h00);  // LEN_L

            fork
                // Thread 1: Send REINIT command
                send_packet(8'h0B, 16'd0, 0,0,0,0,0,0, ri_crc);

                // Thread 2: Mock eMMC — wait for cmd_valid, verify, respond
                begin
                    begin : wait_ri_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_ri_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h0B) begin
                        $display("FAIL: REINIT cmd_id: 0x%02X, expected 0x0B", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    // Mock: simulate init completion delay then respond OK
                    repeat (100) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end

                // Thread 3: Receive response
                recv_packet;
            join
        end

        if (resp_cmd !== 8'h0B) begin
            $display("FAIL: REINIT resp cmd: 0x%02X, expected 0x0B", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: REINIT status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        if (resp_len !== 16'd0) begin
            $display("FAIL: REINIT resp len: %0d, expected 0", resp_len);
            errors = errors + 1;
        end
        begin
            reg [7:0] ri_resp_crc;
            ri_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== ri_resp_crc) begin
                $display("FAIL: REINIT CRC: 0x%02X, expected 0x%02X", resp_crc, ri_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 16: SECURE_ERASE (0x0C) — same as ERASE but different cmd_id
        // Payload: LBA=0x000000C8 (200), COUNT=0x0005
        // ============================================================
        $display("  Test 16: SECURE_ERASE...");
        begin
            reg [7:0] se_crc;
            se_crc = 8'd0;
            se_crc = calc_crc8(se_crc, 8'h0C);  // CMD
            se_crc = calc_crc8(se_crc, 8'h00);  // LEN_H
            se_crc = calc_crc8(se_crc, 8'h06);  // LEN_L
            se_crc = calc_crc8(se_crc, 8'h00);  // LBA[31:24]
            se_crc = calc_crc8(se_crc, 8'h00);  // LBA[23:16]
            se_crc = calc_crc8(se_crc, 8'h00);  // LBA[15:8]
            se_crc = calc_crc8(se_crc, 8'hC8);  // LBA[7:0] = 200
            se_crc = calc_crc8(se_crc, 8'h00);  // COUNT[15:8]
            se_crc = calc_crc8(se_crc, 8'h05);  // COUNT[7:0] = 5

            fork
                // Thread 1: Send SECURE_ERASE command
                send_packet(8'h0C, 16'd6, 8'h00, 8'h00, 8'h00, 8'hC8, 8'h00, 8'h05, se_crc);

                // Thread 2: Mock eMMC — wait for cmd_valid, verify, respond
                begin
                    begin : wait_se_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_se_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h0C) begin
                        $display("FAIL: SECURE_ERASE cmd_id: 0x%02X, expected 0x0C", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    if (emmc_cmd_lba !== 32'h000000C8) begin
                        $display("FAIL: SECURE_ERASE LBA: 0x%08X, expected 0x000000C8", emmc_cmd_lba);
                        errors = errors + 1;
                    end
                    if (emmc_cmd_count !== 16'h0005) begin
                        $display("FAIL: SECURE_ERASE count: 0x%04X, expected 0x0005", emmc_cmd_count);
                        errors = errors + 1;
                    end
                    repeat (50) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end

                // Thread 3: Receive response
                recv_packet;
            join
        end

        if (resp_cmd !== 8'h0C) begin
            $display("FAIL: SECURE_ERASE resp cmd: 0x%02X, expected 0x0C", resp_cmd);
            errors = errors + 1;
        end
        if (resp_status_byte !== 8'h00) begin
            $display("FAIL: SECURE_ERASE status: 0x%02X", resp_status_byte);
            errors = errors + 1;
        end
        begin
            reg [7:0] se_resp_crc;
            se_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== se_resp_crc) begin
                $display("FAIL: SECURE_ERASE CRC: 0x%02X, expected 0x%02X", resp_crc, se_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 17: WRITE_SECTOR with count=2 (multi-write)
        // Payload: LBA(4) + COUNT(2) + DATA_0(512) + DATA_1(512) = 1030 bytes
        // Sector 0 pattern: (i * 7 + 0x21) & 0xFF
        // Sector 1 pattern: (i * 11 + 0x43) & 0xFF
        // eMMC mock: ack first sector via wr_sector_ack after wr_sector_valid,
        // then ack second sector, then pulse resp_valid.
        // ============================================================
        $display("  Test 17: WRITE_SECTOR count=2 (multi-write)...");
        wr_capture_ptr = 10'd0;  // reset capture pointer
        begin
            integer i;
            // Fill tx_large_payload: [LBA(4)] [COUNT(2)] [DATA_0(512)] [DATA_1(512)]
            tx_large_payload[0] = 8'h00; // LBA[31:24]
            tx_large_payload[1] = 8'h00; // LBA[23:16]
            tx_large_payload[2] = 8'h02; // LBA[15:8]
            tx_large_payload[3] = 8'h00; // LBA[7:0] = 0x200
            tx_large_payload[4] = 8'h00; // COUNT[15:8]
            tx_large_payload[5] = 8'h02; // COUNT[7:0] = 2
            for (i = 0; i < 512; i = i + 1)
                tx_large_payload[6 + i] = (i * 7 + 8'h21) & 8'hFF;
            for (i = 0; i < 512; i = i + 1)
                tx_large_payload[518 + i] = (i * 11 + 8'h43) & 8'hFF;

            fork
                // Thread 1: Send command
                begin
                    send_packet_auto(8'h04, 16'd1030);
                end

                // Thread 2: Receive response (parallel with send — early dispatch
                // causes resp_valid before entire packet is sent)
                begin
                    // Wait for TX start bit with large timeout
                    // (~170K clocks: 518 bytes TX + mock ack handshake + resp_valid)
                    begin : wait_mw2_bridge_resp
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 2000; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (uart_tx_pin == 1'b0) disable wait_mw2_bridge_resp;
                        end
                    end
                    // Receive header byte (start bit already detected)
                    begin
                        integer i;
                        repeat (CLKS_PER_BIT / 2) @(posedge clk);
                        for (i = 0; i < 8; i = i + 1) begin
                            repeat (CLKS_PER_BIT) @(posedge clk);
                            resp_header[i] = uart_tx_pin;
                        end
                        repeat (CLKS_PER_BIT) @(posedge clk); // stop bit
                    end
                    // Rest of response
                    uart_recv_byte; resp_cmd = rx_captured;
                    uart_recv_byte; resp_status_byte = rx_captured;
                    uart_recv_byte; resp_len[15:8] = rx_captured;
                    uart_recv_byte; resp_len[7:0] = rx_captured;
                    begin
                        integer j;
                        for (j = 0; j < resp_len && j < 512; j = j + 1) begin
                            uart_recv_byte;
                            resp_payload[j] = rx_captured;
                        end
                    end
                    uart_recv_byte; resp_crc = rx_captured;
                    resp_payload_cnt = resp_len;
                end

                // Thread 3: Mock eMMC controller — multi-write handshake
                begin
                    // Wait for cmd_valid to go low first (clear any stale pulse)
                    begin : wait_mw_clear
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 20; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (!emmc_cmd_valid) disable wait_mw_clear;
                        end
                    end
                    // Wait for NEW cmd_valid (first sector ready — early dispatch after 518 bytes)
                    begin : wait_mw_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 1200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_mw_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h04) begin
                        $display("FAIL: multi-write cmd_id: 0x%02X, expected 0x04", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    if (emmc_cmd_lba !== 32'h00000200) begin
                        $display("FAIL: multi-write LBA: 0x%08X, expected 0x00000200", emmc_cmd_lba);
                        errors = errors + 1;
                    end
                    if (emmc_cmd_count !== 16'h0002) begin
                        $display("FAIL: multi-write count: 0x%04X, expected 0x0002", emmc_cmd_count);
                        errors = errors + 1;
                    end
                    if (!emmc_wr_sector_valid) begin
                        $display("FAIL: multi-write wr_sector_valid not asserted for sector 0");
                        errors = errors + 1;
                    end

                    // Ack first sector (eMMC would write it to flash)
                    repeat (20) @(posedge clk);
                    emmc_wr_sector_ack <= 1'b1;
                    @(posedge clk);
                    emmc_wr_sector_ack <= 1'b0;

                    // Wait for second sector wr_sector_valid (sticky from wr_sector_pending)
                    begin : wait_mw_sec2
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 1200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_wr_sector_valid) disable wait_mw_sec2;
                        end
                    end
                    if (!emmc_wr_sector_valid) begin
                        $display("FAIL: multi-write wr_sector_valid not asserted for sector 1");
                        errors = errors + 1;
                    end

                    // Ack second sector
                    repeat (20) @(posedge clk);
                    emmc_wr_sector_ack <= 1'b1;
                    @(posedge clk);
                    emmc_wr_sector_ack <= 1'b0;

                    // Send final resp_valid (STATUS_OK)
                    repeat (50) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end
            join
        end

        // Verify response
        if (resp_header !== 8'h55) begin
            $display("FAIL: multi-write resp header: 0x%02X, expected 0x55 (timeout?)", resp_header);
            errors = errors + 1;
        end
        else if (resp_cmd !== 8'h04) begin
            $display("FAIL: multi-write resp cmd: 0x%02X, expected 0x04", resp_cmd);
            errors = errors + 1;
        end
        else if (resp_status_byte !== 8'h00) begin
            $display("FAIL: multi-write status: 0x%02X, expected 0x00 (OK)", resp_status_byte);
            errors = errors + 1;
        end
        else if (resp_len !== 16'd0) begin
            $display("FAIL: multi-write len: %0d, expected 0", resp_len);
            errors = errors + 1;
        end
        // Verify captured write data — sector 0 pattern
        begin
            integer k;
            reg [7:0] wr_exp;
            reg wr_data_ok;
            wr_data_ok = 1;
            for (k = 0; k < 512; k = k + 1) begin
                wr_exp = (k * 7 + 8'h21) & 8'hFF;
                if (wr_capture_mem[k] !== wr_exp) begin
                    if (wr_data_ok)
                        $display("FAIL: multi-write sector0[%0d]=0x%02X, expected 0x%02X",
                                 k, wr_capture_mem[k], wr_exp);
                    wr_data_ok = 0;
                end
            end
            if (!wr_data_ok)
                errors = errors + 1;
        end
        // Verify captured write data — sector 1 pattern
        begin
            integer k;
            reg [7:0] wr_exp;
            reg wr_data_ok;
            wr_data_ok = 1;
            for (k = 0; k < 512; k = k + 1) begin
                wr_exp = (k * 11 + 8'h43) & 8'hFF;
                if (wr_capture_mem[512 + k] !== wr_exp) begin
                    if (wr_data_ok)
                        $display("FAIL: multi-write sector1[%0d]=0x%02X, expected 0x%02X",
                                 k, wr_capture_mem[512 + k], wr_exp);
                    wr_data_ok = 0;
                end
            end
            if (!wr_data_ok)
                errors = errors + 1;
        end
        // Verify response CRC
        begin
            reg [7:0] mw_resp_crc;
            mw_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== mw_resp_crc) begin
                $display("FAIL: multi-write CRC: 0x%02X, expected 0x%02X", resp_crc, mw_resp_crc);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 18: READ_SECTOR count=2 (multi-sector read)
        // Two rd_sector_ready pulses → two 512-byte response packets
        // Then resp_valid for final completion
        // ============================================================
        $display("  Test 18: READ_SECTOR count=2 (multi-sector)...");
        begin
            reg [7:0] mr_crc;
            mr_crc = 8'd0;
            mr_crc = calc_crc8(mr_crc, 8'h03);       // CMD
            mr_crc = calc_crc8(mr_crc, 8'h00);       // LEN_H
            mr_crc = calc_crc8(mr_crc, 8'h06);       // LEN_L
            mr_crc = calc_crc8(mr_crc, 8'h00);       // LBA[31:24]
            mr_crc = calc_crc8(mr_crc, 8'h00);       // LBA[23:16]
            mr_crc = calc_crc8(mr_crc, 8'h00);       // LBA[15:8]
            mr_crc = calc_crc8(mr_crc, 8'h05);       // LBA[7:0] = 5
            mr_crc = calc_crc8(mr_crc, 8'h00);       // COUNT[15:8]
            mr_crc = calc_crc8(mr_crc, 8'h02);       // COUNT[7:0] = 2

            fork
                // Thread 1: Send READ_SECTOR command
                send_packet(8'h03, 16'd6, 8'h00, 8'h00, 8'h00, 8'h05, 8'h00, 8'h02, mr_crc);

                // Thread 2: Mock eMMC — sticky rd_sector_ready, wait for ack
                begin
                    begin : wait_mr_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 200; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_mr_cmd;
                        end
                    end
                    // First sector ready (sticky)
                    repeat (50) @(posedge clk);
                    emmc_rd_sector_ready <= 1'b1;
                    // Wait for ack from uart_bridge
                    begin : wait_mr_ack1
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 600; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_rd_sector_ack) disable wait_mr_ack1;
                        end
                    end
                    emmc_rd_sector_ready <= 1'b0;

                    // Wait for first sector to be mostly transmitted before second
                    repeat (CLKS_PER_BIT * 10 * 512 + CLKS_PER_BIT * 100) @(posedge clk);

                    // Second sector ready (sticky)
                    emmc_rd_sector_ready <= 1'b1;
                    // Wait for ack
                    begin : wait_mr_ack2
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 600; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_rd_sector_ack) disable wait_mr_ack2;
                        end
                    end
                    emmc_rd_sector_ready <= 1'b0;

                    // Wait and then send final resp_valid
                    repeat (CLKS_PER_BIT * 10 * 512 + CLKS_PER_BIT * 100) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end

                // Thread 3: Receive first sector packet, then second, then final
                begin : mr_recv
                    // Receive first 512-byte sector packet
                    recv_packet;
                    if (resp_cmd !== 8'h03) begin
                        $display("FAIL: multi-read S0 cmd: 0x%02X, expected 0x03", resp_cmd);
                        errors = errors + 1;
                    end
                    if (resp_status_byte !== 8'h00) begin
                        $display("FAIL: multi-read S0 status: 0x%02X", resp_status_byte);
                        errors = errors + 1;
                    end
                    if (resp_len !== 16'd512) begin
                        $display("FAIL: multi-read S0 len: %0d, expected 512", resp_len);
                        errors = errors + 1;
                    end else begin
                        // Verify first sector data pattern
                        begin
                            integer k;
                            reg [7:0] exp;
                            reg data_ok;
                            data_ok = 1;
                            for (k = 0; k < 512; k = k + 1) begin
                                exp = (k * 5 + 9'h37) & 8'hFF;
                                if (resp_payload[k] !== exp) begin
                                    if (data_ok)
                                        $display("FAIL: multi-read S0 payload[%0d]=0x%02X, expected 0x%02X",
                                                 k, resp_payload[k], exp);
                                    data_ok = 0;
                                end
                            end
                            if (!data_ok) errors = errors + 1;
                        end
                    end
                    begin
                        reg [7:0] mr0_crc;
                        mr0_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
                        if (resp_crc !== mr0_crc) begin
                            $display("FAIL: multi-read S0 CRC: 0x%02X, expected 0x%02X", resp_crc, mr0_crc);
                            errors = errors + 1;
                        end
                    end

                    // Receive second 512-byte sector packet
                    recv_packet;
                    if (resp_cmd !== 8'h03) begin
                        $display("FAIL: multi-read S1 cmd: 0x%02X, expected 0x03", resp_cmd);
                        errors = errors + 1;
                    end
                    if (resp_len !== 16'd512) begin
                        $display("FAIL: multi-read S1 len: %0d, expected 512", resp_len);
                        errors = errors + 1;
                    end
                    begin
                        reg [7:0] mr1_crc;
                        mr1_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
                        if (resp_crc !== mr1_crc) begin
                            $display("FAIL: multi-read S1 CRC: 0x%02X, expected 0x%02X", resp_crc, mr1_crc);
                            errors = errors + 1;
                        end
                    end

                    // Receive final completion response (0-byte payload)
                    recv_packet;
                    if (resp_cmd !== 8'h03) begin
                        $display("FAIL: multi-read final cmd: 0x%02X, expected 0x03", resp_cmd);
                        errors = errors + 1;
                    end
                    if (resp_status_byte !== 8'h00) begin
                        $display("FAIL: multi-read final status: 0x%02X", resp_status_byte);
                        errors = errors + 1;
                    end
                    if (resp_len !== 16'd0) begin
                        $display("FAIL: multi-read final len: %0d, expected 0", resp_len);
                        errors = errors + 1;
                    end
                end
            join
        end

        $display("  Multi-sector read completed OK.");

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 19: SET_BAUD preset=3 (12M, CPB=5)
        // TX: [AA, 0F, 00, 01, 03, CRC]
        // Expected: [55, 0F, 00, 00, 00, CRC] at 3M baud
        // After TX completes, FPGA switches to CPB=5
        // ============================================================
        $display("  Test 19: SET_BAUD preset=3...");
        begin
            reg [7:0] sb_crc;
            sb_crc = 8'd0;
            sb_crc = calc_crc8(sb_crc, 8'h0F);  // CMD
            sb_crc = calc_crc8(sb_crc, 8'h00);  // LEN_H
            sb_crc = calc_crc8(sb_crc, 8'h01);  // LEN_L
            sb_crc = calc_crc8(sb_crc, 8'h03);  // preset=3

            fork
                send_packet(8'h0F, 16'd1, 8'h03, 0,0,0,0,0, sb_crc);
                recv_packet;
            join

            if (resp_cmd !== 8'h0F) begin
                $display("FAIL: SET_BAUD resp cmd: 0x%02X, expected 0x0F", resp_cmd);
                errors = errors + 1;
            end
            if (resp_status_byte !== 8'h00) begin
                $display("FAIL: SET_BAUD status: 0x%02X, expected 0x00", resp_status_byte);
                errors = errors + 1;
            end
            if (resp_len !== 16'd0) begin
                $display("FAIL: SET_BAUD len: %0d, expected 0", resp_len);
                errors = errors + 1;
            end
        end
        begin
            reg [7:0] sb_resp_crc;
            sb_resp_crc = compute_resp_crc(resp_cmd, resp_status_byte, resp_len);
            if (resp_crc !== sb_resp_crc) begin
                $display("FAIL: SET_BAUD CRC: 0x%02X, expected 0x%02X", resp_crc, sb_resp_crc);
                errors = errors + 1;
            end
        end

        // Wait for baud switch to apply (FPGA waits for !tx_busy then switches)
        repeat (CLKS_PER_BIT * 20) @(posedge clk);

        // Verify internal state
        if (uut.uart_clks_per_bit !== 8'd5) begin
            $display("FAIL: SET_BAUD uart_clks_per_bit: %0d, expected 5", uut.uart_clks_per_bit);
            errors = errors + 1;
        end
        if (uut.current_baud_preset !== 2'd3) begin
            $display("FAIL: SET_BAUD current_baud_preset: %0d, expected 3", uut.current_baud_preset);
            errors = errors + 1;
        end

        // PING at new baud rate (CPB=5, 60M/5 = 12M)
        // The FPGA uses CPB=5, so the testbench must also use cpb=5 for send/recv
        $display("  Test 19b: PING at new baud (CPB=5)...");
        begin
            reg [7:0] sb_ping_crc;
            sb_ping_crc = 8'd0;
            sb_ping_crc = calc_crc8(sb_ping_crc, 8'h01);  // CMD_PING
            sb_ping_crc = calc_crc8(sb_ping_crc, 8'h00);  // LEN_H
            sb_ping_crc = calc_crc8(sb_ping_crc, 8'h00);  // LEN_L

            fork
                send_packet_timed(8'h01, 16'd0, 8'h00, sb_ping_crc, 5);
                recv_packet_timed(5);
            join

            if (resp_cmd !== 8'h01) begin
                $display("FAIL: PING@CPB5 resp cmd: 0x%02X, expected 0x01", resp_cmd);
                errors = errors + 1;
            end
            if (resp_status_byte !== 8'h00) begin
                $display("FAIL: PING@CPB5 status: 0x%02X", resp_status_byte);
                errors = errors + 1;
            end
        end

        repeat (5 * 4) @(posedge clk);

        // ============================================================
        // Test 20: SET_BAUD invalid preset=7 → ERR_CMD
        // Must use CPB=5 since we're now at the new baud rate
        // ============================================================
        $display("  Test 20: SET_BAUD invalid preset=7...");
        begin
            reg [7:0] sb2_crc;
            sb2_crc = 8'd0;
            sb2_crc = calc_crc8(sb2_crc, 8'h0F);  // CMD
            sb2_crc = calc_crc8(sb2_crc, 8'h00);  // LEN_H
            sb2_crc = calc_crc8(sb2_crc, 8'h01);  // LEN_L
            sb2_crc = calc_crc8(sb2_crc, 8'h07);  // preset=7 (invalid)

            fork
                send_packet_timed(8'h0F, 16'd1, 8'h07, sb2_crc, 5);
                recv_packet_timed(5);
            join

            if (resp_cmd !== 8'h0F) begin
                $display("FAIL: SET_BAUD invalid resp cmd: 0x%02X, expected 0x0F", resp_cmd);
                errors = errors + 1;
            end
            if (resp_status_byte !== 8'h02) begin
                $display("FAIL: SET_BAUD invalid status: 0x%02X, expected 0x02 (ERR_CMD)", resp_status_byte);
                errors = errors + 1;
            end
            // Verify CPB unchanged (still 5)
            if (uut.uart_clks_per_bit !== 8'd5) begin
                $display("FAIL: SET_BAUD invalid: CPB changed to %0d, should remain 5", uut.uart_clks_per_bit);
                errors = errors + 1;
            end
        end

        repeat (5 * 4) @(posedge clk);

        // ============================================================
        // Test 21: SET_BAUD preset=0 (back to 3M, CPB=20)
        // Send at CPB=5 (current), receive response at CPB=5,
        // then verify switch to CPB=20, then PING at CPB=20
        // ============================================================
        $display("  Test 21: SET_BAUD preset=0 (back to 3M)...");
        begin
            reg [7:0] sb3_crc;
            sb3_crc = 8'd0;
            sb3_crc = calc_crc8(sb3_crc, 8'h0F);  // CMD
            sb3_crc = calc_crc8(sb3_crc, 8'h00);  // LEN_H
            sb3_crc = calc_crc8(sb3_crc, 8'h01);  // LEN_L
            sb3_crc = calc_crc8(sb3_crc, 8'h00);  // preset=0

            fork
                send_packet_timed(8'h0F, 16'd1, 8'h00, sb3_crc, 5);
                recv_packet_timed(5);
            join

            if (resp_status_byte !== 8'h00) begin
                $display("FAIL: SET_BAUD back status: 0x%02X", resp_status_byte);
                errors = errors + 1;
            end
        end

        // Wait for baud switch
        repeat (CLKS_PER_BIT * 20) @(posedge clk);

        if (uut.uart_clks_per_bit !== 8'd20) begin
            $display("FAIL: SET_BAUD back: CPB=%0d, expected 20", uut.uart_clks_per_bit);
            errors = errors + 1;
        end

        // PING at preset 0 baud (CPB=20, hardcoded in baud_preset_to_cpb)
        $display("  Test 21b: PING at preset 0 (CPB=20)...");
        begin
            reg [7:0] sb3_ping_crc;
            sb3_ping_crc = 8'd0;
            sb3_ping_crc = calc_crc8(sb3_ping_crc, 8'h01);
            sb3_ping_crc = calc_crc8(sb3_ping_crc, 8'h00);
            sb3_ping_crc = calc_crc8(sb3_ping_crc, 8'h00);

            fork
                send_packet_timed(8'h01, 16'd0, 8'h00, sb3_ping_crc, 20);
                recv_packet_timed(20);
            join
            if (resp_cmd !== 8'h01 || resp_status_byte !== 8'h00) begin
                $display("FAIL: PING@CPB20 cmd=0x%02X status=0x%02X", resp_cmd, resp_status_byte);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 22: SET_BAUD preset=2 (9M) → ERR_CMD (rejected by FPGA)
        // FPGA rejects preset 2 because 9M doesn't work with FT2232HL
        // ============================================================
        $display("  Test 22: SET_BAUD preset=2 (rejected)...");
        begin
            reg [7:0] sb4_crc;
            sb4_crc = 8'd0;
            sb4_crc = calc_crc8(sb4_crc, 8'h0F);  // CMD
            sb4_crc = calc_crc8(sb4_crc, 8'h00);  // LEN_H
            sb4_crc = calc_crc8(sb4_crc, 8'h01);  // LEN_L
            sb4_crc = calc_crc8(sb4_crc, 8'h02);  // preset=2

            fork
                send_packet_timed(8'h0F, 16'd1, 8'h02, sb4_crc, 20);
                recv_packet_timed(20);
            join

            if (resp_cmd !== 8'h0F) begin
                $display("FAIL: SET_BAUD preset=2 resp cmd: 0x%02X, expected 0x0F", resp_cmd);
                errors = errors + 1;
            end
            if (resp_status_byte !== 8'h02) begin
                $display("FAIL: SET_BAUD preset=2 status: 0x%02X, expected 0x02 (ERR_CMD)", resp_status_byte);
                errors = errors + 1;
            end
            // Verify CPB unchanged (still 20 from preset=0 set in Test 21)
            if (uut.uart_clks_per_bit !== 8'd20) begin
                $display("FAIL: SET_BAUD preset=2: CPB changed to %0d, should remain 20", uut.uart_clks_per_bit);
                errors = errors + 1;
            end
            if (uut.current_baud_preset !== 2'd0) begin
                $display("FAIL: SET_BAUD preset=2: baud_preset changed to %0d, should remain 0", uut.current_baud_preset);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 23: Baud watchdog auto-reset
        // Switch to preset 1 (6M, CPB=10), then wait for watchdog
        // to expire (~2^25 clks), verify FPGA returns to default baud
        // ============================================================
        $display("  Test 23: Baud watchdog auto-reset...");
        begin
            reg [7:0] sb5_crc;
            sb5_crc = 8'd0;
            sb5_crc = calc_crc8(sb5_crc, 8'h0F);  // CMD
            sb5_crc = calc_crc8(sb5_crc, 8'h00);  // LEN_H
            sb5_crc = calc_crc8(sb5_crc, 8'h01);  // LEN_L
            sb5_crc = calc_crc8(sb5_crc, 8'h01);  // preset=1 (6M)

            fork
                send_packet_timed(8'h0F, 16'd1, 8'h01, sb5_crc, 20);
                recv_packet_timed(20);
            join

            if (resp_status_byte !== 8'h00) begin
                $display("FAIL: SET_BAUD preset=1 status: 0x%02X, expected 0x00", resp_status_byte);
                errors = errors + 1;
            end
        end

        // Wait for baud switch to apply
        repeat (CLKS_PER_BIT * 20) @(posedge clk);

        // Verify we're at CPB=10
        if (uut.uart_clks_per_bit !== 8'd10) begin
            $display("FAIL: Watchdog setup: CPB=%0d, expected 10", uut.uart_clks_per_bit);
            errors = errors + 1;
        end

        // Force watchdog to near-overflow by setting counter directly
        // 2^30 = 1_073_741_824 cycles (~18s at 60MHz), too slow for sim.
        // Instead, force the counter to near-max and wait a few cycles.
        force uut.baud_watchdog_cnt = 30'h3FFFFFF0;
        repeat (4) @(posedge clk);
        release uut.baud_watchdog_cnt;

        // Wait for watchdog to count up and expire (needs ~16 more cycles)
        repeat (40) @(posedge clk);

        // Verify FPGA reverted to default baud
        if (uut.uart_clks_per_bit !== 8'd0) begin
            $display("FAIL: Watchdog: CPB=%0d after timeout, expected 0 (default)", uut.uart_clks_per_bit);
            errors = errors + 1;
        end
        if (uut.current_baud_preset !== 2'd0) begin
            $display("FAIL: Watchdog: baud_preset=%0d after timeout, expected 0", uut.current_baud_preset);
            errors = errors + 1;
        end

        // Verify PING works at default baud after watchdog reset
        // uart_clks_per_bit=0 → active_cpb=DEFAULT_CPB=CLKS_PER_BIT (32 in testbench)
        $display("  Test 23b: PING after watchdog reset...");
        begin
            reg [7:0] sb5_ping_crc;
            sb5_ping_crc = 8'd0;
            sb5_ping_crc = calc_crc8(sb5_ping_crc, 8'h01);
            sb5_ping_crc = calc_crc8(sb5_ping_crc, 8'h00);
            sb5_ping_crc = calc_crc8(sb5_ping_crc, 8'h00);

            fork
                send_packet_timed(8'h01, 16'd0, 8'h00, sb5_ping_crc, CLKS_PER_BIT);
                recv_packet_timed(CLKS_PER_BIT);
            join
            if (resp_cmd !== 8'h01 || resp_status_byte !== 8'h00) begin
                $display("FAIL: PING after watchdog: cmd=0x%02X status=0x%02X", resp_cmd, resp_status_byte);
                errors = errors + 1;
            end
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Test 24: WRITE_SECTOR with count=10 (multi-write, >8 banks)
        // Payload: LBA(4) + COUNT(2) + DATA(10*512) = 5126 bytes
        // Verifies 16-bank FIFO with bank wrap-around for >8 sectors
        // ============================================================
        $display("  Test 24: WRITE_SECTOR count=10 (multi-write, 10 sectors)...");
        wr_capture_ptr = 13'd0;
        begin
            integer s, i;
            // Fill tx_large_payload: [LBA(4)] [COUNT(2)] [DATA_0..DATA_9]
            tx_large_payload[0] = 8'h00; // LBA = 0x300
            tx_large_payload[1] = 8'h00;
            tx_large_payload[2] = 8'h03;
            tx_large_payload[3] = 8'h00;
            tx_large_payload[4] = 8'h00; // COUNT = 10
            tx_large_payload[5] = 8'h0A;
            for (s = 0; s < 10; s = s + 1)
                for (i = 0; i < 512; i = i + 1)
                    tx_large_payload[6 + s * 512 + i] = (i * 3 + s * 17 + 8'h55) & 8'hFF;

            fork
                // Thread 1: Send command
                begin
                    send_packet_auto(8'h04, 16'd5126);
                end

                // Thread 2: Receive response (parallel with send — early dispatch
                // causes resp_valid before entire packet is sent)
                begin
                    // Wait for TX start bit with large timeout
                    begin : wait_mw10_bridge_resp
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 12000; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (uart_tx_pin == 1'b0) disable wait_mw10_bridge_resp;
                        end
                    end
                    // Now start bit is active — receive the response
                    begin
                        integer i;
                        // Middle of start bit
                        repeat (CLKS_PER_BIT / 2) @(posedge clk);
                        for (i = 0; i < 8; i = i + 1) begin
                            repeat (CLKS_PER_BIT) @(posedge clk);
                            resp_header[i] = uart_tx_pin;
                        end
                        repeat (CLKS_PER_BIT) @(posedge clk); // stop bit
                    end
                    // Rest of response uses normal recv
                    uart_recv_byte; resp_cmd = rx_captured;
                    uart_recv_byte; resp_status_byte = rx_captured;
                    uart_recv_byte; resp_len[15:8] = rx_captured;
                    uart_recv_byte; resp_len[7:0] = rx_captured;
                    begin
                        integer j;
                        for (j = 0; j < resp_len && j < 512; j = j + 1) begin
                            uart_recv_byte;
                            resp_payload[j] = rx_captured;
                        end
                    end
                    uart_recv_byte; resp_crc = rx_captured;
                    resp_payload_cnt = resp_len;
                end

                // Thread 3: Mock eMMC controller — multi-write handshake for 10 sectors
                begin
                    // Wait for cmd_valid clear
                    begin : wait_mw10_clear
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 20; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (!emmc_cmd_valid) disable wait_mw10_clear;
                        end
                    end
                    // Wait for NEW cmd_valid (first sector ready)
                    begin : wait_mw10_cmd
                        integer cnt;
                        for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 6000; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (emmc_cmd_valid) disable wait_mw10_cmd;
                        end
                    end
                    if (emmc_cmd_id !== 8'h04) begin
                        $display("FAIL: mw10 cmd_id: 0x%02X, expected 0x04", emmc_cmd_id);
                        errors = errors + 1;
                    end
                    if (emmc_cmd_count !== 16'h000A) begin
                        $display("FAIL: mw10 count: 0x%04X, expected 0x000A", emmc_cmd_count);
                        errors = errors + 1;
                    end

                    // Ack first sector
                    repeat (20) @(posedge clk);
                    emmc_wr_sector_ack <= 1'b1;
                    @(posedge clk);
                    emmc_wr_sector_ack <= 1'b0;

                    // Ack remaining 9 sectors
                    begin : mw10_ack_loop
                        integer sec;
                        for (sec = 1; sec < 10; sec = sec + 1) begin
                            // Wait for wr_sector_valid to drop (bridge clears on ack)
                            begin : wait_mw10_drop
                                integer cnt;
                                for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 100; cnt = cnt + 1) begin
                                    @(posedge clk);
                                    if (!emmc_wr_sector_valid) disable wait_mw10_drop;
                                end
                            end
                            // Wait for wr_sector_valid to rise (next sector ready)
                            begin : wait_mw10_sec
                                integer cnt;
                                for (cnt = 0; cnt < CLKS_PER_BIT * 10 * 600; cnt = cnt + 1) begin
                                    @(posedge clk);
                                    if (emmc_wr_sector_valid) disable wait_mw10_sec;
                                end
                            end
                            repeat (20) @(posedge clk);
                            emmc_wr_sector_ack <= 1'b1;
                            @(posedge clk);
                            emmc_wr_sector_ack <= 1'b0;
                        end
                    end

                    // Send final resp_valid (STATUS_OK)
                    repeat (50) @(posedge clk);
                    emmc_resp_status = 8'h00;
                    emmc_resp_valid <= 1'b1;
                    @(posedge clk);
                    emmc_resp_valid <= 1'b0;
                end
            join
        end

        // Verify response
        if (resp_header !== 8'h55) begin
            $display("FAIL: mw10 resp header: 0x%02X, expected 0x55 (timeout?)", resp_header);
            errors = errors + 1;
        end
        else if (resp_cmd !== 8'h04) begin
            $display("FAIL: mw10 resp cmd: 0x%02X, expected 0x04", resp_cmd);
            errors = errors + 1;
        end
        else if (resp_status_byte !== 8'h00) begin
            $display("FAIL: mw10 status: 0x%02X, expected 0x00 (OK)", resp_status_byte);
            errors = errors + 1;
        end

        // Verify captured data for all 10 sectors
        begin
            integer s, k;
            reg [7:0] wr_exp;
            reg wr_all_ok;
            wr_all_ok = 1;
            for (s = 0; s < 10; s = s + 1) begin
                for (k = 0; k < 512; k = k + 1) begin
                    wr_exp = (k * 3 + s * 17 + 8'h55) & 8'hFF;
                    if (wr_capture_mem[s * 512 + k] !== wr_exp) begin
                        if (wr_all_ok)
                            $display("FAIL: mw10 sector%0d[%0d]=0x%02X, expected 0x%02X",
                                     s, k, wr_capture_mem[s * 512 + k], wr_exp);
                        wr_all_ok = 0;
                    end
                end
            end
            if (!wr_all_ok)
                errors = errors + 1;
        end

        repeat (CLKS_PER_BIT * 4) @(posedge clk);

        // ============================================================
        // Results
        // ============================================================
        repeat (CLKS_PER_BIT * 4) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_uart_bridge");
        else
            $display("[FAIL] tb_uart_bridge (%0d errors)", errors);
        $finish(errors != 0);
    end

    // Write capture for WRITE_SECTOR verification (up to 16 sectors)
    reg [7:0] wr_capture_mem [0:8191];
    reg [12:0] wr_capture_ptr;
    always @(posedge clk) begin
        if (!rst_n)
            wr_capture_ptr <= 13'd0;
        else if (emmc_wr_en) begin
            wr_capture_mem[wr_capture_ptr] <= emmc_wr_data;
            wr_capture_ptr <= wr_capture_ptr + 1'b1;
        end
    end

    // Reactive data provider for READ_SECTOR test:
    // Drive emmc_rd_data based on emmc_rd_addr with 1-cycle latency (mimics BRAM)
    always @(posedge clk)
        if (rst_n)
            emmc_rd_data <= (emmc_rd_addr * 5 + 9'h37) & 8'hFF;

endmodule
