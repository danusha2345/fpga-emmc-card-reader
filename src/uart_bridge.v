// UART Bridge - Command protocol handler
// Parses incoming commands from PC and sends responses
//
// PC -> FPGA: [0xAA] [CMD_ID] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]
// FPGA -> PC: [0x55] [CMD_ID] [STATUS] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]
//
// Timing-optimized: info shift register instead of indexed array,
// RX_EXEC split into RX_EXEC1/RX_EXEC2, payload down-counter.

module uart_bridge #(
    parameter CLK_FREQ  = 60_000_000,
    parameter BAUD_RATE = 3_000_000
)(
    input  wire        clk,
    input  wire        rst_n,

    // UART pins
    input  wire        uart_rx_pin,
    output wire        uart_tx_pin,

    // eMMC controller interface
    output reg         emmc_cmd_valid,
    output reg  [7:0]  emmc_cmd_id,
    output reg  [31:0] emmc_cmd_lba,
    output reg  [15:0] emmc_cmd_count,
    input  wire        emmc_cmd_ready,
    input  wire [7:0]  emmc_resp_status,
    input  wire        emmc_resp_valid,

    // eMMC data read path (sector buffer -> UART)
    input  wire [7:0]  emmc_rd_data,
    output reg  [8:0]  emmc_rd_addr,
    input  wire        emmc_rd_sector_ready,
    output reg         emmc_rd_sector_ack,

    // eMMC data write path (UART -> sector buffer)
    output reg  [7:0]  emmc_wr_data,
    output reg  [8:0]  emmc_wr_addr,
    output reg         emmc_wr_en,
    output reg         emmc_wr_sector_valid,
    input  wire        emmc_wr_sector_ack,
    output reg  [3:0]  emmc_wr_bank,       // current bank UART is writing to (0-15)

    // eMMC info data (CID/CSD)
    input  wire [127:0] emmc_cid,
    input  wire [127:0] emmc_csd,
    input  wire         emmc_info_valid,

    // Card status (CMD13 result)
    input  wire [31:0]  emmc_card_status,

    // Raw command response (R2 128-bit data)
    input  wire [127:0] emmc_raw_resp,

    // Debug (original 4-byte)
    input  wire [3:0]   emmc_dbg_init_state,
    input  wire [4:0]   emmc_dbg_mc_state,
    input  wire         emmc_dbg_cmd_pin,
    input  wire         emmc_dbg_dat0_pin,

    // Debug (extended 8-byte)
    input  wire [2:0]   emmc_dbg_cmd_fsm,
    input  wire [3:0]   emmc_dbg_dat_fsm,
    input  wire [1:0]   emmc_dbg_partition,
    input  wire         emmc_dbg_use_fast_clk,
    input  wire         emmc_dbg_reinit_pending,
    input  wire [7:0]   emmc_dbg_err_cmd_timeout,
    input  wire [7:0]   emmc_dbg_err_cmd_crc,
    input  wire [7:0]   emmc_dbg_err_dat_rd,
    input  wire [7:0]   emmc_dbg_err_dat_wr,
    input  wire [7:0]   emmc_dbg_init_retry_cnt,
    input  wire [2:0]   emmc_dbg_clk_preset,

    // Status
    output wire        uart_activity,
    output reg         protocol_error
);

    // Command IDs
    localparam CMD_PING         = 8'h01;
    localparam CMD_GET_INFO     = 8'h02;
    localparam CMD_READ_SECTOR  = 8'h03;
    localparam CMD_WRITE_SECTOR = 8'h04;
    localparam CMD_ERASE        = 8'h05;
    localparam CMD_GET_STATUS   = 8'h06;
    localparam CMD_GET_EXT_CSD  = 8'h07;  // Read 512-byte Extended CSD
    localparam CMD_SET_PARTITION= 8'h08;  // Switch partition (0=user, 1=boot0, 2=boot1)
    localparam CMD_WRITE_EXT_CSD= 8'h09; // Write ExtCSD byte (generic CMD6 SWITCH)
    localparam CMD_GET_CARD_STATUS= 8'h0A; // CMD13 SEND_STATUS (Card Status Register)
    localparam CMD_REINIT        = 8'h0B; // Full re-initialization (CMD0 + init sequence)
    localparam CMD_SECURE_ERASE  = 8'h0C; // Secure erase (CMD38 arg=0x80000000)
    localparam CMD_SET_CLK_DIV   = 8'h0D; // Set eMMC clock speed preset
    localparam CMD_SEND_RAW      = 8'h0E; // Send arbitrary eMMC command
    localparam CMD_SET_BAUD      = 8'h0F; // Set UART baud rate preset
    localparam CMD_SET_RPMB_MODE = 8'h10; // RPMB mode: force CMD25/CMD18 for count=1

    // Response status codes
    localparam STATUS_OK       = 8'h00;
    localparam STATUS_ERR_CRC  = 8'h01;
    localparam STATUS_ERR_CMD  = 8'h02;
    localparam STATUS_ERR_EMMC = 8'h03;
    localparam STATUS_BUSY     = 8'h04;

    // RX FSM states
    localparam RX_IDLE     = 4'd0;
    localparam RX_CMD      = 4'd1;
    localparam RX_LEN_H    = 4'd2;
    localparam RX_LEN_L    = 4'd3;
    localparam RX_PAYLOAD  = 4'd4;
    localparam RX_CRC      = 4'd5;
    localparam RX_EXEC1    = 4'd6;  // stage 1: load info_shift, decode cmd
    localparam RX_EXEC2    = 4'd7;  // stage 2: set TX params

    // TX FSM states
    localparam TX_IDLE     = 4'd0;
    localparam TX_HEADER   = 4'd1;
    localparam TX_CMD      = 4'd2;
    localparam TX_STATUS   = 4'd3;
    localparam TX_LEN_H    = 4'd4;
    localparam TX_LEN_L    = 4'd5;
    localparam TX_PAYLOAD  = 4'd6;
    localparam TX_CRC      = 4'd7;
    localparam TX_PREFETCH = 4'd8;  // 1-cycle latency for info_shift load
    localparam TX_BAUD_WAIT = 4'd9; // wait for TX to finish before baud switch

    // Baud rate preset lookup: preset index → clks_per_bit
    // At 60 MHz: 60/20=3M, 60/10=6M, 60/5=12M (all exact)
    function [7:0] baud_preset_to_cpb;
        input [1:0] preset;
        case (preset)
            2'd0: baud_preset_to_cpb = 8'd20;  // 60M/20 = 3M
            2'd1: baud_preset_to_cpb = 8'd10;  // 60M/10 = 6M
            2'd2: baud_preset_to_cpb = 8'd8;   // 60M/8  = 7.5M (still rejected)
            2'd3: baud_preset_to_cpb = 8'd5;   // 60M/5  = 12M
        endcase
    endfunction

    // Runtime UART baud rate register (drives both uart_rx and uart_tx)
    reg [7:0]  uart_clks_per_bit;      // current CPB (default: CLK_FREQ/BAUD_RATE)
    reg [7:0]  baud_switch_cpb;        // pending new CPB value
    reg [1:0]  baud_switch_preset;     // pending preset index
    reg        baud_switch_pending;    // switch after TX completes
    reg [1:0]  current_baud_preset;    // for GET_STATUS debug byte

    // Baud watchdog: auto-reset to default baud if no valid packets for ~18s (2^30 @ 60MHz)
    // Increased from 25-bit (~0.56s) to 30-bit (~18s) for GUI pattern (connect-disconnect-reconnect)
    reg [29:0] baud_watchdog_cnt;

    // UART RX instance
    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_frame_err;

    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .rx           (uart_rx_pin),
        .clks_per_bit (uart_clks_per_bit),
        .data_out     (rx_data),
        .data_valid   (rx_valid),
        .frame_err    (rx_frame_err)
    );

    // UART TX instance
    reg  [7:0] tx_data;
    reg        tx_valid;
    wire       tx_busy;

    uart_tx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_tx (
        .clk          (clk),
        .rst_n        (rst_n),
        .data_in      (tx_data),
        .data_valid   (tx_valid),
        .clks_per_bit (uart_clks_per_bit),
        .tx           (uart_tx_pin),
        .busy         (tx_busy)
    );

    // CRC-8 for RX (command validation)
    reg        rx_crc_clear;
    reg        rx_crc_en;
    wire [7:0] rx_crc_out;

    crc8 u_rx_crc (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (rx_crc_clear),
        .enable  (rx_crc_en),
        .data_in (rx_data),
        .crc_out (rx_crc_out)
    );

    // CRC-8 for TX (response generation)
    reg        tx_crc_clear;
    reg        tx_crc_en;
    reg  [7:0] tx_crc_data;
    wire [7:0] tx_crc_out;

    crc8 u_tx_crc (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (tx_crc_clear),
        .enable  (tx_crc_en),
        .data_in (tx_crc_data),
        .crc_out (tx_crc_out)
    );

    // RX state
    reg [3:0]  rx_state;
    reg [7:0]  rx_cmd_id;
    reg [15:0] rx_payload_len;
    reg [15:0] rx_payload_cnt;

    // Payload buffer for short commands (max 8 bytes for LBA+count)
    reg [7:0]  rx_payload_buf [0:7];

    // TX state
    reg [3:0]  tx_state;
    reg [7:0]  tx_cmd_id;
    reg [7:0]  tx_status;
    reg [15:0] tx_payload_len;
    reg [15:0] tx_payload_cnt;
    reg        tx_start;
    reg        tx_start_d;  // Delayed by 1 cycle to allow tx_cmd_id to settle

    // Response payload source
    reg [1:0]  tx_payload_src; // 0=none, 1=info_shift, 2=emmc_rd_data

    // Info shift register: replaces info_buf[32] array with indexed access.
    // Loaded all at once in RX_EXEC1, then shifted out byte-by-byte in TX_PAYLOAD.
    // This eliminates the 32:1 MUX that was the critical timing path.
    reg [255:0] info_shift;

    // Registered BRAM output: breaks BRAM read → MUX → tx_crc_data critical path
    reg [7:0]  emmc_rd_data_reg;

    // Registered tx_busy: breaks uart_tx.state → tx_busy → info_shift critical path
    reg        tx_busy_r;

    // Pre-computed flags for timing optimization
    reg        rx_crc_match;      // registered: rx_data == rx_crc_out (sampled on rx_valid)
    reg        is_write_cmd;      // registered: rx_cmd_id == CMD_WRITE_SECTOR
    reg        tx_payload_last;   // pre-computed: tx_payload_cnt == 0 (down-counter)
    reg        rx_payload_last;   // pre-computed: rx_payload_cnt == 0 (down-counter)
    reg [3:0]  rx_byte_num;       // saturating counter 0→8 for first payload bytes

    // Pre-registered card status pending flag: breaks emmc_cmd_id 8-bit compare from info_shift path
    reg        card_status_pending; // set in RX_EXEC2, cleared in TX_IDLE on resp_valid

    // Raw command pending flags
    reg        raw_cmd_pending;    // set in RX_EXEC2, cleared in TX_IDLE on resp_valid
    reg        raw_resp_is_long;   // FLAGS[1]: expect R2 128-bit response
    reg        raw_resp_expected;  // FLAGS[0]: response was expected

    // Early write dispatch: CMD25 dispatched in RX_PAYLOAD after first sector
    reg        early_write_dispatched;

    // Cross-module pipeline registers: break long route from emmc_controller to info_shift
    reg        resp_valid_r;       // 1-cycle delayed emmc_resp_valid
    reg [7:0]  resp_status_r;      // 1-cycle delayed emmc_resp_status
    reg [7:0]  resp_cmd_id_r;      // 1-cycle delayed emmc_cmd_id (for tx_cmd_id)
    reg [31:0] resp_card_status_r; // 1-cycle delayed emmc_card_status
    reg        resp_status_is_ok;  // pre-computed (emmc_resp_status == STATUS_OK)

    // RX timeout: ~140 ms at 60 MHz (2^23 cycles), resets on each rx_valid
    reg [22:0] rx_timeout_cnt;
    reg        rx_timeout;

    // Sector transfer tracking (read)
    reg [15:0] sectors_remaining;
    reg [15:0] sectors_remaining_next; // pre-computed: sectors_remaining - 1
    reg        sectors_pending;   // registered flag: sectors_remaining != 0

    // Multi-write tracking
    reg [15:0] wr_sectors_left;     // remaining sectors to receive after the first
    reg [4:0]  wr_sectors_ready;    // count of sectors in buffer ready for eMMC (0-16)
    reg [8:0]  wr_byte_in_sector;   // byte counter within current sector (0-511)
    reg        wr_byte_is_last;     // pre-computed: wr_byte_in_sector will be 511 next cycle
    reg        wr_has_sectors_left; // pre-computed: wr_sectors_left != 0
    reg        wr_bank_inc_pending; // delayed bank increment (1-cycle after boundary)

    assign uart_activity = rx_valid | tx_busy;

    // =========================================================
    // Single always block for both RX and TX FSMs
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // RX state
            rx_state       <= RX_IDLE;
            rx_cmd_id      <= 0;
            rx_payload_len <= 0;
            rx_payload_cnt <= 0;
            rx_crc_clear   <= 1'b1;
            rx_crc_en      <= 1'b0;
            protocol_error <= 1'b0;
            emmc_cmd_valid <= 1'b0;
            emmc_cmd_id    <= 0;
            emmc_cmd_lba   <= 0;
            emmc_cmd_count <= 0;
            emmc_wr_en     <= 1'b0;
            emmc_wr_addr   <= 0;
            emmc_wr_data   <= 0;
            emmc_wr_sector_valid <= 1'b0;
            rx_timeout_cnt <= 0;
            rx_timeout     <= 1'b0;
            // TX state
            tx_start       <= 1'b0;
            tx_start_d     <= 1'b0;
            tx_cmd_id      <= 0;
            tx_status      <= 0;
            tx_payload_len <= 0;
            tx_payload_src <= 0;
            tx_state       <= TX_IDLE;
            tx_data        <= 0;
            tx_valid       <= 1'b0;
            tx_payload_cnt <= 0;
            tx_crc_clear   <= 1'b1;
            tx_crc_en      <= 1'b0;
            tx_crc_data    <= 0;
            info_shift     <= 0;
            emmc_rd_addr   <= 0;
            emmc_rd_data_reg <= 0;
            emmc_rd_sector_ack <= 1'b0;
            sectors_remaining <= 0;
            sectors_remaining_next <= 0;
            sectors_pending   <= 1'b0;
            wr_sectors_left   <= 0;
            wr_sectors_ready  <= 5'd0;
            wr_byte_in_sector <= 0;
            wr_byte_is_last   <= 1'b0;
            wr_has_sectors_left <= 1'b0;
            wr_bank_inc_pending <= 1'b0;
            emmc_wr_bank      <= 4'd0;
            rx_crc_match      <= 1'b0;
            is_write_cmd      <= 1'b0;
            tx_payload_last   <= 1'b0;
            rx_payload_last   <= 1'b0;
            rx_byte_num       <= 4'd0;
            tx_busy_r         <= 1'b0;
            card_status_pending <= 1'b0;
            raw_cmd_pending    <= 1'b0;
            raw_resp_is_long   <= 1'b0;
            raw_resp_expected  <= 1'b0;
            resp_valid_r       <= 1'b0;
            resp_status_r      <= 8'h00;
            resp_cmd_id_r      <= 8'h00;
            resp_card_status_r <= 32'h0;
            resp_status_is_ok  <= 1'b0;
            early_write_dispatched <= 1'b0;
            // Baud rate
            uart_clks_per_bit   <= 8'd0; // 0 = use compile-time default
            baud_switch_cpb     <= 8'd0;
            baud_switch_preset  <= 2'd0;
            baud_switch_pending <= 1'b0;
            current_baud_preset <= 2'd0;
            // Baud watchdog
            baud_watchdog_cnt   <= 30'd0;
        end else begin
            // Default pulse signals
            rx_crc_clear <= 1'b0;
            rx_crc_en    <= 1'b0;
            emmc_cmd_valid <= 1'b0;
            emmc_wr_en     <= 1'b0;
            emmc_rd_sector_ack <= 1'b0;
            tx_start     <= 1'b0;
            tx_valid     <= 1'b0;
            tx_crc_clear <= 1'b0;
            tx_crc_en    <= 1'b0;

            // wr_sectors_ready counter: tracks sectors buffered by UART beyond the first.
            // First sector uses direct emmc_wr_sector_valid set in RX_EXEC2.
            // Subsequent sectors: counter incremented on sector boundary in RX_PAYLOAD,
            // promoted to valid when ack clears previous valid.
            // Note: promotion decrement (-1) can be overridden by sector boundary
            // increment (+1) via NBA last-write-wins. The boundary code accounts for
            // this by checking whether promotion would fire in the same cycle.
            if (emmc_wr_sector_ack)
                emmc_wr_sector_valid <= 1'b0;
            if (wr_sectors_ready != 5'd0 && !emmc_wr_sector_valid) begin
                emmc_wr_sector_valid <= 1'b1;
                wr_sectors_ready <= wr_sectors_ready - 5'd1;  // may be overridden by boundary
            end

            // Delayed bank increment: apply 1 cycle after sector boundary detection.
            // This ensures byte 511 (last byte of sector) is written to the CURRENT bank
            // before switching to the next. The write uses emmc_wr_bank via combinatorial
            // MUX (uart_buf_sel_w), so bank must stay stable until after we_b fires.
            if (wr_bank_inc_pending) begin
                emmc_wr_bank        <= emmc_wr_bank + 4'd1;
                wr_bank_inc_pending <= 1'b0;
            end

            // Pipeline registers (break timing-critical paths)
            emmc_rd_data_reg   <= emmc_rd_data;
            tx_busy_r          <= tx_busy;
            tx_start_d         <= tx_start;  // Delay tx_start by 1 cycle
            // Cross-module pipeline: resp_status/valid from emmc_controller
            // resp_valid_r is sticky (latched): set on emmc_resp_valid pulse,
            // cleared in TX_IDLE when processed. Prevents losing resp_valid
            // while TX FSM is busy sending sector data.
            if (emmc_resp_valid) begin
                resp_valid_r       <= 1'b1;
                resp_status_r      <= emmc_resp_status;
                resp_cmd_id_r      <= emmc_cmd_id;
                resp_card_status_r <= emmc_card_status;
                resp_status_is_ok  <= (emmc_resp_status == STATUS_OK);
            end

            // RX timeout: reset on rx_valid, overflow returns to RX_IDLE
            if (rx_valid || rx_state == RX_IDLE) begin
                rx_timeout_cnt <= 0;
                rx_timeout     <= 1'b0;
            end else begin
                rx_timeout_cnt <= rx_timeout_cnt + 1'b1;
                if (rx_timeout_cnt == {23{1'b1}})
                    rx_timeout <= 1'b1;
            end

            // Baud watchdog: revert to default baud if no valid packets
            // Only active when uart_clks_per_bit != 0 (non-default baud)
            if (uart_clks_per_bit == 8'd0) begin
                baud_watchdog_cnt <= 30'd0;
            end else if (rx_state == RX_EXEC1 && rx_crc_match) begin
                // Valid packet received — reset watchdog
                baud_watchdog_cnt <= 30'd0;
            end else if (baud_watchdog_cnt == {30{1'b1}}) begin
                // Watchdog expired (~18s @ 60MHz) — revert to default baud
                uart_clks_per_bit   <= 8'd0;
                current_baud_preset <= 2'd0;
                baud_switch_pending <= 1'b0;
                baud_watchdog_cnt   <= 30'd0;
            end else begin
                baud_watchdog_cnt <= baud_watchdog_cnt + 1'b1;
            end

            // =================================================
            // RX FSM - Parse incoming commands
            // =================================================
            if (rx_timeout && rx_state != RX_IDLE &&
                rx_state != RX_EXEC1 && rx_state != RX_EXEC2) begin
                rx_state       <= RX_IDLE;
                protocol_error <= 1'b1;
                // Clear write handshake state to prevent deadlock in eMMC controller
                wr_sectors_ready     <= 5'd0;
            end else
            case (rx_state)
                RX_IDLE: begin
                    protocol_error <= 1'b0;
                    early_write_dispatched <= 1'b0;
                    if (rx_valid) begin
                        if (rx_data == 8'hAA) begin
                            rx_state     <= RX_CMD;
                            rx_crc_clear <= 1'b1;
                        end
                    end
                end

                RX_CMD: begin
                    if (rx_valid) begin
                        rx_cmd_id    <= rx_data;
                        is_write_cmd <= (rx_data == CMD_WRITE_SECTOR);
                        rx_crc_en    <= 1'b1;
                        rx_state     <= RX_LEN_H;
                    end
                end

                RX_LEN_H: begin
                    if (rx_valid) begin
                        rx_payload_len[15:8] <= rx_data;
                        rx_crc_en <= 1'b1;
                        rx_state  <= RX_LEN_L;
                    end
                end

                RX_LEN_L: begin
                    if (rx_valid) begin
                        rx_payload_len[7:0] <= rx_data;
                        rx_crc_en <= 1'b1;
                        rx_payload_cnt <= {rx_payload_len[15:8], rx_data} - 1'b1;
                        rx_payload_last <= ({rx_payload_len[15:8], rx_data} == 16'd1);
                        rx_byte_num <= 4'd0;
                        emmc_wr_addr <= 9'h1FF;
                        if ({rx_payload_len[15:8], rx_data} == 16'd0)
                            rx_state <= RX_CRC;
                        else
                            rx_state <= RX_PAYLOAD;
                    end
                end

                RX_PAYLOAD: begin
                    if (rx_valid) begin
                        rx_crc_en <= 1'b1;

                        // rx_byte_num: saturating 0→8, tracks first payload bytes
                        if (!rx_byte_num[3])  // rx_byte_num < 8
                            rx_payload_buf[rx_byte_num[2:0]] <= rx_data;

                        // Multi-write: init sector tracking when count byte arrives
                        if (is_write_cmd && rx_byte_num == 4'd5) begin
                            wr_sectors_left     <= {rx_payload_buf[4], rx_data} - 1'b1;
                            wr_has_sectors_left <= ({rx_payload_buf[4], rx_data} > 16'd1);
                            wr_byte_in_sector   <= 9'd0;
                            wr_byte_is_last     <= 1'b0;
                            emmc_wr_bank        <= 4'd0;  // always start from bank 0
                            wr_sectors_ready    <= 5'd0;  // reset counter for new write
                        end

                        if (is_write_cmd && (rx_byte_num[3] || rx_byte_num >= 4'd6)) begin
                            emmc_wr_data <= rx_data;
                            emmc_wr_en   <= 1'b1;
                            emmc_wr_addr <= emmc_wr_addr + 1'b1;
                            wr_byte_in_sector <= wr_byte_in_sector + 1'b1;
                            // Pre-compute: will next byte be the last in sector?
                            wr_byte_is_last <= (wr_byte_in_sector == 9'd510);

                            // Sector boundary: after 512 bytes, signal next sector ready
                            // Uses pre-computed flags to avoid 9-bit and 16-bit comparators on critical path
                            if (wr_byte_is_last && wr_has_sectors_left) begin
                                if (!early_write_dispatched) begin
                                    // First sector boundary: early dispatch CMD25
                                    // LBA/COUNT from rx_payload_buf (filled at rx_byte_num 0-5)
                                    emmc_cmd_lba   <= {rx_payload_buf[0], rx_payload_buf[1],
                                                       rx_payload_buf[2], rx_payload_buf[3]};
                                    emmc_cmd_count <= {rx_payload_buf[4], rx_payload_buf[5]};
                                    emmc_cmd_id    <= CMD_WRITE_SECTOR;
                                    emmc_cmd_valid <= 1'b1;
                                    emmc_wr_sector_valid <= 1'b1;
                                    early_write_dispatched <= 1'b1;
                                end else begin
                                    // Subsequent boundaries: increment ready counter
                                    // Account for simultaneous promotion decrement via NBA override:
                                    // If promotion fires this cycle (-1), our +1 overrides it → net +1.
                                    // But we wanted net 0 (+1 -1). So check and adjust.
                                    if (wr_sectors_ready != 5'd0 && !emmc_wr_sector_valid)
                                        wr_sectors_ready <= wr_sectors_ready;  // +1 -1 = net 0
                                    else
                                        wr_sectors_ready <= wr_sectors_ready + 5'd1;
                                end
                                wr_sectors_left   <= wr_sectors_left - 1'b1;
                                wr_has_sectors_left <= (wr_sectors_left != 16'd1);
                                wr_byte_in_sector <= 9'd0;
                                wr_byte_is_last   <= 1'b0;
                                // Don't increment emmc_wr_bank here! Byte 511 write
                                // fires via NBA in this cycle, but sector_buf uses
                                // emmc_wr_bank combinatorially. Delay by 1 cycle.
                                wr_bank_inc_pending <= 1'b1;
                            end else if (wr_byte_is_last && !wr_has_sectors_left && early_write_dispatched) begin
                                // Last sector of multi-write completed: signal it via counter
                                if (wr_sectors_ready != 5'd0 && !emmc_wr_sector_valid)
                                    wr_sectors_ready <= wr_sectors_ready;  // +1 -1 = net 0
                                else
                                    wr_sectors_ready <= wr_sectors_ready + 5'd1;
                            end
                        end

                        // Update rx_byte_num (saturating at 8)
                        if (!rx_byte_num[3])
                            rx_byte_num <= rx_byte_num + 1'b1;

                        // Down-counter
                        rx_payload_cnt <= rx_payload_cnt - 1'b1;
                        rx_payload_last <= (rx_payload_cnt == 16'd1);
                        if (rx_payload_last)
                            rx_state <= RX_CRC;
                    end
                end

                RX_CRC: begin
                    if (rx_valid) begin
                        // rx_crc_match was pre-computed continuously
                        rx_crc_match <= (rx_data == rx_crc_out);
                        rx_state <= RX_EXEC1; // always go to EXEC1, check match there
                    end
                end

                // Stage 1: Check CRC match (registered), load info shift register.
                // Heavy work (256-bit load) happens here, TX params in stage 2.
                RX_EXEC1: begin
                    if (rx_crc_match) begin
                        // CRC OK - continue to exec
                        // Pre-load info shift register with CID+CSD
                        info_shift <= {emmc_cid, emmc_csd};

                        // Pre-extract LBA and count from payload buffer
                        emmc_cmd_lba   <= {rx_payload_buf[0], rx_payload_buf[1],
                                           rx_payload_buf[2], rx_payload_buf[3]};
                        emmc_cmd_count <= {rx_payload_buf[4], rx_payload_buf[5]};

                        rx_state <= RX_EXEC2;
                    end else begin
                        // CRC error - send error response
                        protocol_error <= 1'b1;
                        tx_start       <= 1'b1;
                        tx_cmd_id      <= rx_cmd_id;
                        tx_status      <= STATUS_ERR_CRC;
                        tx_payload_len <= 0;
                        tx_payload_src <= 0;
                        rx_state       <= RX_IDLE;
                    end
                end

                // Stage 2: Set TX parameters based on command.
                // All inputs are now registered (rx_cmd_id, emmc_cmd_lba, etc.)
                RX_EXEC2: begin
                    case (rx_cmd_id)
                        CMD_PING: begin
                            tx_start       <= 1'b1;
                            tx_cmd_id      <= CMD_PING;
                            tx_status      <= STATUS_OK;
                            tx_payload_len <= 0;
                            tx_payload_src <= 0;
                        end

                        CMD_GET_INFO: begin
                            // info_shift already loaded in EXEC1
                            tx_start       <= 1'b1;
                            tx_cmd_id      <= CMD_GET_INFO;
                            tx_status      <= emmc_info_valid ? STATUS_OK : STATUS_ERR_EMMC;
                            tx_payload_len <= 16'd32;
                            tx_payload_src <= 2'd1;
                        end

                        CMD_READ_SECTOR: begin
                            emmc_cmd_id    <= CMD_READ_SECTOR;
                            emmc_cmd_valid <= 1'b1;
                            sectors_remaining      <= emmc_cmd_count;
                            sectors_remaining_next <= emmc_cmd_count - 1'b1;
                            sectors_pending        <= (emmc_cmd_count != 0);
                        end

                        CMD_WRITE_SECTOR: begin
                            if (!early_write_dispatched) begin
                                // Single-sector write or count=1: normal dispatch
                                emmc_cmd_id    <= CMD_WRITE_SECTOR;
                                emmc_cmd_valid <= 1'b1;
                                // First sector: set valid directly (no counter delay)
                                // to match cmd_valid_d timing in emmc_controller
                                emmc_wr_sector_valid <= 1'b1;
                            end
                            // Multi-sector: already dispatched in RX_PAYLOAD
                        end

                        CMD_ERASE: begin
                            emmc_cmd_id    <= CMD_ERASE;
                            emmc_cmd_valid <= 1'b1;
                        end

                        CMD_GET_STATUS: begin
                            // 12-byte extended debug status
                            // Bytes 0-3: backward compatible
                            info_shift[255:248] <= emmc_resp_status;
                            info_shift[247:240] <= {emmc_dbg_init_state, 1'b0, emmc_dbg_mc_state[4:2]};
                            info_shift[239:232] <= {emmc_dbg_mc_state[1:0], emmc_info_valid, emmc_cmd_ready, 4'b0};
                            info_shift[231:224] <= {emmc_dbg_cmd_pin, emmc_dbg_dat0_pin, 6'b0};
                            // Bytes 4-11: new extended fields
                            info_shift[223:216] <= {emmc_dbg_cmd_fsm, emmc_dbg_dat_fsm, emmc_dbg_use_fast_clk};
                            info_shift[215:208] <= {emmc_dbg_partition, emmc_dbg_reinit_pending, 5'b0};
                            info_shift[207:200] <= emmc_dbg_err_cmd_timeout;
                            info_shift[199:192] <= emmc_dbg_err_cmd_crc;
                            info_shift[191:184] <= emmc_dbg_err_dat_rd;
                            info_shift[183:176] <= emmc_dbg_err_dat_wr;
                            info_shift[175:168] <= emmc_dbg_init_retry_cnt;
                            info_shift[167:160] <= {3'b0, current_baud_preset, emmc_dbg_clk_preset};
                            tx_start       <= 1'b1;
                            tx_cmd_id      <= CMD_GET_STATUS;
                            tx_status      <= STATUS_OK;
                            tx_payload_len <= 16'd12;
                            tx_payload_src <= 2'd1;
                        end

                        CMD_GET_EXT_CSD: begin
                            // Request Extended CSD (512 bytes) from eMMC controller
                            emmc_cmd_id    <= CMD_GET_EXT_CSD;
                            emmc_cmd_valid <= 1'b1;
                            // Response will come via sector buffer (512 bytes)
                            sectors_remaining      <= 16'd1;
                            sectors_remaining_next <= 16'd0;
                            sectors_pending        <= 1'b1;
                        end

                        CMD_SET_PARTITION: begin
                            // Partition ID in payload[0]: 0=user, 1=boot0, 2=boot1
                            emmc_cmd_id    <= CMD_SET_PARTITION;
                            emmc_cmd_lba   <= {24'd0, rx_payload_buf[0]}; // partition ID in LSB
                            emmc_cmd_valid <= 1'b1;
                        end

                        CMD_WRITE_EXT_CSD: begin
                            // Generic CMD6 SWITCH: index=payload[0], value=payload[1]
                            emmc_cmd_id    <= CMD_WRITE_EXT_CSD;
                            emmc_cmd_lba   <= {16'd0, rx_payload_buf[0], rx_payload_buf[1]};
                            emmc_cmd_valid <= 1'b1;
                        end

                        CMD_GET_CARD_STATUS: begin
                            // CMD13 SEND_STATUS: request card status register
                            emmc_cmd_id    <= CMD_GET_CARD_STATUS;
                            emmc_cmd_valid <= 1'b1;
                            // Set pending flag for TX path (avoids 8-bit compare on critical path)
                            card_status_pending <= 1'b1;
                        end

                        CMD_REINIT: begin
                            // Full re-initialization: CMD0 + init sequence
                            emmc_cmd_id    <= CMD_REINIT;
                            emmc_cmd_valid <= 1'b1;
                        end

                        CMD_SECURE_ERASE: begin
                            // Secure erase: same payload as ERASE (LBA+COUNT)
                            emmc_cmd_id    <= CMD_SECURE_ERASE;
                            emmc_cmd_valid <= 1'b1;
                        end

                        CMD_SET_CLK_DIV: begin
                            // Set eMMC clock speed: preset index in payload[0][2:0]
                            emmc_cmd_id    <= CMD_SET_CLK_DIV;
                            emmc_cmd_lba   <= {29'd0, rx_payload_buf[0][2:0]};
                            emmc_cmd_valid <= 1'b1;
                        end

                        CMD_SEND_RAW: begin
                            // payload[0]=CMD_INDEX, [1..4]=ARG (big-endian), [5]=FLAGS
                            emmc_cmd_id    <= CMD_SEND_RAW;
                            emmc_cmd_lba   <= {rx_payload_buf[1], rx_payload_buf[2],
                                               rx_payload_buf[3], rx_payload_buf[4]};
                            // Encode: cmd_count = {5'b0, FLAGS[2:0], 2'b0, CMD_INDEX[5:0]}
                            emmc_cmd_count <= {5'b0, rx_payload_buf[5][2:0],
                                               2'b0, rx_payload_buf[0][5:0]};
                            emmc_cmd_valid <= 1'b1;
                            raw_cmd_pending   <= 1'b1;
                            raw_resp_is_long  <= rx_payload_buf[5][1]; // FLAGS[1]
                            raw_resp_expected <= rx_payload_buf[5][0]; // FLAGS[0]
                        end

                        CMD_SET_RPMB_MODE: begin
                            // RPMB mode: payload[0] = 0 (normal) or 1 (force CMD25/CMD18)
                            emmc_cmd_id    <= CMD_SET_RPMB_MODE;
                            emmc_cmd_lba   <= {31'd0, rx_payload_buf[0][0]};
                            emmc_cmd_valid <= 1'b1;
                        end

                        CMD_SET_BAUD: begin
                            // Validate preset: must be 0-3 (upper bits zero), reject preset 2 (9M broken with FT2232HL)
                            if (rx_payload_buf[0][7:2] == 6'd0 && rx_payload_buf[0][1:0] <= 2'd3
                                && rx_payload_buf[0][1:0] != 2'd2) begin
                                baud_switch_cpb     <= baud_preset_to_cpb(rx_payload_buf[0][1:0]);
                                baud_switch_preset  <= rx_payload_buf[0][1:0];
                                baud_switch_pending <= 1'b1;
                                tx_start       <= 1'b1;
                                tx_cmd_id      <= CMD_SET_BAUD;
                                tx_status      <= STATUS_OK;
                                tx_payload_len <= 16'd0;
                                tx_payload_src <= 2'd0;
                            end else begin
                                tx_start       <= 1'b1;
                                tx_cmd_id      <= CMD_SET_BAUD;
                                tx_status      <= STATUS_ERR_CMD;
                                tx_payload_len <= 16'd0;
                                tx_payload_src <= 2'd0;
                            end
                        end

                        default: begin
                            protocol_error <= 1'b1;
                            tx_start       <= 1'b1;
                            tx_cmd_id      <= rx_cmd_id;
                            tx_status      <= STATUS_ERR_CMD;
                            tx_payload_len <= 0;
                            tx_payload_src <= 0;
                        end
                    endcase
                    rx_state <= RX_IDLE;
                end
            endcase

            // =================================================
            // TX FSM - Send response packets
            // =================================================
            case (tx_state)
                TX_IDLE: begin
                    if (tx_start_d) begin  // Use delayed tx_start so tx_cmd_id has settled
                        tx_state     <= TX_HEADER;
                        tx_crc_clear <= 1'b1;
                    end else if (emmc_rd_sector_ready && sectors_pending) begin
                        emmc_rd_sector_ack <= 1'b1;  // ack sticky rd_sector_ready
                        tx_cmd_id      <= CMD_READ_SECTOR;
                        tx_status      <= STATUS_OK;
                        tx_payload_len <= 16'd512;
                        tx_payload_src <= 2'd2;
                        tx_state       <= TX_HEADER;
                        tx_crc_clear   <= 1'b1;
                        sectors_remaining      <= sectors_remaining_next;
                        sectors_remaining_next <= sectors_remaining_next - 1'b1;
                        sectors_pending        <= (sectors_remaining > 16'd1);
                    end else if (resp_valid_r) begin
                        resp_valid_r   <= 1'b0;  // clear sticky latch
                        tx_cmd_id      <= resp_cmd_id_r;
                        tx_status      <= resp_status_r;
                        tx_crc_clear   <= 1'b1;
                        tx_state       <= TX_HEADER;
                        if (raw_cmd_pending && resp_status_is_ok) begin
                            // Raw CMD response: 0/4/16 bytes depending on flags
                            if (!raw_resp_expected) begin
                                // No response expected — 0 payload
                                tx_payload_len <= 16'd0;
                                tx_payload_src <= 2'd0;
                            end else if (raw_resp_is_long) begin
                                // R2 long: 16 bytes (128-bit)
                                info_shift <= {emmc_raw_resp, 128'd0};
                                tx_payload_len <= 16'd16;
                                tx_payload_src <= 2'd1;
                            end else begin
                                // R1 short: 4 bytes (card status)
                                info_shift[255:224] <= resp_card_status_r;
                                info_shift[223:0]   <= 224'd0;
                                tx_payload_len <= 16'd4;
                                tx_payload_src <= 2'd1;
                            end
                            raw_cmd_pending     <= 1'b0;
                            card_status_pending <= 1'b0;
                        end else if (raw_cmd_pending) begin
                            // Raw CMD error response — 0 payload
                            tx_payload_len <= 16'd0;
                            tx_payload_src <= 2'd0;
                            raw_cmd_pending     <= 1'b0;
                            card_status_pending <= 1'b0;
                        end else if (card_status_pending && resp_status_is_ok) begin
                            // 4-byte Card Status (pending flag avoids 8-bit cmd_id compare)
                            info_shift[255:224] <= resp_card_status_r;
                            tx_payload_len <= 16'd4;
                            tx_payload_src <= 2'd1;
                            card_status_pending <= 1'b0;
                        end else begin
                            tx_payload_len <= 16'd0;
                            tx_payload_src <= 2'd0;
                            card_status_pending <= 1'b0;
                        end
                    end
                end

                TX_HEADER: begin
                    if (!tx_busy) begin
                        tx_data  <= 8'h55;
                        tx_valid <= 1'b1;
                        tx_state <= TX_CMD;
                    end
                end

                TX_CMD: begin
                    if (!tx_busy && !tx_valid) begin
                        tx_data     <= tx_cmd_id;
                        tx_valid    <= 1'b1;
                        tx_crc_en   <= 1'b1;
                        tx_crc_data <= tx_cmd_id;
                        tx_state    <= TX_STATUS;
                    end
                end

                TX_STATUS: begin
                    if (!tx_busy && !tx_valid) begin
                        tx_data     <= tx_status;
                        tx_valid    <= 1'b1;
                        tx_crc_en   <= 1'b1;
                        tx_crc_data <= tx_status;
                        tx_state    <= TX_LEN_H;
                    end
                end

                TX_LEN_H: begin
                    if (!tx_busy && !tx_valid) begin
                        tx_data     <= tx_payload_len[15:8];
                        tx_valid    <= 1'b1;
                        tx_crc_en   <= 1'b1;
                        tx_crc_data <= tx_payload_len[15:8];
                        tx_state    <= TX_LEN_L;
                    end
                end

                TX_LEN_L: begin
                    if (!tx_busy && !tx_valid) begin
                        tx_data     <= tx_payload_len[7:0];
                        tx_valid    <= 1'b1;
                        tx_crc_en   <= 1'b1;
                        tx_crc_data <= tx_payload_len[7:0];
                        tx_payload_cnt <= tx_payload_len - 1'b1;
                        tx_payload_last <= (tx_payload_len == 16'd1);
                        emmc_rd_addr   <= 0;
                        if (tx_payload_len == 0)
                            tx_state <= TX_CRC;
                        else
                            tx_state <= TX_PAYLOAD;
                    end
                end

                TX_PAYLOAD: begin
                    if (!tx_busy && !tx_valid) begin
                        case (tx_payload_src)
                            2'd1: begin
                                // Shift register: MSB byte out first
                                tx_data     <= info_shift[255:248];
                                tx_crc_data <= info_shift[255:248];
                                info_shift  <= {info_shift[247:0], 8'd0};
                            end
                            2'd2: begin
                                tx_data     <= emmc_rd_data_reg;
                                tx_crc_data <= emmc_rd_data_reg;
                                emmc_rd_addr <= emmc_rd_addr + 1'b1;
                            end
                            default: begin
                                tx_data     <= 8'h00;
                                tx_crc_data <= 8'h00;
                            end
                        endcase
                        tx_valid  <= 1'b1;
                        tx_crc_en <= 1'b1;
                        tx_payload_cnt <= tx_payload_cnt - 1'b1;
                        tx_payload_last <= (tx_payload_cnt == 16'd1);
                        if (tx_payload_last)
                            tx_state <= TX_CRC;
                    end
                end

                TX_CRC: begin
                    if (!tx_busy && !tx_valid) begin
                        tx_data  <= tx_crc_out;
                        tx_valid <= 1'b1;
                        tx_state <= baud_switch_pending ? TX_BAUD_WAIT : TX_IDLE;
                    end
                end

                TX_BAUD_WAIT: begin
                    // Wait until CRC byte is fully transmitted, then apply new baud
                    if (!tx_busy && !tx_valid) begin
                        uart_clks_per_bit   <= baud_switch_cpb;
                        current_baud_preset <= baud_switch_preset;
                        baud_switch_pending <= 1'b0;
                        tx_state            <= TX_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
