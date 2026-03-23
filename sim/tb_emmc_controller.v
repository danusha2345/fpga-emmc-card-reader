// Testbench: eMMC Controller — full integration test
// Tests init sequence and single-sector read with a stub eMMC device model
// that responds on CMD and DAT0 lines

`timescale 1ns / 1ps

module tb_emmc_controller;

    reg        clk;
    reg        rst_n;

    // Physical eMMC pins
    wire       emmc_clk;
    wire       emmc_rstn;
    wire       emmc_cmd_io;
    wire       emmc_dat0_io;

    // Command interface
    reg        cmd_valid;
    reg  [7:0] cmd_id;
    reg [31:0] cmd_lba;
    reg [15:0] cmd_count;
    wire       cmd_ready;
    wire [7:0] resp_status;
    wire       resp_valid;

    // Sector buffer read (UART side)
    reg  [8:0] uart_rd_addr;
    wire [7:0] uart_rd_data;
    wire       rd_sector_ready;
    reg        rd_sector_ack;

    // Sector buffer write (UART side)
    reg  [7:0] uart_wr_data;
    reg  [8:0] uart_wr_addr;
    reg        uart_wr_en;
    reg        uart_wr_sector_valid;
    reg  [3:0] uart_wr_bank;
    wire       wr_sector_ack;

    // Info outputs
    wire [127:0] cid;
    wire [127:0] csd;
    wire         info_valid;
    wire         active;
    wire         ready;
    wire         error;
    wire [31:0]  card_status;
    wire [127:0] raw_resp_data;

    emmc_controller #(
        .CLK_FREQ(60_000_000)
    ) uut (
        .clk               (clk),
        .rst_n             (rst_n),
        .emmc_clk          (emmc_clk),
        .emmc_rstn         (emmc_rstn),
        .emmc_cmd_io       (emmc_cmd_io),
        .emmc_dat0_io      (emmc_dat0_io),
        .cmd_valid         (cmd_valid),
        .cmd_id            (cmd_id),
        .cmd_lba           (cmd_lba),
        .cmd_count         (cmd_count),
        .cmd_ready         (cmd_ready),
        .resp_status       (resp_status),
        .resp_valid        (resp_valid),
        .uart_rd_addr      (uart_rd_addr),
        .uart_rd_data      (uart_rd_data),
        .rd_sector_ready   (rd_sector_ready),
        .rd_sector_ack     (rd_sector_ack),
        .uart_wr_data      (uart_wr_data),
        .uart_wr_addr      (uart_wr_addr),
        .uart_wr_en        (uart_wr_en),
        .uart_wr_sector_valid (uart_wr_sector_valid),
        .uart_wr_bank      (uart_wr_bank),
        .wr_sector_ack     (wr_sector_ack),
        .cid               (cid),
        .csd               (csd),
        .info_valid        (info_valid),
        .card_status       (card_status),
        .raw_resp_data     (raw_resp_data),
        .active            (active),
        .ready             (ready),
        .error             (error),
        .dbg_init_state    (),
        .dbg_mc_state      (),
        .dbg_cmd_pin       (),
        .dbg_dat0_pin      (),
        .dbg_cmd_fsm       (),
        .dbg_dat_fsm       (),
        .dbg_partition     (),
        .dbg_use_fast_clk  (),
        .dbg_reinit_pending(),
        .dbg_err_cmd_timeout(),
        .dbg_err_cmd_crc   (),
        .dbg_err_dat_rd    (),
        .dbg_err_dat_wr    (),
        .dbg_init_retry_cnt(),
        .dbg_clk_preset    ()
    );

    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    integer errors = 0;

    // =========================================================
    // Stub eMMC Device
    // =========================================================

    reg        cmd_card_out;
    reg        cmd_card_oe;
    reg        card_dat0_out;
    reg        card_dat0_oe;

    assign emmc_cmd_io  = cmd_card_oe ? cmd_card_out : 1'bz;
    assign emmc_dat0_io = card_dat0_oe ? card_dat0_out : 1'bz;

    pullup (emmc_cmd_io);
    pullup (emmc_dat0_io);

    // Detect eMMC clock edges
    reg emmc_clk_prev;
    wire emmc_clk_posedge = emmc_clk && !emmc_clk_prev;
    wire emmc_clk_negedge = !emmc_clk && emmc_clk_prev;
    always @(posedge clk) emmc_clk_prev <= emmc_clk;

    // CRC-7 function
    function [6:0] calc_crc7;
        input [39:0] data;
        integer i;
        reg [6:0] c;
        reg       fb;
        begin
            c = 7'd0;
            for (i = 39; i >= 0; i = i - 1) begin
                fb = c[6] ^ data[i];
                c[6] = c[5]; c[5] = c[4]; c[4] = c[3];
                c[3] = c[2] ^ fb;
                c[2] = c[1]; c[1] = c[0]; c[0] = fb;
            end
            calc_crc7 = c;
        end
    endfunction

    // CRC-16 bit-by-bit function
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

    // --- Card CMD FSM ---
    reg [47:0]  card_rx_shift;
    reg [7:0]   card_rx_cnt;
    reg         card_rx_active;
    reg         card_rx_done;
    reg [135:0] card_tx_shift;
    reg [7:0]   card_tx_cnt;
    reg [7:0]   card_tx_len;
    reg         card_tx_active;
    reg         card_tx_pending;

    // Track which CMD was received (for DAT0 trigger)
    reg [5:0]   last_cmd_idx;
    reg [31:0]  last_cmd_arg;
    reg         cmd17_received;  // trigger DAT0 read data
    reg         cmd18_received;  // trigger multi-block DAT0 read
    reg         cmd24_received;  // trigger DAT0 write (host->card)
    reg         cmd25_received;  // trigger multi-block DAT0 write
    reg         cmd12_received;  // stop multi-block transmission
    reg         cmd8_received;   // trigger ExtCSD read data on DAT0
    reg         cmd6_received;   // trigger switch busy on DAT0
    reg         multi_dat_active; // multi-block read in progress
    reg         multi_wr_active;  // multi-block write in progress
    reg [31:0]  card_sector_lba; // current sector LBA for data pattern

    // Write reception storage
    reg [7:0]   card_wr_mem [0:511]; // received data from host
    reg         card_wr_crc_ok;      // CRC match flag after write
    reg         force_wr_crc_err;    // Test: force write CRC status 101
    reg         force_rd_crc_err;    // Test: force read data corruption
    reg         force_cmd_crc_err;   // Test: force CMD response CRC-7 error
    reg         cmd38_received;      // CMD38 ERASE received
    reg [31:0]  last_cmd38_arg;      // CMD38 argument (0=normal, 0x80000000=secure)
    reg [7:0]   switch_busy_cnt;     // CMD6 switch busy counter
    reg [7:0]   switch_busy_limit;   // How many eMMC clks to hold busy
    reg         force_switch_no_release; // Test: keep DAT0 busy forever

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
        end else if (emmc_clk_posedge) begin
            cmd_card_oe  <= 1'b0;
            cmd_card_out <= 1'b1;
            card_rx_done <= 1'b0;

            if (card_tx_active) begin
                cmd_card_oe  <= 1'b1;
                cmd_card_out <= card_tx_shift[135];
                card_tx_shift <= {card_tx_shift[134:0], 1'b1};
                card_tx_cnt  <= card_tx_cnt + 1'b1;
                if (card_tx_cnt == card_tx_len - 1)
                    card_tx_active <= 1'b0;
            end else if (card_tx_pending) begin
                card_tx_active  <= 1'b1;
                card_tx_pending <= 1'b0;
            end else if (card_rx_active) begin
                card_rx_shift <= {card_rx_shift[46:0], emmc_cmd_io};
                card_rx_cnt   <= card_rx_cnt + 1'b1;
                if (card_rx_cnt == 8'd47) begin
                    card_rx_active <= 1'b0;
                    card_rx_done   <= 1'b1;
                end
            end else begin
                if (emmc_cmd_io === 1'b0) begin
                    card_rx_active <= 1'b1;
                    card_rx_shift  <= {47'd0, 1'b0};
                    card_rx_cnt    <= 8'd1;
                end
            end
        end
    end

    // Card response generation — fires once per card_rx_done rising edge
    reg card_resp_triggered;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_cmd_idx        <= 0;
            last_cmd_arg        <= 0;
            cmd17_received      <= 0;
            cmd18_received      <= 0;
            cmd24_received      <= 0;
            cmd25_received      <= 0;
            cmd12_received      <= 0;
            cmd8_received       <= 0;
            cmd6_received       <= 0;
            cmd38_received      <= 0;
            last_cmd38_arg      <= 0;
            card_resp_triggered <= 0;
        end else begin
            // cmd signals are level, cleared by DAT0 FSM
            if (dat_state != DAT_IDLE) begin
                cmd17_received <= 1'b0;
                cmd18_received <= 1'b0;
                cmd24_received <= 1'b0;
                cmd25_received <= 1'b0;
                cmd8_received  <= 1'b0;
                cmd6_received  <= 1'b0;
                cmd38_received <= 1'b0;
            end
            if (card_rx_done && !card_resp_triggered) begin
                card_resp_triggered <= 1'b1;
                last_cmd_idx <= card_rx_shift[45:40];
                last_cmd_arg <= card_rx_shift[39:8];

                case (card_rx_shift[45:40])
                    6'd0: begin
                        // CMD0: no response
                    end
                    6'd1: begin
                        // CMD1: R3 response (OCR with ready)
                        card_tx_shift <= {1'b0, 1'b0, 6'b111111, 32'hC0FF8080, 7'b1111111, 1'b1, 88'd0};
                        card_tx_len   <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt   <= 0;
                    end
                    6'd2: begin
                        // CMD2: R2 (CID)
                        card_tx_shift <= {1'b0, 1'b0, 6'b111111,
                                          128'h11223344_55667788_99AABBCC_DDEEFF00};
                        card_tx_len   <= 8'd136;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt   <= 0;
                    end
                    6'd9: begin
                        // CMD9: R2 (CSD)
                        card_tx_shift <= {1'b0, 1'b0, 6'b111111,
                                          128'hAABBCCDD_EEFF0011_22334455_66778899};
                        card_tx_len   <= 8'd136;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt   <= 0;
                    end
                    6'd12: begin
                        // CMD12: R1 response (stop transmission)
                        begin
                            reg [6:0] c7;
                            c7 = calc_crc7({1'b0, 1'b0, 6'd12, 32'h0000_0900});
                            card_tx_shift <= {1'b0, 1'b0, 6'd12, 32'h0000_0900, c7, 1'b1, 88'd0};
                        end
                        card_tx_len    <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt    <= 0;
                        cmd12_received <= 1'b1;
                    end
                    6'd17: begin
                        // CMD17: R1 + data on DAT0
                        begin
                            reg [6:0] c7;
                            c7 = calc_crc7({1'b0, 1'b0, 6'd17, 32'h0000_0900});
                            if (force_cmd_crc_err) c7 = c7 ^ 7'h01;
                            card_tx_shift <= {1'b0, 1'b0, 6'd17, 32'h0000_0900, c7, 1'b1, 88'd0};
                        end
                        card_tx_len    <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt    <= 0;
                        cmd17_received <= 1'b1;
                        cmd12_received <= 1'b0; // clear stale CMD12 from previous multi-block
                    end
                    6'd18: begin
                        // CMD18: R1 + multi-block data on DAT0
                        begin
                            reg [6:0] c7;
                            c7 = calc_crc7({1'b0, 1'b0, 6'd18, 32'h0000_0900});
                            if (force_cmd_crc_err) c7 = c7 ^ 7'h01;
                            card_tx_shift <= {1'b0, 1'b0, 6'd18, 32'h0000_0900, c7, 1'b1, 88'd0};
                        end
                        card_tx_len    <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt    <= 0;
                        cmd18_received <= 1'b1;
                        cmd12_received <= 1'b0;
                    end
                    6'd24: begin
                        // CMD24: R1, host will write data on DAT0
                        begin
                            reg [6:0] c7;
                            c7 = calc_crc7({1'b0, 1'b0, 6'd24, 32'h0000_0900});
                            if (force_cmd_crc_err) c7 = c7 ^ 7'h01;
                            card_tx_shift <= {1'b0, 1'b0, 6'd24, 32'h0000_0900, c7, 1'b1, 88'd0};
                        end
                        card_tx_len    <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt    <= 0;
                        cmd24_received <= 1'b1;
                        cmd12_received <= 1'b0;
                    end
                    6'd25: begin
                        // CMD25: R1, multi-block write on DAT0
                        begin
                            reg [6:0] c7;
                            c7 = calc_crc7({1'b0, 1'b0, 6'd25, 32'h0000_0900});
                            if (force_cmd_crc_err) c7 = c7 ^ 7'h01;
                            card_tx_shift <= {1'b0, 1'b0, 6'd25, 32'h0000_0900, c7, 1'b1, 88'd0};
                        end
                        card_tx_len    <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt    <= 0;
                        cmd25_received <= 1'b1;
                        cmd12_received <= 1'b0;
                    end
                    6'd6: begin
                        // CMD6 SWITCH: R1 + trigger DAT0 busy
                        begin
                            reg [6:0] c7;
                            c7 = calc_crc7({1'b0, 1'b0, 6'd6, 32'h0000_0900});
                            card_tx_shift <= {1'b0, 1'b0, 6'd6, 32'h0000_0900, c7, 1'b1, 88'd0};
                        end
                        card_tx_len    <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt    <= 0;
                        cmd6_received  <= 1'b1;
                    end
                    6'd38: begin
                        // CMD38 ERASE: R1 + trigger DAT0 busy (reuse switch busy)
                        begin
                            reg [6:0] c7;
                            c7 = calc_crc7({1'b0, 1'b0, 6'd38, 32'h0000_0900});
                            card_tx_shift <= {1'b0, 1'b0, 6'd38, 32'h0000_0900, c7, 1'b1, 88'd0};
                        end
                        card_tx_len    <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt    <= 0;
                        cmd38_received <= 1'b1;
                        last_cmd38_arg <= card_rx_shift[39:8]; // capture CMD38 argument directly from shift register
                    end
                    6'd8: begin
                        // CMD8 SEND_EXT_CSD: R1 + trigger DAT0 data
                        begin
                            reg [6:0] c7;
                            c7 = calc_crc7({1'b0, 1'b0, 6'd8, 32'h0000_0900});
                            card_tx_shift <= {1'b0, 1'b0, 6'd8, 32'h0000_0900, c7, 1'b1, 88'd0};
                        end
                        card_tx_len    <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt    <= 0;
                        cmd8_received  <= 1'b1;
                        cmd12_received <= 1'b0;
                    end
                    default: begin
                        // Generic R1 response
                        begin
                            reg [6:0] c7;
                            c7 = calc_crc7({1'b0, 1'b0, card_rx_shift[45:40], 32'h0000_0900});
                            card_tx_shift <= {1'b0, 1'b0, card_rx_shift[45:40], 32'h0000_0900, c7, 1'b1, 88'd0};
                        end
                        card_tx_len    <= 8'd48;
                        card_tx_pending <= 1'b1;
                        card_tx_cnt    <= 0;
                    end
                endcase
            end
            if (!card_rx_done)
                card_resp_triggered <= 1'b0;
        end
    end

    // --- Card DAT0 FSM: sends 512-byte data block after CMD17 ---
    reg [3:0]  dat_state;
    reg [12:0] dat_bit_cnt;
    reg [8:0]  dat_byte_idx;
    reg [7:0]  dat_byte;
    reg [2:0]  dat_bit_pos;
    reg [15:0] dat_crc;
    reg [15:0] dat_crc_shift;
    reg [12:0] dat_wait_cnt;

    localparam DAT_IDLE       = 4'd0;
    localparam DAT_WAIT       = 4'd1;
    localparam DAT_START      = 4'd2;
    localparam DAT_DATA       = 4'd3;
    localparam DAT_CRC        = 4'd4;
    localparam DAT_END        = 4'd5;
    localparam DAT_WR_WAIT    = 4'd6;
    localparam DAT_WR_DATA    = 4'd7;
    localparam DAT_WR_CRC     = 4'd8;
    localparam DAT_WR_END_BIT = 4'd9;
    localparam DAT_WR_STAT    = 4'd10;
    localparam DAT_WR_RELEASE = 4'd11;
    localparam DAT_SWITCH_BUSY = 4'd12;

    // DAT0 driven on falling edge so data is stable when host reads on rising edge.
    // Also handles write reception (sampling host data on negedge, which is stable
    // since host drives on posedge via clk_en).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            card_dat0_out  <= 1'b1;
            card_dat0_oe   <= 1'b0;
            dat_state      <= DAT_IDLE;
            dat_bit_cnt    <= 0;
            dat_byte_idx   <= 0;
            dat_byte       <= 0;
            dat_bit_pos    <= 0;
            dat_crc        <= 0;
            dat_crc_shift  <= 0;
            dat_wait_cnt   <= 0;
            multi_dat_active <= 0;
            multi_wr_active  <= 0;
            card_sector_lba  <= 0;
            card_wr_crc_ok   <= 0;
            switch_busy_cnt  <= 0;
        end else if (emmc_clk_negedge) begin
            card_dat0_oe  <= 1'b0;
            card_dat0_out <= 1'b1;

            case (dat_state)
                DAT_IDLE: begin
                    if (cmd17_received) begin
                        card_sector_lba  <= last_cmd_arg;
                        multi_dat_active <= 1'b0;
                        dat_state <= DAT_WAIT;
                    end else if (cmd18_received) begin
                        card_sector_lba  <= last_cmd_arg;
                        multi_dat_active <= 1'b1;
                        dat_state <= DAT_WAIT;
                    end else if (cmd24_received) begin
                        card_sector_lba <= last_cmd_arg;
                        multi_wr_active <= 1'b0;
                        dat_state <= DAT_WR_WAIT;
                    end else if (cmd25_received) begin
                        card_sector_lba <= last_cmd_arg;
                        multi_wr_active <= 1'b1;
                        dat_state <= DAT_WR_WAIT;
                    end else if (cmd8_received) begin
                        $display("  DEBUG: DAT_IDLE: cmd8_received! Setting lba=0xEE");
                        card_sector_lba  <= 32'h000000EE; // ExtCSD pattern base
                        multi_dat_active <= 1'b0;
                        dat_state <= DAT_WAIT;
                    end else if (cmd6_received) begin
                        switch_busy_cnt <= 0;
                        dat_state <= DAT_SWITCH_BUSY;
                    end else if (cmd38_received) begin
                        switch_busy_cnt <= 0;
                        dat_state <= DAT_SWITCH_BUSY;
                    end
                end

                DAT_WAIT: begin
                    dat_wait_cnt <= dat_wait_cnt + 1'b1;
                    if (dat_wait_cnt == 13'd100) begin
                        dat_wait_cnt <= 0;
                        dat_state    <= DAT_START;
                    end
                end

                DAT_START: begin
                    card_dat0_oe  <= 1'b1;
                    card_dat0_out <= 1'b0;  // start bit
                    dat_byte_idx  <= 0;
                    dat_byte      <= card_sector_lba[7:0];
                    dat_bit_pos   <= 3'd7;
                    dat_bit_cnt   <= 0;
                    dat_crc       <= 16'd0;
                    dat_state     <= DAT_DATA;
                end

                DAT_DATA: begin
                    card_dat0_oe  <= 1'b1;
                    if (force_rd_crc_err && dat_byte_idx == 0 && dat_bit_pos == 3'd7)
                        card_dat0_out <= ~dat_byte[7]; // corrupt first bit
                    else
                        card_dat0_out <= dat_byte[7]; // MSB first
                    dat_crc <= crc16_bit(dat_crc, dat_byte[7]);

                    if (dat_bit_pos == 3'd0) begin
                        dat_byte_idx <= dat_byte_idx + 1'b1;
                        dat_bit_pos  <= 3'd7;
                        dat_byte <= dat_byte_idx[7:0] + 1'b1 + card_sector_lba[7:0];
                        if (dat_byte_idx == 9'd511) begin
                            dat_crc_shift <= crc16_bit(dat_crc, dat_byte[7]);
                            dat_bit_cnt   <= 0;
                            dat_state     <= DAT_CRC;
                        end
                    end else begin
                        dat_byte    <= {dat_byte[6:0], 1'b0};
                        dat_bit_pos <= dat_bit_pos - 1'b1;
                    end
                end

                DAT_CRC: begin
                    card_dat0_oe  <= 1'b1;
                    card_dat0_out <= dat_crc_shift[15];
                    dat_crc_shift <= {dat_crc_shift[14:0], 1'b0};
                    dat_bit_cnt   <= dat_bit_cnt + 1'b1;
                    if (dat_bit_cnt == 13'd15) begin
                        $display("  DEBUG DAT_CRC done: card_crc=0x%04X, lba=0x%08X", dat_crc, card_sector_lba);
                        dat_state <= DAT_END;
                    end
                end

                DAT_END: begin
                    card_dat0_oe  <= 1'b1;
                    card_dat0_out <= 1'b1;  // end bit
                    if (multi_dat_active && !cmd12_received) begin
                        card_sector_lba <= card_sector_lba + 1'b1;
                        dat_wait_cnt    <= 0;
                        dat_state       <= DAT_WAIT;
                    end else begin
                        multi_dat_active <= 1'b0;
                        dat_state        <= DAT_IDLE;
                    end
                end

                // =========================================================
                // Write reception: host drives data on DAT0, card receives
                // =========================================================
                DAT_WR_WAIT: begin
                    // Wait for start bit from host (DAT0 low), or CMD12 abort
                    if (cmd12_received) begin
                        multi_wr_active <= 1'b0;
                        dat_state <= DAT_IDLE;
                    end else if (emmc_dat0_io === 1'b0) begin
                        dat_byte_idx <= 0;
                        dat_byte     <= 0;
                        dat_bit_pos  <= 3'd7;
                        dat_crc      <= 16'd0;
                        dat_bit_cnt  <= 0;
                        dat_state    <= DAT_WR_DATA;
                    end
                end

                DAT_WR_DATA: begin
                    // Receive data bit from host
                    dat_crc <= crc16_bit(dat_crc, emmc_dat0_io);
                    dat_byte <= {dat_byte[6:0], emmc_dat0_io};

                    if (dat_bit_pos == 3'd0) begin
                        card_wr_mem[dat_byte_idx] <= {dat_byte[6:0], emmc_dat0_io};
                        dat_byte_idx <= dat_byte_idx + 1'b1;
                        dat_bit_pos  <= 3'd7;
                        if (dat_byte_idx == 9'd511) begin
                            dat_bit_cnt   <= 0;
                            dat_crc_shift <= 0;
                            dat_state     <= DAT_WR_CRC;
                        end
                    end else begin
                        dat_bit_pos <= dat_bit_pos - 1'b1;
                    end
                end

                DAT_WR_CRC: begin
                    // Receive 16-bit CRC from host
                    dat_crc_shift <= {dat_crc_shift[14:0], emmc_dat0_io};
                    dat_bit_cnt   <= dat_bit_cnt + 1'b1;
                    if (dat_bit_cnt == 13'd15)
                        dat_state <= DAT_WR_END_BIT;
                end

                DAT_WR_END_BIT: begin
                    // Host sends end bit (1), skip it
                    dat_bit_cnt <= 0;
                    dat_state   <= DAT_WR_STAT;
                end

                DAT_WR_STAT: begin
                    // Drive CRC status response: start(0) + 010 + busy
                    card_dat0_oe <= 1'b1;
                    case (dat_bit_cnt[3:0])
                        4'd0: card_dat0_out <= 1'b0; // start bit
                        4'd1: card_dat0_out <= force_wr_crc_err ? 1'b1 : 1'b0;
                        4'd2: card_dat0_out <= force_wr_crc_err ? 1'b0 : 1'b1;
                        4'd3: card_dat0_out <= force_wr_crc_err ? 1'b1 : 1'b0;
                        default: card_dat0_out <= 1'b0; // busy
                    endcase
                    dat_bit_cnt <= dat_bit_cnt + 1'b1;
                    if (dat_bit_cnt == 13'd13)
                        dat_state <= DAT_WR_RELEASE;
                end

                DAT_WR_RELEASE: begin
                    card_dat0_oe  <= 1'b1;
                    card_dat0_out <= 1'b1; // release busy
                    card_wr_crc_ok <= (dat_crc_shift == dat_crc);
                    if (multi_wr_active && !cmd12_received) begin
                        card_sector_lba <= card_sector_lba + 1'b1;
                        dat_state <= DAT_WR_WAIT;
                    end else begin
                        multi_wr_active <= 1'b0;
                        dat_state <= DAT_IDLE;
                    end
                end

                DAT_SWITCH_BUSY: begin
                    card_dat0_oe  <= 1'b1;
                    card_dat0_out <= 1'b0; // hold DAT0 busy
                    switch_busy_cnt <= switch_busy_cnt + 1'b1;
                    if (switch_busy_cnt >= switch_busy_limit && !force_switch_no_release)
                        dat_state <= DAT_IDLE;
                end
            endcase
        end
    end

    // =========================================================
    // Test procedure
    // =========================================================

    // Watchdog
    initial begin
        #5_000_000_000;  // 5s (23 tests: +raw cmd)
        $display("FAIL: tb_emmc_controller - timeout");
        $finish(1);
    end




    // Capture info_valid pulse (it's only high for 1 cycle)
    reg info_valid_seen;
    reg [127:0] captured_cid;
    reg [127:0] captured_csd;
    always @(posedge clk) begin
        if (!rst_n) begin
            info_valid_seen <= 0;
            captured_cid <= 0;
            captured_csd <= 0;
        end else if (info_valid) begin
            info_valid_seen <= 1;
            captured_cid <= cid;
            captured_csd <= csd;
        end
    end

    initial begin
        rst_n              = 0;
        cmd_valid          = 0;
        cmd_id             = 0;
        cmd_lba            = 0;
        cmd_count          = 0;
        uart_rd_addr       = 0;
        uart_wr_data       = 0;
        uart_wr_addr       = 0;
        uart_wr_en         = 0;
        uart_wr_sector_valid = 0;
        uart_wr_bank       = 0;
        rd_sector_ack      = 0;
        force_wr_crc_err   = 0;
        force_rd_crc_err   = 0;
        force_cmd_crc_err  = 0;
        switch_busy_limit  = 8'd200;
        force_switch_no_release = 0;

        repeat (20) @(posedge clk);
        rst_n = 1;

        // ---- Test 1: Wait for initialization ----
        $display("  Waiting for eMMC init...");
        begin : init_wait
            integer cnt;
            for (cnt = 0; cnt < 150_000_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (ready) disable init_wait;
                if (error) begin
                    $display("FAIL: init error at cycle %0d", cnt);
                    errors = errors + 1;
                    disable init_wait;
                end
            end
            if (!ready && !error) begin
                $display("FAIL: init timeout");
                errors = errors + 1;
            end
        end

        if (ready) begin
            $display("  Init complete.");

            // Check info_valid was seen (it's a 1-cycle pulse)
            if (!info_valid_seen) begin
                $display("FAIL: info_valid pulse never seen");
                errors = errors + 1;
            end

            // Check CID
            if (captured_cid !== 128'h11223344_55667788_99AABBCC_DDEEFF00) begin
                $display("FAIL: CID mismatch: 0x%032X", captured_cid);
                errors = errors + 1;
            end

            // Check CSD
            if (captured_csd !== 128'hAABBCCDD_EEFF0011_22334455_66778899) begin
                $display("FAIL: CSD mismatch: 0x%032X", captured_csd);
                errors = errors + 1;
            end

            // ---- Test 2: Read single sector (CMD17) ----
            $display("  Test: READ_SECTOR LBA=0...");
            @(posedge clk);
            cmd_id    <= 8'h03;  // READ_SECTOR
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd1;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            // Wait for rd_sector_ready
            begin : sector_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable sector_wait;
                    if (resp_valid && resp_status != 8'h00) begin
                        $display("FAIL: read sector error: status=0x%02X", resp_status);
                        errors = errors + 1;
                        disable sector_wait;
                    end
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end
            // Ack sticky rd_sector_ready (pulse, then wait for resp_valid)
            rd_sector_ack <= 1'b1;
            @(posedge clk);
            rd_sector_ack <= 1'b0;

            // Wait for resp_valid (command completion)
            // Note: for single-block, resp_valid fires 1 cycle after rd_sector_ready
            // so it may already be asserted
            if (errors == 0) begin
                begin : resp_wait
                    integer cnt;
                    for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                        if (resp_valid) disable resp_wait;
                        @(posedge clk);
                        if (resp_valid) disable resp_wait;
                    end
                end

                if (resp_valid && resp_status == 8'h00) begin
                    $display("  Read sector completed OK.");
                    // Read first few bytes from sector buffer
                    // Data pattern: byte[i] = (i + LBA[7:0]) & 0xFF, so byte[0]=0, byte[1]=1, etc.
                    repeat (4) @(posedge clk);
                    uart_rd_addr <= 9'd0;
                    repeat (3) @(posedge clk); // BRAM read latency
                    if (uart_rd_data !== 8'h00) begin
                        $display("FAIL: sector[0] = 0x%02X, expected 0x00", uart_rd_data);
                        errors = errors + 1;
                    end
                    uart_rd_addr <= 9'd1;
                    repeat (3) @(posedge clk);
                    if (uart_rd_data !== 8'h01) begin
                        $display("FAIL: sector[1] = 0x%02X, expected 0x01", uart_rd_data);
                        errors = errors + 1;
                    end
                    uart_rd_addr <= 9'd255;
                    repeat (3) @(posedge clk);
                    if (uart_rd_data !== 8'hFF) begin
                        $display("FAIL: sector[255] = 0x%02X, expected 0xFF", uart_rd_data);
                        errors = errors + 1;
                    end
                end else begin
                    $display("FAIL: read completion: status=0x%02X valid=%0d", resp_status, resp_valid);
                    errors = errors + 1;
                end
            end

            // ---- Test 3: Read single sector with non-zero LBA ----
            $display("  Test: READ_SECTOR LBA=42...");
            @(posedge clk);
            cmd_id    <= 8'h03;
            cmd_lba   <= 32'd42;
            cmd_count <= 16'd1;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : sector_wait3
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable sector_wait3;
                    if (resp_valid && resp_status != 8'h00) begin
                        $display("FAIL: read LBA=42 error: status=0x%02X", resp_status);
                        errors = errors + 1;
                        disable sector_wait3;
                    end
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: rd_sector_ready timeout (LBA=42)");
                    errors = errors + 1;
                end
            end
            // Ack sticky rd_sector_ready (pulse, then wait for resp_valid)
            rd_sector_ack <= 1'b1;
            @(posedge clk);
            rd_sector_ack <= 1'b0;

            begin
                begin : resp_wait3
                    integer cnt;
                    for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                        if (resp_valid) disable resp_wait3;
                        @(posedge clk);
                        if (resp_valid) disable resp_wait3;
                    end
                end

                if (resp_valid && resp_status == 8'h00) begin
                    $display("  Read LBA=42 completed OK.");
                    // Data pattern: byte[i] = (i + 42) & 0xFF
                    repeat (4) @(posedge clk);
                    uart_rd_addr <= 9'd0;
                    repeat (3) @(posedge clk);
                    if (uart_rd_data !== 8'h2A) begin
                        $display("FAIL: sector[0] LBA=42: 0x%02X, expected 0x2A", uart_rd_data);
                        errors = errors + 1;
                    end
                    uart_rd_addr <= 9'd1;
                    repeat (3) @(posedge clk);
                    if (uart_rd_data !== 8'h2B) begin
                        $display("FAIL: sector[1] LBA=42: 0x%02X, expected 0x2B", uart_rd_data);
                        errors = errors + 1;
                    end
                    uart_rd_addr <= 9'd214;
                    repeat (3) @(posedge clk);
                    // 214 + 42 = 256 => 0x00
                    if (uart_rd_data !== 8'h00) begin
                        $display("FAIL: sector[214] LBA=42: 0x%02X, expected 0x00", uart_rd_data);
                        errors = errors + 1;
                    end
                end else begin
                    $display("FAIL: read LBA=42 completion: status=0x%02X valid=%0d", resp_status, resp_valid);
                    errors = errors + 1;
                end
            end

            // ---- Test 4: Write single sector (CMD24) ----
            $display("  Test: WRITE_SECTOR LBA=0...");
            // Fill sector buffer bank 0 (UART always starts writing at bank 0)
            uart_wr_bank = 4'd0;
            begin : fill_buf
                integer i;
                for (i = 0; i < 512; i = i + 1)
                    uut.u_write_buf.mem_lo[{3'd0, i[8:0]}] = (i * 3 + 8'h42) & 8'hFF;
            end

            @(posedge clk);
            cmd_id    <= 8'h04;
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd1;
            cmd_valid            <= 1'b1;
            uart_wr_sector_valid <= 1'b1;
            @(posedge clk);
            cmd_valid            <= 1'b0;
            uart_wr_sector_valid <= 1'b0;

            begin : write_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable write_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: write resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00) begin
                $display("  Write sector completed OK.");
                // Verify card received correct data
                begin : verify_wr
                    integer i;
                    reg [7:0] expected;
                    reg wr_data_ok;
                    wr_data_ok = 1;
                    for (i = 0; i < 512; i = i + 1) begin
                        expected = (i * 3 + 8'h42) & 8'hFF;
                        if (card_wr_mem[i] !== expected) begin
                            if (wr_data_ok)
                                $display("FAIL: card_wr_mem[%0d]=0x%02X, expected 0x%02X",
                                         i, card_wr_mem[i], expected);
                            wr_data_ok = 0;
                        end
                    end
                    if (!wr_data_ok)
                        errors = errors + 1;
                end
                // Verify CRC was OK
                if (!card_wr_crc_ok) begin
                    $display("FAIL: write CRC mismatch in card stub");
                    errors = errors + 1;
                end
            end else if (resp_valid) begin
                $display("FAIL: write sector status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // ---- Test 5: Multi-block read (CMD18, count=2) ----
            $display("  Test: MULTI-BLOCK READ LBA=10, count=2...");
            @(posedge clk);
            cmd_id    <= 8'h03;
            cmd_lba   <= 32'd10;
            cmd_count <= 16'd2;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            // Wait for first sector
            begin : mb_wait1
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable mb_wait1;
                    if (resp_valid && resp_status != 8'h00) begin
                        $display("FAIL: multi-block sector 0 error: status=0x%02X", resp_status);
                        errors = errors + 1;
                        disable mb_wait1;
                    end
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: multi-block sector 0 rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end

            if (rd_sector_ready) begin
                // Ack sticky rd_sector_ready (allows controller to proceed to next sector)
                rd_sector_ack <= 1'b1;
                @(posedge clk);
                rd_sector_ack <= 1'b0;
                // Check first sector data: pattern byte[i] = (i + 10) & 0xFF
                repeat (4) @(posedge clk);
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h0A) begin
                    $display("FAIL: multi-block S0[0]=0x%02X, expected 0x0A", uart_rd_data);
                    errors = errors + 1;
                end
                uart_rd_addr <= 9'd246;
                repeat (3) @(posedge clk);
                // 246 + 10 = 256 => 0x00
                if (uart_rd_data !== 8'h00) begin
                    $display("FAIL: multi-block S0[246]=0x%02X, expected 0x00", uart_rd_data);
                    errors = errors + 1;
                end
            end

            // Wait for second sector
            begin : mb_wait2
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable mb_wait2;
                    if (resp_valid && resp_status != 8'h00) begin
                        $display("FAIL: multi-block sector 1 error: status=0x%02X", resp_status);
                        errors = errors + 1;
                        disable mb_wait2;
                    end
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: multi-block sector 1 rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end

            if (rd_sector_ready) begin
                // Ack sticky rd_sector_ready
                rd_sector_ack <= 1'b1;
                @(posedge clk);
                rd_sector_ack <= 1'b0;
                // Check second sector: pattern byte[i] = (i + 11) & 0xFF
                repeat (4) @(posedge clk);
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h0B) begin
                    $display("FAIL: multi-block S1[0]=0x%02X, expected 0x0B", uart_rd_data);
                    errors = errors + 1;
                end
                uart_rd_addr <= 9'd245;
                repeat (3) @(posedge clk);
                // 245 + 11 = 256 => 0x00
                if (uart_rd_data !== 8'h00) begin
                    $display("FAIL: multi-block S1[245]=0x%02X, expected 0x00", uart_rd_data);
                    errors = errors + 1;
                end
            end

            // Wait for CMD12 + final response
            begin : mb_resp_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable mb_resp_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: multi-block resp_valid timeout after CMD12");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00)
                $display("  Multi-block read completed OK.");
            else if (resp_valid) begin
                $display("FAIL: multi-block final status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // Wait for card DAT FSM to settle after multi-block
            // (card may still be sending sector 12 data before CMD12 arrives)
            begin : dat_settle
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (dat_state == DAT_IDLE) disable dat_settle;
                end
                $display("WARN: card DAT FSM did not return to IDLE");
            end

            // ---- Test 6: ExtCSD Read (CMD8) ----
            $display("  Test: EXT_CSD READ...");
            @(posedge clk);
            cmd_id    <= 8'h07;  // GET_EXT_CSD
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd1;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            // Wait for rd_sector_ready
            begin : ext_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable ext_wait;
                    if (resp_valid && resp_status != 8'h00) begin
                        $display("FAIL: ExtCSD error: status=0x%02X, dat_state=%0d, cmd8_received=%0b, cmd6_received=%0b",
                                 resp_status, dat_state, cmd8_received, cmd6_received);
                        errors = errors + 1;
                        disable ext_wait;
                    end
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: ExtCSD rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end

            if (rd_sector_ready) begin
                // Ack sticky rd_sector_ready
                rd_sector_ack <= 1'b1;
                @(posedge clk);
                rd_sector_ack <= 1'b0;
                $display("  ExtCSD read completed.");
                // Data pattern: byte[i] = (i + 0xEE) & 0xFF
                repeat (4) @(posedge clk);
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'hEE) begin
                    $display("FAIL: ExtCSD[0] = 0x%02X, expected 0xEE", uart_rd_data);
                    errors = errors + 1;
                end
                uart_rd_addr <= 9'd1;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'hEF) begin
                    $display("FAIL: ExtCSD[1] = 0x%02X, expected 0xEF", uart_rd_data);
                    errors = errors + 1;
                end
                uart_rd_addr <= 9'd18;
                repeat (3) @(posedge clk);
                // 18 + 0xEE = 256 => 0x00
                if (uart_rd_data !== 8'h00) begin
                    $display("FAIL: ExtCSD[18] = 0x%02X, expected 0x00", uart_rd_data);
                    errors = errors + 1;
                end
            end

            // Wait for resp_valid
            begin : ext_resp_wait
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable ext_resp_wait;
                end
            end
            if (resp_valid && resp_status == 8'h00)
                $display("  ExtCSD read OK.");
            else if (resp_valid) begin
                $display("FAIL: ExtCSD final status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // ---- Test 7: Partition Switch (CMD6) ----
            $display("  Test: PARTITION SWITCH (boot1)...");
            @(posedge clk);
            cmd_id    <= 8'h08;  // SET_PARTITION
            cmd_lba   <= {24'd0, 8'd2}; // boot1
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : sw_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable sw_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: partition switch resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00)
                $display("  Partition switch completed OK.");
            else if (resp_valid) begin
                $display("FAIL: partition switch status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // ---- Test 8: Write CRC Error ----
            $display("  Test: WRITE CRC ERROR...");
            force_wr_crc_err = 1;

            uart_wr_bank = 4'd0;
            begin : fill_buf8
                integer i;
                for (i = 0; i < 512; i = i + 1)
                    uut.u_write_buf.mem_lo[{3'd0, i[8:0]}] = (i * 3 + 8'h42) & 8'hFF;
            end

            @(posedge clk);
            cmd_id    <= 8'h04;
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd1;
            cmd_valid            <= 1'b1;
            uart_wr_sector_valid <= 1'b1;
            @(posedge clk);
            cmd_valid            <= 1'b0;
            uart_wr_sector_valid <= 1'b0;

            begin : wr_err_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable wr_err_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: write CRC error resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h03)
                $display("  Write CRC error correctly reported.");
            else if (resp_valid) begin
                $display("FAIL: write CRC error status=0x%02X, expected 0x03", resp_status);
                errors = errors + 1;
            end

            force_wr_crc_err = 0;

            // Wait for controller to return to ready
            begin : wr_err_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable wr_err_ready;
                end
            end

            // ---- Test 9: Read CRC Mismatch ----
            $display("  Test: READ CRC MISMATCH...");
            force_rd_crc_err = 1;

            @(posedge clk);
            cmd_id    <= 8'h03;
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd1;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : rd_err_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable rd_err_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: read CRC error resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h03)
                $display("  Read CRC mismatch correctly reported.");
            else if (resp_valid) begin
                $display("FAIL: read CRC error status=0x%02X, expected 0x03", resp_status);
                errors = errors + 1;
            end

            force_rd_crc_err = 0;

            // Wait for controller to return to ready
            begin : rd_err_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable rd_err_ready;
                end
            end

            // ---- Test 10: Erase (CMD35 → CMD36 → CMD38) ----
            $display("  Test: ERASE LBA=100, count=10...");
            @(posedge clk);
            cmd_id    <= 8'h05;  // ERASE
            cmd_lba   <= 32'd100;
            cmd_count <= 16'd10;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : erase_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable erase_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: erase resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00)
                $display("  Erase completed OK.");
            else if (resp_valid) begin
                $display("FAIL: erase status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // Wait for controller ready
            begin : erase_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable erase_ready;
                end
            end

            // ---- Test 11: Write ExtCSD (CMD6 SWITCH generic) ----
            $display("  Test: WRITE_EXT_CSD index=33 value=1...");
            @(posedge clk);
            cmd_id    <= 8'h09;  // WRITE_EXT_CSD
            cmd_lba   <= {16'd0, 8'd33, 8'd1}; // index=33 (CACHE_CTRL), value=1
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : wext_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable wext_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: write_ext_csd resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00)
                $display("  Write ExtCSD completed OK.");
            else if (resp_valid) begin
                $display("FAIL: write_ext_csd status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // ---- Test 12: READ with count=0 ----
            $display("  Test: READ count=0 (should return ERR_CMD)...");
            @(posedge clk);
            cmd_id    <= 8'h03;  // READ_SECTOR
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : read0_wait
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable read0_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: READ count=0 resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h02)
                $display("  READ count=0 correctly rejected (ERR_CMD).");
            else if (resp_valid) begin
                $display("FAIL: READ count=0 status=0x%02X, expected 0x02", resp_status);
                errors = errors + 1;
            end

            // Wait for controller ready
            begin : read0_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable read0_ready;
                end
            end

            // ---- Test 13: ERASE with count=0 ----
            $display("  Test: ERASE count=0 (should return ERR_CMD)...");
            @(posedge clk);
            cmd_id    <= 8'h05;  // ERASE
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : erase0_wait
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable erase0_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: ERASE count=0 resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h02)
                $display("  ERASE count=0 correctly rejected (ERR_CMD).");
            else if (resp_valid) begin
                $display("FAIL: ERASE count=0 status=0x%02X, expected 0x02", resp_status);
                errors = errors + 1;
            end

            // Wait for controller ready
            begin : erase0_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable erase0_ready;
                end
            end

            // ---- Test 14: WRITE with count=0 ----
            $display("  Test: WRITE count=0 (should return ERR_CMD)...");
            @(posedge clk);
            cmd_id    <= 8'h04;  // WRITE_SECTOR
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : write0_wait
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable write0_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: WRITE count=0 resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h02)
                $display("  WRITE count=0 correctly rejected (ERR_CMD).");
            else if (resp_valid) begin
                $display("FAIL: WRITE count=0 status=0x%02X, expected 0x02", resp_status);
                errors = errors + 1;
            end

            // Wait for controller ready
            begin : write0_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable write0_ready;
                end
            end

            // ---- Test 15: SEND_STATUS (CMD13) ----
            $display("  Test: SEND_STATUS (CMD13)...");
            @(posedge clk);
            cmd_id    <= 8'h0A;  // GET_CARD_STATUS
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : status_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable status_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: SEND_STATUS resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00) begin
                $display("  SEND_STATUS completed OK.");
                // Card stub default R1 response has card_status = 0x00000900
                // (CURRENT_STATE=tran=4, READY_FOR_DATA=1)
                if (card_status !== 32'h00000900) begin
                    $display("FAIL: card_status=0x%08X, expected 0x00000900", card_status);
                    errors = errors + 1;
                end
            end else if (resp_valid) begin
                $display("FAIL: SEND_STATUS status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // Wait for controller ready after SEND_STATUS
            begin : status_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable status_ready;
                end
            end

            // ---- Test 16: RE-INIT (CMD0 re-initialization) ----
            $display("  Test: RE-INIT (CMD0 re-initialization)...");
            @(posedge clk);
            cmd_id    <= 8'h0B;  // REINIT
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            // RE-INIT takes much longer (full CMD0→CMD1→...→CMD7→CMD6 sequence)
            begin : reinit_wait
                integer cnt;
                for (cnt = 0; cnt < 10_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable reinit_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: RE-INIT resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00) begin
                $display("  RE-INIT completed OK.");
                // Controller should be back in READY state
                if (!cmd_ready) begin
                    $display("FAIL: cmd_ready not set after RE-INIT");
                    errors = errors + 1;
                end
                // Verify CID is still valid (re-read during init)
                if (cid == 128'd0) begin
                    $display("FAIL: CID is zero after RE-INIT");
                    errors = errors + 1;
                end
            end else if (resp_valid) begin
                $display("FAIL: RE-INIT status=0x%02X, expected 0x00", resp_status);
                errors = errors + 1;
            end

            // Wait for controller ready after RE-INIT
            begin : reinit_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable reinit_ready;
                end
            end

            // ---- Test 17: Secure Erase (CMD38 arg=0x80000000) ----
            $display("  Test: SECURE ERASE LBA=200, count=5...");
            @(posedge clk);
            cmd_id    <= 8'h0C;  // SECURE_ERASE
            cmd_lba   <= 32'd200;
            cmd_count <= 16'd5;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : serase_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable serase_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: secure erase resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00) begin
                $display("  Secure erase completed OK.");
                // Verify CMD38 argument was 0x80000000 (secure erase flag)
                if (last_cmd38_arg !== 32'h8000_0000) begin
                    $display("FAIL: CMD38 arg=0x%08X, expected 0x80000000", last_cmd38_arg);
                    errors = errors + 1;
                end
            end else if (resp_valid) begin
                $display("FAIL: secure erase status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // Wait for controller ready after secure erase
            begin : serase_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable serase_ready;
                end
            end

            // ---- Test 18: Multi-block Write (CMD25, count=2) ----
            $display("  Test: MULTI-BLOCK WRITE LBA=50, count=2...");
            // Fill first sector into bank 0
            uart_wr_bank = 4'd0;
            begin : fill_mb_wr0
                integer i;
                for (i = 0; i < 512; i = i + 1)
                    uut.u_write_buf.mem_lo[{3'd0, i[8:0]}] = (i + 8'hA0) & 8'hFF;
            end

            @(posedge clk);
            cmd_id    <= 8'h04;
            cmd_lba   <= 32'd50;
            cmd_count <= 16'd2;
            cmd_valid            <= 1'b1;
            uart_wr_sector_valid <= 1'b1;
            @(posedge clk);
            cmd_valid            <= 1'b0;
            uart_wr_sector_valid <= 1'b0;

            // Wait for first sector write to complete (controller goes to MC_WRITE_DONE)
            // Then MC_WRITE_DONE waits for uart_wr_sector_valid for second sector
            begin : mbw_wait1
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (uut.mc_state == 5'd8) // MC_WRITE_DONE
                        disable mbw_wait1;
                    if (resp_valid) begin
                        if (resp_status != 8'h00) begin
                            $display("FAIL: multi-block write sector 0 error: status=0x%02X", resp_status);
                            errors = errors + 1;
                        end
                        disable mbw_wait1;
                    end
                end
            end

            // Verify first sector data received by card
            if (uut.mc_state == 5'd8) begin
                begin : verify_mbw0
                    integer i;
                    reg [7:0] expected;
                    reg wr_ok;
                    wr_ok = 1;
                    for (i = 0; i < 512; i = i + 1) begin
                        expected = (i + 8'hA0) & 8'hFF;
                        if (card_wr_mem[i] !== expected) begin
                            if (wr_ok)
                                $display("FAIL: mbw S0 card_wr_mem[%0d]=0x%02X, expected 0x%02X",
                                         i, card_wr_mem[i], expected);
                            wr_ok = 0;
                        end
                    end
                    if (!wr_ok)
                        errors = errors + 1;
                end

                // Fill second sector into bank 1
                begin : fill_mb_wr1
                    integer i;
                    for (i = 0; i < 512; i = i + 1)
                        uut.u_write_buf.mem_lo[{3'd1, i[8:0]}] = (i + 8'hB0) & 8'hFF;
                end

                // Signal second sector ready
                @(posedge clk);
                uart_wr_sector_valid <= 1'b1;
                @(posedge clk);
                uart_wr_sector_valid <= 1'b0;
            end

            // Wait for final resp_valid (after CMD12 STOP)
            begin : mbw_resp_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable mbw_resp_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: multi-block write resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00) begin
                $display("  Multi-block write completed OK.");
                // Verify second sector data
                begin : verify_mbw1
                    integer i;
                    reg [7:0] expected;
                    reg wr_ok;
                    wr_ok = 1;
                    for (i = 0; i < 512; i = i + 1) begin
                        expected = (i + 8'hB0) & 8'hFF;
                        if (card_wr_mem[i] !== expected) begin
                            if (wr_ok)
                                $display("FAIL: mbw S1 card_wr_mem[%0d]=0x%02X, expected 0x%02X",
                                         i, card_wr_mem[i], expected);
                            wr_ok = 0;
                        end
                    end
                    if (!wr_ok)
                        errors = errors + 1;
                end
                // Verify CMD12 was sent
                if (!cmd12_received) begin
                    $display("FAIL: CMD12 not received after multi-block write");
                    errors = errors + 1;
                end
            end else if (resp_valid) begin
                $display("FAIL: multi-block write status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // Wait for card DAT FSM to settle
            begin : mbw_settle
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (dat_state == DAT_IDLE) disable mbw_settle;
                end
            end

            // Wait for controller ready
            begin : mbw_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable mbw_ready;
                end
            end

            // ---- Test 19: Multi-block READ CRC error + CMD12 ----
            $display("  Test: MULTI-BLOCK READ CRC ERROR + CMD12...");
            cmd12_received = 0; // reset flag for verification
            force_rd_crc_err = 1;

            @(posedge clk);
            cmd_id    <= 8'h03;
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd2;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : mb_rd_err_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable mb_rd_err_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: multi-block read CRC error resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h03) begin
                $display("  Multi-block read CRC error correctly reported.");
                // Verify CMD12 was sent (MC_ERROR_STOP should have sent it)
                // Wait a bit for CMD12 to propagate through card stub
                repeat (1000) @(posedge clk);
                if (!cmd12_received) begin
                    $display("FAIL: CMD12 not sent after multi-block read error");
                    errors = errors + 1;
                end else begin
                    $display("  CMD12 sent after multi-block read error — OK.");
                end
            end else if (resp_valid) begin
                $display("FAIL: multi-block read CRC error status=0x%02X, expected 0x03", resp_status);
                errors = errors + 1;
            end

            force_rd_crc_err = 0;

            // Wait for card DAT FSM + controller to settle
            begin : mb_rd_err_settle
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (dat_state == DAT_IDLE && cmd_ready) disable mb_rd_err_settle;
                end
            end

            // ---- Test 20: Multi-block WRITE CRC error + CMD12 ----
            $display("  Test: MULTI-BLOCK WRITE CRC ERROR + CMD12...");
            cmd12_received = 0;
            force_wr_crc_err = 1;

            uart_wr_bank = 4'd0;
            begin : fill_mb_err
                integer i;
                for (i = 0; i < 512; i = i + 1)
                    uut.u_write_buf.mem_lo[{3'd0, i[8:0]}] = i & 8'hFF;
            end

            @(posedge clk);
            cmd_id    <= 8'h04;
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd2;
            cmd_valid            <= 1'b1;
            uart_wr_sector_valid <= 1'b1;
            @(posedge clk);
            cmd_valid            <= 1'b0;
            uart_wr_sector_valid <= 1'b0;

            begin : mb_wr_err_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable mb_wr_err_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: multi-block write CRC error resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h03) begin
                $display("  Multi-block write CRC error correctly reported.");
                repeat (1000) @(posedge clk);
                if (!cmd12_received) begin
                    $display("FAIL: CMD12 not sent after multi-block write error");
                    errors = errors + 1;
                end else begin
                    $display("  CMD12 sent after multi-block write error — OK.");
                end
            end else if (resp_valid) begin
                $display("FAIL: multi-block write CRC error status=0x%02X, expected 0x03", resp_status);
                errors = errors + 1;
            end

            force_wr_crc_err = 0;

            begin : mb_wr_err_settle
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (dat_state == DAT_IDLE && cmd_ready) disable mb_wr_err_settle;
                end
            end

            // ---- Test 21: DAT0 busy timeout (switch_wait_cnt overflow) ----
            $display("  Test: DAT0 BUSY TIMEOUT...");
            force_switch_no_release = 1;

            @(posedge clk);
            cmd_id    <= 8'h08;  // SET_PARTITION
            cmd_lba   <= {24'd0, 8'd1}; // boot0
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            // Wait for MC_SWITCH_WAIT state, then force counter near overflow
            begin : busy_to_seek
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (uut.mc_state == 5'd15) // MC_SWITCH_WAIT
                        disable busy_to_seek;
                end
            end

            // Speed up: force counter near overflow (need to wait for clk_en low)
            begin : force_cnt
                integer cnt;
                for (cnt = 0; cnt < 100; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (!uut.clk_en) begin
                        uut.switch_wait_cnt = 20'hF_FFFD;
                        disable force_cnt;
                    end
                end
            end

            begin : busy_to_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable busy_to_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: busy timeout resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h03)
                $display("  DAT0 busy timeout correctly reported.");
            else if (resp_valid) begin
                $display("FAIL: busy timeout status=0x%02X, expected 0x03", resp_status);
                errors = errors + 1;
            end

            force_switch_no_release = 0;

            begin : busy_to_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable busy_to_ready;
                end
            end

            // ---- Test 22: SET_CLK_DIV (runtime clock switching) ----
            $display("  Test: SET_CLK_DIV preset=3 (10 MHz)...");
            @(posedge clk);
            cmd_id    <= 8'h0D;  // SET_CLK_DIV
            cmd_lba   <= {29'd0, 3'd3}; // preset 3 = 10 MHz (div=3)
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : setclk_wait
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable setclk_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: SET_CLK_DIV resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00) begin
                $display("  SET_CLK_DIV preset=3 accepted.");
                // Verify fast_clk_div_reload = preset_to_div(3) - 1 = 3 - 1 = 2
                if (uut.fast_clk_div_reload !== 9'd2) begin
                    $display("FAIL: fast_clk_div_reload=%0d, expected 2", uut.fast_clk_div_reload);
                    errors = errors + 1;
                end
                if (uut.current_clk_preset !== 3'd3) begin
                    $display("FAIL: current_clk_preset=%0d, expected 3", uut.current_clk_preset);
                    errors = errors + 1;
                end
            end else if (resp_valid) begin
                $display("FAIL: SET_CLK_DIV preset=3 status=0x%02X, expected 0x00", resp_status);
                errors = errors + 1;
            end

            // Wait for controller ready
            begin : setclk_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable setclk_ready;
                end
            end

            // Test invalid preset (7)
            $display("  Test: SET_CLK_DIV preset=7 (invalid, should ERR_CMD)...");
            @(posedge clk);
            cmd_id    <= 8'h0D;
            cmd_lba   <= {29'd0, 3'd7}; // preset 7 = invalid
            cmd_count <= 16'd0;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : setclk_inv_wait
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable setclk_inv_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: SET_CLK_DIV invalid resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h02)
                $display("  SET_CLK_DIV preset=7 correctly rejected (ERR_CMD).");
            else if (resp_valid) begin
                $display("FAIL: SET_CLK_DIV preset=7 status=0x%02X, expected 0x02", resp_status);
                errors = errors + 1;
            end

            // Verify preset was NOT changed (still 3)
            if (uut.current_clk_preset !== 3'd3) begin
                $display("FAIL: current_clk_preset=%0d after invalid, expected 3", uut.current_clk_preset);
                errors = errors + 1;
            end

            // Wait for controller ready
            begin : setclk_inv_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable setclk_inv_ready;
                end
            end

            // ---- Test 23a: SEND_RAW CMD13 (R1 short response) ----
            $display("  Test: SEND_RAW CMD13 (R1 short response)...");
            @(posedge clk);
            cmd_id    <= 8'h0E;  // SEND_RAW
            cmd_lba   <= 32'd0;  // ARG (CMD13 accepts RCA in [31:16], card stub ignores)
            // cmd_count = {5'b0, FLAGS[2:0], 2'b0, CMD_INDEX[5:0]}
            // FLAGS: check_busy=0, resp_long=0, resp_expected=1 → 3'b001
            // CMD_INDEX = 13 = 6'b001101
            cmd_count <= {5'b0, 3'b001, 2'b0, 6'd13};
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : raw13_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable raw13_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: RAW CMD13 resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00) begin
                $display("  RAW CMD13 completed OK.");
                // Card stub responds with card_status = 0x00000900
                if (card_status !== 32'h0000_0900) begin
                    $display("FAIL: RAW CMD13 card_status=0x%08X, expected 0x00000900", card_status);
                    errors = errors + 1;
                end
            end else if (resp_valid) begin
                $display("FAIL: RAW CMD13 status=0x%02X, expected 0x00", resp_status);
                errors = errors + 1;
            end

            // Wait for controller ready
            begin : raw13_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable raw13_ready;
                end
            end

            // ---- Test 23b: SEND_RAW CMD62 vendor-specific (R1 short) ----
            $display("  Test: SEND_RAW CMD62 arg=0x96C9D71C...");
            @(posedge clk);
            cmd_id    <= 8'h0E;
            cmd_lba   <= 32'h96C9_D71C;  // vendor debug mode argument
            // FLAGS: check_busy=0, resp_long=0, resp_expected=1 → 3'b001
            // CMD_INDEX = 62 = 6'b111110
            cmd_count <= {5'b0, 3'b001, 2'b0, 6'd62};
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : raw62_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable raw62_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: RAW CMD62 resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00)
                $display("  RAW CMD62 completed OK.");
            else if (resp_valid) begin
                $display("FAIL: RAW CMD62 status=0x%02X, expected 0x00", resp_status);
                errors = errors + 1;
            end

            begin : raw62_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable raw62_ready;
                end
            end

            // ---- Test 23c: SEND_RAW CMD0 no response ----
            $display("  Test: SEND_RAW CMD0 arg=0 (no response)...");
            @(posedge clk);
            cmd_id    <= 8'h0E;
            cmd_lba   <= 32'd0;
            // FLAGS: check_busy=0, resp_long=0, resp_expected=0 → 3'b000
            // CMD_INDEX = 0 = 6'b000000
            cmd_count <= {5'b0, 3'b000, 2'b0, 6'd0};
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : raw0_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable raw0_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: RAW CMD0 resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00)
                $display("  RAW CMD0 no-response completed OK.");
            else if (resp_valid) begin
                $display("FAIL: RAW CMD0 status=0x%02X, expected 0x00", resp_status);
                errors = errors + 1;
            end

            begin : raw0_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable raw0_ready;
                end
            end

            // ---- Test 23d: SEND_RAW CMD9 R2 long response ----
            $display("  Test: SEND_RAW CMD9 (R2 long response)...");
            @(posedge clk);
            cmd_id    <= 8'h0E;
            cmd_lba   <= 32'd0;
            // FLAGS: check_busy=0, resp_long=1, resp_expected=1 → 3'b011
            // CMD_INDEX = 9 = 6'b001001
            cmd_count <= {5'b0, 3'b011, 2'b0, 6'd9};
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : raw9_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable raw9_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: RAW CMD9 resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00) begin
                $display("  RAW CMD9 R2 completed OK.");
                // Card stub CMD9 returns CSD: 0xAABBCCDD_EEFF0011_22334455_66778899
                if (raw_resp_data !== 128'hAABBCCDD_EEFF0011_22334455_66778899) begin
                    $display("FAIL: RAW CMD9 raw_resp_data=0x%032X, expected CSD", raw_resp_data);
                    errors = errors + 1;
                end
            end else if (resp_valid) begin
                $display("FAIL: RAW CMD9 status=0x%02X, expected 0x00", resp_status);
                errors = errors + 1;
            end

            begin : raw9_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable raw9_ready;
                end
            end

            // ---- Test 23e: SEND_RAW CMD6 with check_busy ----
            $display("  Test: SEND_RAW CMD6 SWITCH (check_busy=1)...");
            @(posedge clk);
            cmd_id    <= 8'h0E;
            // CMD6 SWITCH argument: access=0b11 (write), index=179, value=0x02, cmd_set=0
            cmd_lba   <= {6'b0, 2'b11, 8'd179, 8'd2, 8'b0};
            // FLAGS: check_busy=1, resp_long=0, resp_expected=1 → 3'b101
            // CMD_INDEX = 6 = 6'b000110
            cmd_count <= {5'b0, 3'b101, 2'b0, 6'd6};
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : raw6_wait
                integer cnt;
                for (cnt = 0; cnt < 5_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable raw6_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: RAW CMD6 resp_valid timeout");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00)
                $display("  RAW CMD6 with busy wait completed OK.");
            else if (resp_valid) begin
                $display("FAIL: RAW CMD6 status=0x%02X, expected 0x00", resp_status);
                errors = errors + 1;
            end

            begin : raw6_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable raw6_ready;
                end
            end
        end

        // ---- Test 24: Multi-block Write count=16 (full 16-bank FIFO) ----
        begin
            $display("  Test: MULTI-BLOCK WRITE LBA=100, count=16...");
            // Fill all 16 banks with unique patterns
            uart_wr_bank = 4'd0;
            begin : fill_mb16
                integer b, i;
                for (b = 0; b < 16; b = b + 1)
                    for (i = 0; i < 512; i = i + 1)
                        if (b < 8)
                            uut.u_write_buf.mem_lo[{b[2:0], i[8:0]}] = (i + b * 16 + 8'hC0) & 8'hFF;
                        else
                            uut.u_write_buf.mem_hi[{b[2:0], i[8:0]}] = (i + b * 16 + 8'hC0) & 8'hFF;
            end

            @(posedge clk);
            cmd_id    <= 8'h04;
            cmd_lba   <= 32'd100;
            cmd_count <= 16'd16;
            cmd_valid            <= 1'b1;
            uart_wr_sector_valid <= 1'b1;
            @(posedge clk);
            cmd_valid            <= 1'b0;
            uart_wr_sector_valid <= 1'b0;

            // Wait for first sector DAT write to start
            begin : mb16_wait_first
                integer cnt;
                for (cnt = 0; cnt < 200_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (uut.mc_state == 5'd8) disable mb16_wait_first; // MC_WRITE_DONE
                end
            end

            // Verify first sector data
            begin : verify_mb16_s0
                integer i;
                reg [7:0] expected;
                reg wr_ok;
                wr_ok = 1;
                for (i = 0; i < 512; i = i + 1) begin
                    expected = (i + 8'hC0) & 8'hFF;
                    if (card_wr_mem[i] !== expected) begin
                        if (wr_ok)
                            $display("FAIL: mb16 S0 card_wr_mem[%0d]=0x%02X, expected 0x%02X",
                                     i, card_wr_mem[i], expected);
                        wr_ok = 0;
                    end
                end
                if (!wr_ok)
                    errors = errors + 1;
            end

            // Feed remaining 15 sectors one by one
            begin : mb16_feed
                integer s;
                for (s = 1; s < 16; s = s + 1) begin
                    @(posedge clk);
                    uart_wr_sector_valid <= 1'b1;
                    @(posedge clk);
                    uart_wr_sector_valid <= 1'b0;

                    // Wait for MC_WRITE_DONE for this sector
                    begin : mb16_wait_s
                        integer cnt;
                        for (cnt = 0; cnt < 200_000; cnt = cnt + 1) begin
                            @(posedge clk);
                            if (uut.mc_state == 5'd8) disable mb16_wait_s;
                        end
                    end

                    // Verify this sector's data
                    begin : verify_mb16_sn
                        integer i;
                        reg [7:0] expected;
                        reg wr_ok;
                        wr_ok = 1;
                        for (i = 0; i < 512; i = i + 1) begin
                            expected = (i + s * 16 + 8'hC0) & 8'hFF;
                            if (card_wr_mem[i] !== expected) begin
                                if (wr_ok)
                                    $display("FAIL: mb16 S%0d card_wr_mem[%0d]=0x%02X, expected 0x%02X",
                                             s, i, card_wr_mem[i], expected);
                                wr_ok = 0;
                            end
                        end
                        if (!wr_ok)
                            errors = errors + 1;
                    end
                end
            end

            // Wait for resp_valid (after CMD12 STOP)
            begin : mb16_resp_wait
                integer cnt;
                for (cnt = 0; cnt < 200_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable mb16_resp_wait;
                end
            end

            if (resp_status !== 8'h00) begin
                $display("FAIL: mb16 resp_status=0x%02X, expected 0x00", resp_status);
                errors = errors + 1;
            end

            // Wait for cmd_ready
            begin : mb16_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable mb16_ready;
                end
            end

            $display("    16-sector multi-block write verified OK");
        end

        // ---- Test 25: Write count=17 rejected (exceeds 16-bank limit) ----
        begin
            $display("  Test: WRITE count=17 rejected...");
            @(posedge clk);
            cmd_id    <= 8'h04;
            cmd_lba   <= 32'd200;
            cmd_count <= 16'd17;
            cmd_valid            <= 1'b1;
            uart_wr_sector_valid <= 1'b1;
            @(posedge clk);
            cmd_valid            <= 1'b0;

            begin : wr17_resp
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable wr17_resp;
                end
            end

            if (resp_status !== 8'h02) begin
                $display("FAIL: count=17 resp_status=0x%02X, expected 0x02 (ERR_CMD)", resp_status);
                errors = errors + 1;
            end

            uart_wr_sector_valid <= 1'b0;

            begin : wr17_ready
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable wr17_ready;
                end
            end
        end

        // ---- Test 26: CMD17 CRC error → ERR_EMMC ----
        begin
            $display("  Test: CMD17 CRC error...");
            force_cmd_crc_err = 1;
            @(posedge clk);
            cmd_id    <= 8'h03; // READ_SECTOR
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd1;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : rd_crc_cmd_resp26
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable rd_crc_cmd_resp26;
                end
            end

            if (resp_status !== 8'h03) begin
                $display("FAIL: CMD17 CRC err resp_status=0x%02X, expected 0x03", resp_status);
                errors = errors + 1;
            end

            begin : rd_crc_cmd_ready26
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable rd_crc_cmd_ready26;
                end
            end

            force_cmd_crc_err = 0;
        end

        // ---- Test 27: CMD18 CRC error → ERR_EMMC + CMD12 STOP ----
        begin
            $display("  Test: CMD18 CRC error + CMD12...");
            force_cmd_crc_err = 1;
            @(posedge clk);
            cmd_id    <= 8'h03; // READ_SECTOR
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd2; // multi-block → CMD18
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : rd_crc_cmd_resp27
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable rd_crc_cmd_resp27;
                end
            end

            if (resp_status !== 8'h03) begin
                $display("FAIL: CMD18 CRC err resp_status=0x%02X, expected 0x03", resp_status);
                errors = errors + 1;
            end

            // Verify CMD12 was sent (cmd12_received set by card stub)
            if (!cmd12_received) begin
                $display("FAIL: CMD18 CRC err — CMD12 STOP not sent");
                errors = errors + 1;
            end

            begin : rd_crc_cmd_ready27
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable rd_crc_cmd_ready27;
                end
            end

            force_cmd_crc_err = 0;
        end

        // ---- Test 28: CMD25 CRC error → ERR_EMMC + CMD12 STOP ----
        begin
            $display("  Test: CMD25 CRC error + CMD12...");

            // Fill write buffer sector 0
            begin : fill_buf28
                integer i;
                for (i = 0; i < 512; i = i + 1)
                    uut.u_write_buf.mem_lo[{3'd0, i[8:0]}] = (i + 8'h28) & 8'hFF;
            end

            force_cmd_crc_err = 1;
            @(posedge clk);
            cmd_id    <= 8'h04; // WRITE_SECTOR
            cmd_lba   <= 32'd0;
            cmd_count <= 16'd2; // multi-block → CMD25
            cmd_valid            <= 1'b1;
            uart_wr_sector_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            begin : wr_crc_cmd_resp28
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable wr_crc_cmd_resp28;
                end
            end

            if (resp_status !== 8'h03) begin
                $display("FAIL: CMD25 CRC err resp_status=0x%02X, expected 0x03", resp_status);
                errors = errors + 1;
            end

            // Verify CMD12 was sent
            if (!cmd12_received) begin
                $display("FAIL: CMD25 CRC err — CMD12 STOP not sent");
                errors = errors + 1;
            end

            uart_wr_sector_valid <= 1'b0;

            begin : wr_crc_cmd_ready28
                integer cnt;
                for (cnt = 0; cnt < 100_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable wr_crc_cmd_ready28;
                end
            end

            force_cmd_crc_err = 0;
        end

        // ---- Test 29: Multi-block read with backpressure (CMD18, count=3) ----
        // Verify that MC_READ_DONE waits for rd_sector_ack before starting next DAT read
        begin
            $display("  Test: Multi-block read with backpressure (count=3)...");

            // Wait for controller to be ready after previous test
            begin : bp_pre_ready
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable bp_pre_ready;
                end
            end

            // Wait for card stub DAT FSM to return to IDLE (may still be sending
            // data from previous CMD18/CMD25 CRC error tests)
            begin : bp_dat_settle
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (dat_state == 0) disable bp_dat_settle; // DAT_IDLE
                end
            end
            repeat (100) @(posedge clk);

            @(posedge clk);
            cmd_id    <= 8'h03; // READ_SECTOR
            cmd_lba   <= 32'd20;
            cmd_count <= 16'd3;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            // Sector 0: wait for rd_sector_ready, delay ack by 500 clocks
            begin : bp_wait0
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable bp_wait0;
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: backpressure S0 rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end

            if (rd_sector_ready) begin
                // Delay ack by 500 clocks (simulates slow UART TX)
                // Verify CLK gating: clk_pause should be active during backpressure
                repeat (50) @(posedge clk);
                if (!uut.clk_pause) begin
                    $display("FAIL: clk_pause not active during backpressure wait");
                    errors = errors + 1;
                end
                repeat (450) @(posedge clk);
                // ACK promotes uart_rd_bank from _next → active
                rd_sector_ack <= 1'b1;
                @(posedge clk);
                rd_sector_ack <= 1'b0;
                // Verify sector 0 data after ACK: pattern byte[i] = (i + 20) & 0xFF
                repeat (2) @(posedge clk);
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h14) begin // 0 + 20 = 0x14
                    $display("FAIL: backpressure S0[0]=0x%02X, expected 0x14", uart_rd_data);
                    errors = errors + 1;
                end
            end

            // Sector 1: wait for rd_sector_ready, delay ack by 300 clocks
            begin : bp_wait1
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable bp_wait1;
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: backpressure S1 rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end

            if (rd_sector_ready) begin
                // Verify clk_pause released after ack
                if (uut.clk_pause) begin
                    $display("FAIL: clk_pause still active after S0 ack + DAT read");
                    errors = errors + 1;
                end
                // Delay ack by 300 clocks
                repeat (300) @(posedge clk);
                // ACK promotes uart_rd_bank
                rd_sector_ack <= 1'b1;
                @(posedge clk);
                rd_sector_ack <= 1'b0;
                // Verify sector 1 data after ACK: pattern byte[i] = (i + 21) & 0xFF
                repeat (2) @(posedge clk);
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h15) begin // 0 + 21 = 0x15
                    $display("FAIL: backpressure S1[0]=0x%02X, expected 0x15", uart_rd_data);
                    errors = errors + 1;
                end
            end

            // Sector 2: wait for rd_sector_ready
            begin : bp_wait2
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable bp_wait2;
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: backpressure S2 rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end

            if (rd_sector_ready) begin
                // ACK promotes uart_rd_bank
                rd_sector_ack <= 1'b1;
                @(posedge clk);
                rd_sector_ack <= 1'b0;
                // Verify sector 2 data after ACK: pattern byte[i] = (i + 22) & 0xFF
                repeat (2) @(posedge clk);
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h16) begin // 0 + 22 = 0x16
                    $display("FAIL: backpressure S2[0]=0x%02X, expected 0x16", uart_rd_data);
                    errors = errors + 1;
                end
            end

            // Wait for CMD12 STOP + final response
            begin : bp_resp_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable bp_resp_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: backpressure resp_valid timeout after CMD12");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00)
                $display("  Multi-block read with backpressure OK (3 sectors, delayed acks).");
            else if (resp_valid) begin
                $display("FAIL: backpressure final status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // Wait for card DAT FSM settle
            begin : bp_settle
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable bp_settle;
                end
            end
        end

        // ---- Test 30: CMD18 data integrity — uart_rd_bank double-buffer ----
        // Verifies that uart_rd_bank does NOT switch while reading sector data.
        // Scenario: ACK sector 0, let sector 1 complete (uart_rd_bank_next updates),
        // but uart_rd_bank must still point to sector 0's bank until sector 1 is ACK'd.
        // Then after ACK sector 1, verify sector 1 data is correct.
        begin
            $display("  Test: CMD18 data integrity — uart_rd_bank double-buffer (count=3, LBA=30)...");

            // Wait for controller ready
            begin : t30_pre_ready
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable t30_pre_ready;
                end
            end

            // Wait for card DAT FSM idle
            begin : t30_dat_settle
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (dat_state == 0) disable t30_dat_settle;
                end
            end
            repeat (100) @(posedge clk);

            // Issue CMD18 read: LBA=30, count=3
            @(posedge clk);
            cmd_id    <= 8'h03; // READ_SECTOR
            cmd_lba   <= 32'd30;
            cmd_count <= 16'd3;
            cmd_valid <= 1'b1;
            @(posedge clk);
            cmd_valid <= 1'b0;

            // === Sector 0: wait for ready, ACK immediately ===
            begin : t30_wait0
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable t30_wait0;
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: T30 S0 rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end

            if (rd_sector_ready) begin
                // ACK sector 0 — promotes uart_rd_bank, controller starts reading sector 1
                rd_sector_ack <= 1'b1;
                @(posedge clk);
                rd_sector_ack <= 1'b0;

                // Verify sector 0 data after ACK: byte[i] = (i + 30) & 0xFF
                repeat (2) @(posedge clk);
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h1E) begin // 0 + 30 = 0x1E
                    $display("FAIL: T30 S0[0]=0x%02X, expected 0x1E (post-ack)", uart_rd_data);
                    errors = errors + 1;
                end
            end

            // === Wait for sector 1 to finish (uart_rd_bank_next updates, but uart_rd_bank must NOT) ===
            begin : t30_wait1
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable t30_wait1;
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: T30 S1 rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end

            // === CRITICAL CHECK: sector 1 is ready but NOT yet ACK'd ===
            // uart_rd_bank must still point to sector 0's bank (from the ACK above).
            // Without double-buffer fix: uart_rd_bank already switched → reads sector 1 data → FAIL
            // With fix: uart_rd_bank unchanged → still reads sector 0 data → PASS
            if (rd_sector_ready) begin
                // Read sector 0 data via current uart_rd_bank (should still be S0's bank)
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h1E) begin // sector 0: (0 + 30) = 0x1E
                    $display("FAIL: T30 S0[0] after S1 ready = 0x%02X, expected 0x1E (bank switched early!)", uart_rd_data);
                    errors = errors + 1;
                end
                uart_rd_addr <= 9'd255;
                repeat (3) @(posedge clk);
                // sector 0: (255 + 30) & 0xFF = 285 & 0xFF = 0x1D
                if (uart_rd_data !== 8'h1D) begin
                    $display("FAIL: T30 S0[255] after S1 ready = 0x%02X, expected 0x1D (bank switched early!)", uart_rd_data);
                    errors = errors + 1;
                end

                // NOW ACK sector 1 — uart_rd_bank should switch to sector 1's bank
                rd_sector_ack <= 1'b1;
                @(posedge clk);
                rd_sector_ack <= 1'b0;

                // Verify sector 1 data after ACK: byte[i] = (i + 31) & 0xFF
                repeat (2) @(posedge clk); // let uart_rd_bank propagate through BRAM
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h1F) begin // 0 + 31 = 0x1F
                    $display("FAIL: T30 S1[0]=0x%02X, expected 0x1F (after ack)", uart_rd_data);
                    errors = errors + 1;
                end
                uart_rd_addr <= 9'd1;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h20) begin // 1 + 31 = 0x20
                    $display("FAIL: T30 S1[1]=0x%02X, expected 0x20 (after ack)", uart_rd_data);
                    errors = errors + 1;
                end
            end

            // === Sector 2 ===
            begin : t30_wait2
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (rd_sector_ready) disable t30_wait2;
                end
                if (!rd_sector_ready) begin
                    $display("FAIL: T30 S2 rd_sector_ready timeout");
                    errors = errors + 1;
                end
            end

            if (rd_sector_ready) begin
                // ACK promotes uart_rd_bank to sector 2
                rd_sector_ack <= 1'b1;
                @(posedge clk);
                rd_sector_ack <= 1'b0;

                // Verify sector 2 data after ACK: pattern byte[i] = (i + 32) & 0xFF
                repeat (2) @(posedge clk);
                uart_rd_addr <= 9'd0;
                repeat (3) @(posedge clk);
                if (uart_rd_data !== 8'h20) begin // 0 + 32 = 0x20
                    $display("FAIL: T30 S2[0]=0x%02X, expected 0x20", uart_rd_data);
                    errors = errors + 1;
                end
            end

            // Wait for CMD12 STOP + final response
            begin : t30_resp_wait
                integer cnt;
                for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable t30_resp_wait;
                end
                if (!resp_valid) begin
                    $display("FAIL: T30 resp_valid timeout after CMD12");
                    errors = errors + 1;
                end
            end

            if (resp_valid && resp_status == 8'h00)
                $display("  CMD18 data integrity — uart_rd_bank double-buffer OK.");
            else if (resp_valid) begin
                $display("FAIL: T30 final status=0x%02X", resp_status);
                errors = errors + 1;
            end

            // Settle
            begin : t30_settle
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (cmd_ready) disable t30_settle;
                end
            end
        end

        // ---- Test 6: CLK Preset changes (SET_CLK_DIV) ----
        $display("  Test: SET_CLK_DIV presets 0-6...");
        begin : clk_preset_tests
            integer preset;
            integer expected_div;

            // Test each valid preset 0-6
            for (preset = 0; preset <= 6; preset = preset + 1) begin
                @(posedge clk);
                cmd_id    <= 8'h0D;  // SET_CLK_DIV
                cmd_lba   <= {29'b0, preset[2:0]};  // preset goes in cmd_lba[2:0]
                cmd_count <= 16'd0;
                cmd_valid <= 1'b1;
                @(posedge clk);
                cmd_valid <= 1'b0;

                // Wait for resp_valid
                begin : clk_resp_wait
                    integer cnt;
                    for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                        @(posedge clk);
                        if (resp_valid) disable clk_resp_wait;
                    end
                    if (!resp_valid) begin
                        $display("FAIL: SET_CLK_DIV preset=%0d: resp_valid timeout", preset);
                        errors = errors + 1;
                    end
                end

                // Check response status
                if (resp_valid && resp_status == 8'h00) begin
                    // Expected divider values: preset_to_div(x) - 1
                    case (preset)
                        0: expected_div = 14;  // 15 - 1
                        1: expected_div = 7;   // 8 - 1
                        2: expected_div = 4;   // 5 - 1
                        3: expected_div = 2;   // 3 - 1
                        4: expected_div = 1;   // 2 - 1
                        5: expected_div = 1;   // 2 - 1
                        6: expected_div = 0;   // 1 - 1
                        default: expected_div = -1;
                    endcase

                    // Small delay to allow register update
                    repeat (5) @(posedge clk);

                    // Verify current_clk_preset
                    if (uut.current_clk_preset !== preset[2:0]) begin
                        $display("FAIL: SET_CLK_DIV preset=%0d: current_clk_preset=0x%01X, expected 0x%01X",
                                 preset, uut.current_clk_preset, preset[2:0]);
                        errors = errors + 1;
                    end

                    // Verify fast_clk_div_reload
                    if (uut.fast_clk_div_reload !== expected_div) begin
                        $display("FAIL: SET_CLK_DIV preset=%0d: fast_clk_div_reload=0x%03X, expected 0x%03X",
                                 preset, uut.fast_clk_div_reload, expected_div);
                        errors = errors + 1;
                    end else begin
                        $display("  SET_CLK_DIV preset=%0d: OK (preset_reg=0x%01X, div=0x%03X)",
                                 preset, uut.current_clk_preset, uut.fast_clk_div_reload);
                    end
                end else begin
                    $display("FAIL: SET_CLK_DIV preset=%0d: status=0x%02X valid=%0d",
                             preset, resp_status, resp_valid);
                    errors = errors + 1;
                end

                // Wait for cmd_ready before next test
                begin : clk_cmd_ready
                    integer cnt;
                    for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                        @(posedge clk);
                        if (cmd_ready) disable clk_cmd_ready;
                    end
                end
            end
        end

        // ---- Test 6b: Reject invalid preset 7 ----
        $display("  Test: SET_CLK_DIV reject invalid preset 7...");
        @(posedge clk);
        cmd_id    <= 8'h0D;
        cmd_lba   <= {29'b0, 3'd7};  // Invalid preset
        cmd_count <= 16'd0;
        cmd_valid <= 1'b1;
        @(posedge clk);
        cmd_valid <= 1'b0;

        // Wait for resp_valid
        begin : clk_invalid_wait
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (resp_valid) disable clk_invalid_wait;
            end
            if (!resp_valid) begin
                $display("FAIL: SET_CLK_DIV preset=7: resp_valid timeout");
                errors = errors + 1;
            end
        end

        // Check that we get STATUS_CMD_ERR (0x02) for invalid preset
        if (resp_valid && resp_status == 8'h02) begin
            $display("  SET_CLK_DIV preset=7: correctly rejected (STATUS_CMD_ERR)");
        end else begin
            $display("FAIL: SET_CLK_DIV preset=7: status=0x%02X (expected 0x02)", resp_status);
            errors = errors + 1;
        end

        // Wait for cmd_ready
        begin : clk_invalid_settle
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (cmd_ready) disable clk_invalid_settle;
            end
        end

        // ---- Test 6c: Verify command reception after CLK preset change ----
        $display("  Test: Commands at SET_CLK_DIV preset 3 (10 MHz)...");
        // First, set clock to preset 3 (10 MHz)
        @(posedge clk);
        cmd_id    <= 8'h0D;
        cmd_lba   <= {29'b0, 3'd3};
        cmd_count <= 16'd0;
        cmd_valid <= 1'b1;
        @(posedge clk);
        cmd_valid <= 1'b0;

        // Wait for resp_valid
        begin : clk_set_wait
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (resp_valid) disable clk_set_wait;
            end
        end

        if (resp_valid && resp_status == 8'h00) begin
            $display("  Clock set to preset 3 (10 MHz): OK.");
        end else begin
            $display("FAIL: SET_CLK_DIV preset=3: status=0x%02X", resp_status);
            errors = errors + 1;
        end

        // Wait for cmd_ready
        begin : clk_set_settle
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (cmd_ready) disable clk_set_settle;
            end
        end
        // Extra settling delay after clock change
        repeat (100) @(posedge clk);

        // Verify that SEND_STATUS works at new clock speed
        @(posedge clk);
        cmd_id    <= 8'h0A;  // SEND_STATUS
        cmd_lba   <= 32'd0;
        cmd_count <= 16'd0;
        cmd_valid <= 1'b1;
        @(posedge clk);
        cmd_valid <= 1'b0;

        // Wait for resp_valid
        begin : clk_status_wait
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (resp_valid) disable clk_status_wait;
            end
            if (!resp_valid) begin
                $display("FAIL: SEND_STATUS at preset 3: resp_valid timeout");
                errors = errors + 1;
            end
        end

        if (resp_valid && resp_status == 8'h00) begin
            $display("  SEND_STATUS at preset 3 (10 MHz): OK.");
        end else begin
            $display("FAIL: SEND_STATUS at preset 3: status=0x%02X", resp_status);
            errors = errors + 1;
        end

        // Settle
        begin : clk_settle_final
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (cmd_ready) disable clk_settle_final;
            end
        end

        // =========================================================
        // T33: RPMB FIFO wait timeout (SET_RPMB_MODE + WRITE without data)
        // =========================================================
        $display("T33: RPMB FIFO wait timeout...");
        repeat (100) @(posedge clk);

        // Enable RPMB mode (force_multi_block=1)
        @(posedge clk);
        cmd_id    <= 8'h10;  // SET_RPMB_MODE
        cmd_lba   <= 32'd1;  // mode=1
        cmd_count <= 16'd0;
        cmd_valid <= 1'b1;
        @(posedge clk);
        cmd_valid <= 1'b0;

        begin : rpmb_mode_wait
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (resp_valid) disable rpmb_mode_wait;
            end
        end

        if (!resp_valid || resp_status != 8'h00) begin
            $display("FAIL: SET_RPMB_MODE status=0x%02X", resp_status);
            errors = errors + 1;
        end

        // Wait for cmd_ready
        begin : rpmb_mode_settle
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (cmd_ready) disable rpmb_mode_settle;
            end
        end

        // Issue WRITE_SECTOR with count=1, but DO NOT provide write data
        // This will cause: MC_READY -> MC_RPMB_CMD23 -> CMD23 -> MC_RPMB_FIFO_WAIT -> timeout
        @(posedge clk);
        cmd_id    <= 8'h04;  // WRITE_SECTOR
        cmd_lba   <= 32'd0;
        cmd_count <= 16'd1;
        cmd_valid <= 1'b1;
        @(posedge clk);
        cmd_valid <= 1'b0;
        uart_wr_sector_valid <= 1'b0;  // Ensure no write data

        // Wait for FSM to enter MC_RPMB_FIFO_WAIT then fast-forward the watchdog
        // (avoid waiting 16M+ cycles in simulation)
        begin : rpmb_fifo_enter_wait
            integer cnt;
            for (cnt = 0; cnt < 2_000_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (uut.mc_state == 5'd24) disable rpmb_fifo_enter_wait; // MC_RPMB_FIFO_WAIT
            end
        end

        if (uut.mc_state != 5'd24) begin
            $display("FAIL: RPMB FIFO wait — FSM never entered MC_RPMB_FIFO_WAIT (state=%0d)", uut.mc_state);
            errors = errors + 1;
        end else begin
            // Fast-forward watchdog to near-overflow (skip ~16M sim cycles)
            force uut.wr_done_watchdog = 24'hFFFF_F0;
            @(posedge clk);
            release uut.wr_done_watchdog;

            // Wait for timeout -> resp_valid
            begin : rpmb_timeout_wait
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (resp_valid) disable rpmb_timeout_wait;
                end
            end

            if (!resp_valid) begin
                $display("FAIL: RPMB FIFO wait timeout — resp_valid never asserted");
                errors = errors + 1;
            end else if (resp_status != 8'h03) begin
                $display("FAIL: RPMB FIFO wait timeout status=0x%02X, expected 0x03 (EMMC_ERR)", resp_status);
                errors = errors + 1;
            end else begin
                $display("  RPMB FIFO wait timeout: correctly returned EMMC_ERR after watchdog.");
            end
        end

        // Disable RPMB mode
        begin : rpmb_timeout_settle
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (cmd_ready) disable rpmb_timeout_settle;
            end
        end

        @(posedge clk);
        cmd_id    <= 8'h10;  // SET_RPMB_MODE
        cmd_lba   <= 32'd0;  // mode=0 (normal)
        cmd_count <= 16'd0;
        cmd_valid <= 1'b1;
        @(posedge clk);
        cmd_valid <= 1'b0;

        begin : rpmb_mode_off_wait
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (resp_valid) disable rpmb_mode_off_wait;
            end
        end

        begin : rpmb_mode_off_settle
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (cmd_ready) disable rpmb_mode_off_settle;
            end
        end

        // ---- Results ----
        repeat (100) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_emmc_controller");
        else
            $display("[FAIL] tb_emmc_controller (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
