// eMMC Host Controller
// Top-level module combining CMD, DAT, init FSM, clock generation, sector buffer
// Provides simple command interface for uart_bridge

module emmc_controller #(
    parameter CLK_FREQ = 60_000_000
)(
    input  wire         clk,          // system clock (60 MHz default)
    input  wire         rst_n,

    // Physical eMMC pins
    output wire         emmc_clk,     // eMMC clock output
    output wire         emmc_rstn,    // eMMC reset (active low)
    inout  wire         emmc_cmd_io,  // CMD bidirectional
    inout  wire         emmc_dat0_io, // DAT0 bidirectional (1-bit mode)

    // Command interface from uart_bridge
    input  wire         cmd_valid,     // new command
    input  wire [7:0]   cmd_id,        // command type
    input  wire [31:0]  cmd_lba,       // sector address
    input  wire [15:0]  cmd_count,     // sector count
    output reg          cmd_ready,     // ready for next command
    output reg  [7:0]   resp_status,   // status code
    output reg          resp_valid,    // response ready

    // Sector buffer interface - read path (UART reads from buffer)
    input  wire [8:0]   uart_rd_addr,
    output wire [7:0]   uart_rd_data,
    output reg          rd_sector_ready,
    input  wire         rd_sector_ack,

    // Sector buffer interface - write path (UART writes to buffer)
    input  wire [7:0]   uart_wr_data,
    input  wire [8:0]   uart_wr_addr,
    input  wire         uart_wr_en,
    input  wire         uart_wr_sector_valid,
    input  wire [3:0]   uart_wr_bank,       // current bank UART is writing to (0-15)
    output reg          wr_sector_ack,

    // Info outputs
    output wire [127:0] cid,
    output wire [127:0] csd,
    output wire         info_valid,

    // Card status (CMD13 result)
    output reg  [31:0]  card_status,

    // Raw command response (R2 128-bit data)
    output reg  [127:0] raw_resp_data,

    // Status
    output wire         active,        // eMMC bus activity
    output wire         ready,         // card initialized
    output wire         error,

    // Debug (original 4-byte)
    output wire [3:0]   dbg_init_state,
    output wire [4:0]   dbg_mc_state,
    output wire         dbg_cmd_pin,
    output wire         dbg_dat0_pin,

    // Debug (extended 8-byte)
    output wire [2:0]   dbg_cmd_fsm,
    output wire [3:0]   dbg_dat_fsm,
    output wire [1:0]   dbg_partition,
    output wire         dbg_use_fast_clk,
    output wire         dbg_reinit_pending,
    output wire [7:0]   dbg_err_cmd_timeout,
    output wire [7:0]   dbg_err_cmd_crc,
    output wire [7:0]   dbg_err_dat_rd,
    output wire [7:0]   dbg_err_dat_wr,
    output wire [7:0]   dbg_init_retry_cnt,
    output wire [2:0]   dbg_clk_preset
);

    // =========================================================
    // eMMC Clock Generator
    // =========================================================
    // Init clock: 60 MHz / (225*2) = ~133 kHz (< 400 kHz spec max)
    // Transfer clock: 60 MHz / (N*2), N from preset table
    localparam CLK_DIV_SLOW = 9'd225;  // ~133 kHz init
    localparam CLK_DIV_FAST = 9'd15;   // 2 MHz default (60MHz/(15*2))

    // Preset → divider lookup (pure combinational)
    function [8:0] preset_to_div;
        input [2:0] preset;
        case (preset)
            3'd0: preset_to_div = 9'd15;  // 2 MHz
            3'd1: preset_to_div = 9'd8;   // 3.75 MHz
            3'd2: preset_to_div = 9'd5;   // 6 MHz
            3'd3: preset_to_div = 9'd3;   // 10 MHz
            3'd4: preset_to_div = 9'd2;   // 15 MHz
            3'd5: preset_to_div = 9'd2;   // 15 MHz (same)
            3'd6: preset_to_div = 9'd1;   // 30 MHz
            default: preset_to_div = 9'd15;
        endcase
    endfunction

    reg         use_fast_clk;
    reg [8:0]   fast_clk_div_reload;   // configurable fast clock divider
    reg [2:0]   current_clk_preset;    // current preset index (0-6)
    reg [8:0]   clk_div_cnt;
    reg [8:0]   clk_div_reload; // pre-computed reload value
    reg         emmc_clk_reg;
    reg         clk_en;        // one pulse per eMMC CLK rising edge
    reg         clk_pause;     // pause eMMC CLK (backpressure during multi-block read)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div_cnt    <= CLK_DIV_SLOW - 1'b1;
            clk_div_reload <= CLK_DIV_SLOW - 1'b1;
            emmc_clk_reg   <= 1'b0;
            clk_en         <= 1'b0;
        end else begin
            clk_en <= 1'b0;
            if (clk_div_cnt == 0) begin
                clk_div_cnt  <= clk_div_reload;
                emmc_clk_reg <= ~emmc_clk_reg;
                if (!emmc_clk_reg) // rising edge
                    clk_en <= 1'b1;
            end else if (!clk_pause) begin
                clk_div_cnt <= clk_div_cnt - 1'b1;
            end
            // Update reload value when clock speed changes
            if (use_fast_clk)
                clk_div_reload <= fast_clk_div_reload;
            else
                clk_div_reload <= CLK_DIV_SLOW - 1'b1;
        end
    end

    assign emmc_clk = emmc_clk_reg;

    // =========================================================
    // CMD line tristate
    // =========================================================
    wire       cmd_out_w;
    wire       cmd_oe_w;
    wire       cmd_in_w;
    wire       cmd_in_raw;

    assign emmc_cmd_io = cmd_oe_w ? cmd_out_w : 1'bz;
    assign cmd_in_raw = emmc_cmd_io;

    // =========================================================
    // DAT0 tristate (1-bit mode)
    // =========================================================
    wire       dat_out_w;
    wire       dat_oe_w;
    wire       dat_in_w;
    wire       dat_in_raw;

    assign emmc_dat0_io = dat_oe_w ? dat_out_w : 1'bz;
    assign dat_in_raw = emmc_dat0_io;

    // =========================================================
    // Metastability synchronizers for eMMC inputs (2-stage FF)
    // =========================================================
    reg cmd_in_meta, cmd_in_sync;
    reg dat_in_meta, dat_in_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_in_meta <= 1'b1;
            cmd_in_sync <= 1'b1;
            dat_in_meta <= 1'b1;
            dat_in_sync <= 1'b1;
        end else begin
            cmd_in_meta <= cmd_in_raw;
            cmd_in_sync <= cmd_in_meta;
            dat_in_meta <= dat_in_raw;
            dat_in_sync <= dat_in_meta;
        end
    end

    assign cmd_in_w = cmd_in_sync;
    assign dat_in_w = dat_in_sync;

    // =========================================================
    // CMD Module
    // =========================================================
    reg         cmd_start;
    reg  [5:0]  cmd_index;
    reg  [31:0] cmd_argument;
    reg         cmd_resp_long;
    reg         cmd_resp_expected;
    wire        cmd_done;
    wire        cmd_timeout;
    wire        cmd_crc_err;
    wire        cmd_error = cmd_timeout || cmd_crc_err;
    wire [31:0] cmd_resp_status;
    wire [127:0] cmd_resp_data;
    wire [2:0]  cmd_dbg_state;

    emmc_cmd u_cmd (
        .clk            (clk),
        .rst_n          (rst_n),
        .clk_en         (clk_en),
        .cmd_start      (cmd_start),
        .cmd_index      (cmd_index),
        .cmd_argument   (cmd_argument),
        .resp_type_long (cmd_resp_long),
        .resp_expected  (cmd_resp_expected),
        .cmd_done       (cmd_done),
        .cmd_timeout    (cmd_timeout),
        .cmd_crc_err    (cmd_crc_err),
        .resp_status    (cmd_resp_status),
        .resp_data      (cmd_resp_data),
        .cmd_out        (cmd_out_w),
        .cmd_oe         (cmd_oe_w),
        .cmd_in         (cmd_in_w),
        .dbg_state      (cmd_dbg_state)
    );

    // =========================================================
    // DAT Module
    // =========================================================
    reg         dat_rd_start;
    wire        dat_rd_done;
    wire        dat_rd_crc_err;
    reg         dat_wr_start;
    wire        dat_wr_done;
    wire        dat_wr_crc_err;
    wire [3:0]  dat_dbg_state;
    wire [7:0]  dat_buf_wr_data;
    wire [8:0]  dat_buf_wr_addr;
    wire        dat_buf_wr_en;
    wire [8:0]  dat_buf_rd_addr;
    wire [7:0]  dat_buf_rd_data;

    emmc_dat u_dat (
        .clk         (clk),
        .rst_n       (rst_n),
        .clk_en      (clk_en),
        .rd_start    (dat_rd_start),
        .rd_done     (dat_rd_done),
        .rd_crc_err  (dat_rd_crc_err),
        .wr_start    (dat_wr_start),
        .wr_done     (dat_wr_done),
        .wr_crc_err  (dat_wr_crc_err),
        .buf_wr_data (dat_buf_wr_data),
        .buf_wr_addr (dat_buf_wr_addr),
        .buf_wr_en   (dat_buf_wr_en),
        .buf_rd_addr (dat_buf_rd_addr),
        .buf_rd_data (dat_buf_rd_data),
        .dat_out     (dat_out_w),
        .dat_oe      (dat_oe_w),
        .dat_in      (dat_in_w),
        .dbg_state   (dat_dbg_state)
    );

    // =========================================================
    // Init Module
    // =========================================================
    wire        init_cmd_start;
    wire [5:0]  init_cmd_index;
    wire [31:0] init_cmd_argument;
    wire        init_resp_long;
    wire        init_resp_expected;
    wire        init_done;
    wire        init_error;
    wire        init_use_fast_clk;
    wire        init_rstn;
    wire [127:0] init_cid;
    wire [127:0] init_csd;
    wire [15:0]  init_rca;
    wire         init_info_valid;
    wire [3:0]   init_state_dbg;
    wire [7:0]   init_retry_cnt;

    reg          init_start;

    emmc_init #(
        .CLK_FREQ(CLK_FREQ)
    ) u_init (
        .clk            (clk),
        .rst_n          (rst_n),
        .init_start     (init_start),
        .init_done      (init_done),
        .init_error     (init_error),
        .init_state_dbg (init_state_dbg),
        .cmd_start      (init_cmd_start),
        .cmd_index      (init_cmd_index),
        .cmd_argument   (init_cmd_argument),
        .resp_type_long (init_resp_long),
        .resp_expected  (init_resp_expected),
        .cmd_done       (cmd_done),
        .cmd_timeout    (cmd_timeout),
        .cmd_crc_err    (cmd_crc_err),
        .resp_status    (cmd_resp_status),
        .resp_data      (cmd_resp_data),
        .cid_reg        (init_cid),
        .csd_reg        (init_csd),
        .rca_reg        (init_rca),
        .info_valid     (init_info_valid),
        .use_fast_clk   (init_use_fast_clk),
        .emmc_rstn_out  (init_rstn),
        .dbg_retry_cnt  (init_retry_cnt)
    );

    assign emmc_rstn = init_rstn;
    assign cid = init_cid;
    assign csd = init_csd;
    assign info_valid = init_info_valid;

    // =========================================================
    // Sector Buffers
    // =========================================================
    // Read buffer (sector_buf): 2 banks x 512B, for eMMC→PC reads
    //   Port A: eMMC DAT writes incoming data
    //   Port B: UART reads data to send to PC
    // Write FIFO (sector_buf_wr): 16 banks x 512B, for PC→eMMC writes
    //   Port A: eMMC DAT reads data to send to card
    //   Port B: UART writes incoming data from PC
    wire [7:0] rd_buf_a_rdata;  // read buffer Port A output (unused externally)
    wire [7:0] wr_buf_rdata;    // write FIFO read output → DAT write path
    reg  [3:0] emmc_bank;       // 0-15: which bank eMMC is currently using

    // Read path: double-buffered bank index to prevent mid-transfer bank switch.
    // uart_rd_bank drives buf_sel_b — updated ONLY on rd_sector_ack (when UART starts new sector).
    // uart_rd_bank_next is staged in MC_READ_DAT when data arrives.
    reg [1:0] uart_rd_bank;
    reg [1:0] uart_rd_bank_next;

    // Read buffer (unchanged, 2 banks, for eMMC→PC reads)
    sector_buf u_sector_buf (
        .clk       (clk),
        .buf_sel_a (emmc_bank[1:0]),
        .addr_a    (dat_buf_wr_addr),
        .wdata_a   (dat_buf_wr_data),
        .we_a      (dat_buf_wr_en),
        .rdata_a   (rd_buf_a_rdata),
        .buf_sel_b (uart_rd_bank),
        .addr_b    (uart_rd_addr),
        .wdata_b   (8'd0),
        .we_b      (1'b0),
        .rdata_b   (uart_rd_data)
    );

    // Write FIFO (16 banks x 512B, for PC→eMMC writes)
    sector_buf_wr u_write_buf (
        .clk       (clk),
        .rd_bank   (emmc_bank),
        .rd_addr   (dat_buf_rd_addr),
        .rd_data   (wr_buf_rdata),
        .wr_bank   (uart_wr_bank),
        .wr_addr   (uart_wr_addr),
        .wr_data   (uart_wr_data),
        .wr_en     (uart_wr_en)
    );

    // DAT write path reads from write FIFO
    assign dat_buf_rd_data = wr_buf_rdata;

    // =========================================================
    // Main Controller FSM
    // =========================================================
    localparam MC_IDLE        = 5'd0;
    localparam MC_INIT        = 5'd1;
    localparam MC_READY       = 5'd2;
    localparam MC_READ_CMD    = 5'd3;
    localparam MC_READ_DAT    = 5'd4;
    localparam MC_READ_DONE   = 5'd5;
    localparam MC_WRITE_CMD   = 5'd6;
    localparam MC_WRITE_DAT   = 5'd7;
    localparam MC_WRITE_DONE  = 5'd8;
    localparam MC_STOP_CMD    = 5'd9;
    localparam MC_ERROR       = 5'd10;
    localparam MC_STOP_WAIT   = 5'd11;  // wait for CMD12 response
    localparam MC_EXT_CSD_CMD = 5'd12;  // send CMD8 for Extended CSD
    localparam MC_EXT_CSD_DAT = 5'd13;  // read 512 bytes of ExtCSD
    localparam MC_SWITCH_CMD  = 5'd14;  // send CMD6 SWITCH
    localparam MC_SWITCH_WAIT = 5'd15;  // wait for switch completion
    localparam MC_ERASE_START = 5'd16;  // CMD35 ERASE_GROUP_START
    localparam MC_ERASE_END   = 5'd17;  // CMD36 ERASE_GROUP_END
    localparam MC_ERASE_CMD   = 5'd18;  // CMD38 ERASE
    localparam MC_STATUS_CMD  = 5'd19;  // CMD13 SEND_STATUS
    localparam MC_ERROR_STOP  = 5'd20;  // CMD12 after multi-block error
    localparam MC_RAW_CMD    = 5'd21;  // Send arbitrary CMD (raw command)
    localparam MC_RAW_WAIT   = 5'd22;  // Optional DAT0 busy wait after raw CMD
    localparam MC_RPMB_CMD23 = 5'd23;  // CMD23 SET_BLOCK_COUNT before RPMB read/write
    localparam MC_RPMB_FIFO_WAIT = 5'd24; // Wait for write FIFO after CMD23

    // Response status codes
    localparam STATUS_OK       = 8'h00;
    localparam STATUS_CRC_ERR  = 8'h01;
    localparam STATUS_CMD_ERR  = 8'h02;
    localparam STATUS_EMMC_ERR = 8'h03;
    localparam STATUS_BUSY     = 8'h04;

    // RAW_CMD flags bit positions within cmd_count
    localparam RAW_FLAG_RESP_EXP  = 8;   // FLAGS[0]: response expected
    localparam RAW_FLAG_RESP_LONG = 9;   // FLAGS[1]: R2 long response
    localparam RAW_FLAG_BUSY_WAIT = 10;  // FLAGS[2]: poll DAT0 busy

    reg [4:0]  mc_state;
    reg [31:0] current_lba;
    reg [31:0] next_lba;
    reg [15:0] sectors_left;
    reg [31:0] erase_end_lba;  // Pre-computed CMD36 argument (pipelined for timing)
    reg        is_init_mode;    // CMD mux: 0=controller, 1=init
    reg        use_multi_block; // 1=CMD18/CMD25, 0=CMD17/CMD24
    reg        is_read_op;      // 1=read, 0=write (for STOP_CMD)
    reg [1:0]  current_partition; // 0=user, 1=boot0, 2=boot1, 3=RPMB
    reg        reinit_pending;   // RE-INIT in progress, send resp after init completes
    reg        erase_secure;     // 1=secure erase (CMD38 arg=0x80000000), 0=normal
    reg [1:0]  boot_retry_cnt;   // Auto-reinit retries on first boot (max 3)
    reg        raw_check_busy;   // FLAGS[2]: poll DAT0 after raw CMD response
    reg        raw_resp_long;    // FLAGS[1]: expect R2 (128-bit) response
    reg        force_multi_block; // RPMB mode: force CMD25/CMD18 even for count=1

    reg active_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            active_reg <= 1'b0;
        else
            active_reg <= (mc_state != MC_IDLE && mc_state != MC_READY);
    end
    assign active = active_reg;
    assign ready  = (mc_state == MC_READY);
    assign error  = (mc_state == MC_ERROR);
    assign dbg_init_state = init_state_dbg;
    assign dbg_mc_state   = mc_state;
    assign dbg_cmd_pin    = cmd_in_w;
    assign dbg_dat0_pin   = dat_in_w;

    // Extended debug outputs
    assign dbg_cmd_fsm        = cmd_dbg_state;
    assign dbg_dat_fsm        = dat_dbg_state;
    assign dbg_partition      = current_partition;
    assign dbg_use_fast_clk   = use_fast_clk;
    assign dbg_reinit_pending = reinit_pending;
    assign dbg_init_retry_cnt = init_retry_cnt;
    assign dbg_clk_preset     = current_clk_preset;

    // Saturating 8-bit error counters (separate always block, off critical path)
    reg [7:0] err_cmd_timeout_cnt;
    reg [7:0] err_cmd_crc_cnt;
    reg [7:0] err_dat_rd_cnt;
    reg [7:0] err_dat_wr_cnt;

    assign dbg_err_cmd_timeout = err_cmd_timeout_cnt;
    assign dbg_err_cmd_crc     = err_cmd_crc_cnt;
    assign dbg_err_dat_rd      = err_dat_rd_cnt;
    assign dbg_err_dat_wr      = err_dat_wr_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_cmd_timeout_cnt <= 8'd0;
            err_cmd_crc_cnt     <= 8'd0;
            err_dat_rd_cnt      <= 8'd0;
            err_dat_wr_cnt      <= 8'd0;
        end else if (reinit_pending && mc_state == MC_IDLE) begin
            // Clear on REINIT
            err_cmd_timeout_cnt <= 8'd0;
            err_cmd_crc_cnt     <= 8'd0;
            err_dat_rd_cnt      <= 8'd0;
            err_dat_wr_cnt      <= 8'd0;
        end else begin
            if (cmd_timeout && !(&err_cmd_timeout_cnt))
                err_cmd_timeout_cnt <= err_cmd_timeout_cnt + 1'b1;
            if (cmd_crc_err && !(&err_cmd_crc_cnt))
                err_cmd_crc_cnt <= err_cmd_crc_cnt + 1'b1;
            if (dat_rd_crc_err && !(&err_dat_rd_cnt))
                err_dat_rd_cnt <= err_dat_rd_cnt + 1'b1;
            if ((dat_wr_crc_err || wr_done_timeout) && !(&err_dat_wr_cnt))
                err_dat_wr_cnt <= err_dat_wr_cnt + 1'b1;
        end
    end

    // Pre-decoded cmd_id flags (registered, removes 8-bit compare from critical path)
    reg cmd_is_read;          // cmd_id == 8'h03
    reg cmd_is_write;         // cmd_id == 8'h04
    reg cmd_is_erase;         // cmd_id == 8'h05
    reg cmd_is_ext_csd;       // cmd_id == 8'h07
    reg cmd_is_partition;     // cmd_id == 8'h08
    reg cmd_is_write_ext_csd; // cmd_id == 8'h09
    reg cmd_is_status;        // cmd_id == 8'h0A
    reg cmd_is_reinit;        // cmd_id == 8'h0B
    reg cmd_is_secure_erase;  // cmd_id == 8'h0C
    reg cmd_is_set_clk;       // cmd_id == 8'h0D
    reg cmd_is_raw;           // cmd_id == 8'h0E
    reg cmd_is_set_rpmb_mode; // cmd_id == 8'h10

    // Pre-computed count==0 flag (registered, removes 16-bit NOR from critical CE path)
    // Safe: cmd_count is set 1 cycle before cmd_valid in uart_bridge (RX_EXEC1 vs RX_EXEC2)
    reg cmd_count_is_zero;
    // Pre-computed count>1 flag (registered, removes 16-bit comparator from MC_READY)
    reg cmd_count_gt_one;
    // Pre-computed count>16 flag: reject write with count>16 (16-bank write FIFO limit)
    reg cmd_count_gt_sixteen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_is_read          <= 1'b0;
            cmd_is_write         <= 1'b0;
            cmd_is_erase         <= 1'b0;
            cmd_is_ext_csd       <= 1'b0;
            cmd_is_partition     <= 1'b0;
            cmd_is_write_ext_csd <= 1'b0;
            cmd_is_status        <= 1'b0;
            cmd_is_reinit        <= 1'b0;
            cmd_is_secure_erase  <= 1'b0;
            cmd_is_set_clk       <= 1'b0;
            cmd_is_raw           <= 1'b0;
            cmd_is_set_rpmb_mode <= 1'b0;
            cmd_count_is_zero    <= 1'b1;
            cmd_count_gt_one     <= 1'b0;
            cmd_count_gt_sixteen   <= 1'b0;
        end else begin
            cmd_is_read          <= (cmd_id == 8'h03);
            cmd_is_write         <= (cmd_id == 8'h04);
            cmd_is_erase         <= (cmd_id == 8'h05);
            cmd_is_ext_csd       <= (cmd_id == 8'h07);
            cmd_is_partition     <= (cmd_id == 8'h08);
            cmd_is_write_ext_csd <= (cmd_id == 8'h09);
            cmd_is_status        <= (cmd_id == 8'h0A);
            cmd_is_reinit        <= (cmd_id == 8'h0B);
            cmd_is_secure_erase  <= (cmd_id == 8'h0C);
            cmd_is_set_clk       <= (cmd_id == 8'h0D);
            cmd_is_raw           <= (cmd_id == 8'h0E);
            cmd_is_set_rpmb_mode <= (cmd_id == 8'h10);
            cmd_count_is_zero    <= (cmd_count == 16'd0);
            cmd_count_gt_one     <= (cmd_count > 16'd1);
            cmd_count_gt_sixteen   <= (cmd_count > 16'd16);
        end
    end

    // Delayed cmd_valid and wr_sector_valid: gives cmd_is_* flags 1 extra cycle to settle
    // Fixes latent timing bug: uart_bridge sets cmd_id and cmd_valid in same cycle (RX_EXEC2),
    // but cmd_is_* registers from cmd_id — without delay, MC_READY sees stale flags
    reg cmd_valid_d;
    reg wr_sector_valid_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_valid_d       <= 1'b0;
            wr_sector_valid_d <= 1'b0;
        end else begin
            cmd_valid_d       <= cmd_valid;
            wr_sector_valid_d <= uart_wr_sector_valid;
        end
    end

    // Pre-computed eMMC command parameters (1-cycle pipeline from cmd_id/cmd_lba/cmd_count)
    // Runs every cycle; coherent with cmd_valid_d (both have same 1-cycle latency)
    // Uses cmd_id directly (not cmd_is_* flags) for correct pipeline alignment
    reg [31:0] pre_cmd_argument;
    reg [5:0]  pre_cmd_index;
    reg        pre_cmd_resp_exp;
    reg [31:0] pre_erase_end_lba; // pre-computed in erase branch only
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_cmd_argument  <= 32'd0;
            pre_cmd_index     <= 6'd0;
            pre_cmd_resp_exp  <= 1'b0;
            pre_erase_end_lba <= 32'd0;
        end else begin
            pre_cmd_resp_exp <= 1'b1; // default: expect response
            case (cmd_id)
                8'h03: begin // READ_SECTOR
                    pre_cmd_argument <= cmd_lba;
                    pre_cmd_index    <= (cmd_count > 16'd1 || force_multi_block) ? 6'd18 : 6'd17;
                end
                8'h04: begin // WRITE_SECTOR
                    pre_cmd_argument <= cmd_lba;
                    pre_cmd_index    <= (cmd_count > 16'd1 || force_multi_block) ? 6'd25 : 6'd24;
                end
                8'h05, 8'h0C: begin // ERASE, SECURE_ERASE
                    pre_cmd_argument <= cmd_lba;
                    pre_cmd_index    <= 6'd35;
                    pre_erase_end_lba <= cmd_lba + {16'd0, cmd_count} - 1'b1;
                end
                8'h07: begin // GET_EXT_CSD
                    pre_cmd_argument <= 32'd0;
                    pre_cmd_index    <= 6'd8;
                end
                8'h08: begin // SET_PARTITION (CMD6 index=179)
                    pre_cmd_argument <= {6'b0, 2'b11, 8'd179, cmd_lba[7:0], 8'b0};
                    pre_cmd_index    <= 6'd6;
                end
                8'h09: begin // WRITE_EXT_CSD (CMD6 generic)
                    pre_cmd_argument <= {6'b0, 2'b11, cmd_lba[15:8], cmd_lba[7:0], 8'b0};
                    pre_cmd_index    <= 6'd6;
                end
                8'h0A: begin // GET_CARD_STATUS (CMD13)
                    pre_cmd_argument <= status_arg;
                    pre_cmd_index    <= 6'd13;
                end
                8'h0E: begin // SEND_RAW_CMD
                    pre_cmd_argument <= cmd_lba;       // ARG passed via cmd_lba
                    pre_cmd_index    <= cmd_count[5:0]; // CMD_INDEX via cmd_count[5:0]
                    pre_cmd_resp_exp <= cmd_count[RAW_FLAG_RESP_EXP];   // FLAGS[0] = resp_expected
                end
                default: begin
                    pre_cmd_argument <= 32'd0;
                    pre_cmd_index    <= 6'd0;
                    pre_cmd_resp_exp <= 1'b0;
                end
            endcase
        end
    end

    // Main FSM registers
    reg        mc_cmd_start;
    reg [5:0]  mc_cmd_index;
    reg [31:0] mc_cmd_argument;
    reg        mc_cmd_resp_exp;

    // DAT0 busy wait timeout counter (~17.5ms at 60 MHz = ~1M cycles)
    reg [19:0] switch_wait_cnt;

    // Write-done watchdog: timeout if uart_wr_sector_valid doesn't arrive
    // 24-bit counter at 60 MHz = 16M cycles = ~280ms (> UART RX timeout 140ms)
    reg [23:0] wr_done_watchdog;
    reg        wr_done_timeout;  // 1-cycle pulse on watchdog timeout

    // Pre-computed CMD13 SEND_STATUS argument
    wire [31:0] status_arg = {init_rca, 16'h0000};

    // CMD mux: single always block to avoid multiple drivers
    always @(*) begin
        if (is_init_mode) begin
            cmd_start         = init_cmd_start;
            cmd_index         = init_cmd_index;
            cmd_argument      = init_cmd_argument;
            cmd_resp_long     = init_resp_long;
            cmd_resp_expected = init_resp_expected;
        end else begin
            cmd_start         = mc_cmd_start;
            cmd_index         = mc_cmd_index;
            cmd_argument      = mc_cmd_argument;
            cmd_resp_long     = raw_resp_long;
            cmd_resp_expected = mc_cmd_resp_exp;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mc_state         <= MC_IDLE;
            current_lba      <= 0;
            sectors_left     <= 0;
            is_init_mode     <= 1'b1;
            use_multi_block  <= 1'b0;
            is_read_op       <= 1'b0;
            current_partition<= 2'd0;  // user partition
            emmc_bank        <= 4'd0;  // start with bank 0
            init_start      <= 1'b0;
            use_fast_clk         <= 1'b0;
            fast_clk_div_reload  <= CLK_DIV_FAST - 1'b1;
            current_clk_preset   <= 3'd0;
            cmd_ready       <= 1'b0;
            resp_status     <= 0;
            resp_valid      <= 1'b0;
            rd_sector_ready <= 1'b0;
            uart_rd_bank      <= 2'd0;
            uart_rd_bank_next <= 2'd0;
            dat_rd_start    <= 1'b0;
            dat_wr_start    <= 1'b0;
            mc_cmd_start    <= 1'b0;
            mc_cmd_index    <= 6'd0;
            mc_cmd_argument <= 32'd0;
            mc_cmd_resp_exp <= 1'b0;
            next_lba        <= 1;
            switch_wait_cnt <= 0;
            wr_done_watchdog <= 0;
            wr_done_timeout  <= 1'b0;
            card_status     <= 32'd0;
            reinit_pending  <= 1'b0;
            erase_secure    <= 1'b0;
            boot_retry_cnt  <= 2'd0;
            raw_check_busy  <= 1'b0;
            raw_resp_long   <= 1'b0;
            raw_resp_data   <= 128'd0;
            force_multi_block <= 1'b0;
            wr_sector_ack   <= 1'b0;
            clk_pause       <= 1'b0;
        end else begin
            init_start      <= 1'b0;
            dat_rd_start    <= 1'b0;
            dat_wr_start    <= 1'b0;
            mc_cmd_start    <= 1'b0;
            resp_valid      <= 1'b0;
            wr_sector_ack   <= 1'b0;
            wr_done_timeout <= 1'b0;
            // rd_sector_ready: sticky level, cleared by ack from uart_bridge
            if (rd_sector_ack) begin
                rd_sector_ready <= 1'b0;
                uart_rd_bank    <= uart_rd_bank_next;  // promote staged bank on ACK
            end

            next_lba <= current_lba + 1'b1;

            case (mc_state)
                MC_IDLE: begin
                    is_init_mode <= 1'b1;
                    init_start   <= 1'b1;
                    mc_state     <= MC_INIT;
                end

                MC_INIT: begin
                    use_fast_clk <= init_use_fast_clk;
                    if (init_done) begin
                        is_init_mode <= 1'b0;
                        cmd_ready    <= 1'b1;
                        mc_state     <= MC_READY;
                        if (reinit_pending) begin
                            resp_status    <= 8'h00; // STATUS_OK
                            resp_valid     <= 1'b1;
                            reinit_pending <= 1'b0;
                        end
                    end else if (init_error) begin
                        if (reinit_pending) begin
                            resp_status    <= 8'h03; // STATUS_ERR_EMMC
                            resp_valid     <= 1'b1;
                            cmd_ready      <= 1'b1;
                            reinit_pending <= 1'b0;
                            mc_state       <= MC_READY;
                        end else if (boot_retry_cnt < 2'd3) begin
                            // First boot — auto-retry init (card may need more power-up time)
                            boot_retry_cnt <= boot_retry_cnt + 1'b1;
                            mc_state       <= MC_IDLE;
                        end else begin
                            mc_state <= MC_ERROR;
                        end
                    end
                end

                MC_READY: begin
                    if (cmd_valid_d) begin
                        cmd_ready <= 1'b0;

                        // Pre-computed eMMC command parameters — simple register loads
                        // (MUX was moved to pre_cmd_* pipeline, off critical path)
                        mc_cmd_argument <= pre_cmd_argument;
                        mc_cmd_index    <= pre_cmd_index;
                        mc_cmd_resp_exp <= pre_cmd_resp_exp;

                        // Count=0 validation (read/write/erase)
                        if ((cmd_is_read || cmd_is_write || cmd_is_erase || cmd_is_secure_erase)
                            && cmd_count_is_zero) begin
                            resp_status <= STATUS_CMD_ERR; // ERR_CMD: invalid count
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                        end
                        else if (cmd_is_read) begin
                            current_lba     <= cmd_lba;
                            sectors_left    <= cmd_count;
                            is_read_op      <= 1'b1;
                            use_multi_block <= cmd_count_gt_one || force_multi_block;
                            mc_state        <= force_multi_block ? MC_RPMB_CMD23 : MC_READ_CMD;
                        end
                        else if (cmd_is_write && cmd_count_gt_sixteen) begin
                            resp_status <= STATUS_CMD_ERR; // ERR_CMD: write count > 16 (16-bank FIFO limit)
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                        end
                        else if (cmd_is_write) begin
                            current_lba     <= cmd_lba;
                            sectors_left    <= cmd_count;
                            is_read_op      <= 1'b0;
                            use_multi_block <= cmd_count_gt_one || force_multi_block;
                            emmc_bank       <= 4'd0;  // UART always fills from bank 0
                            if (force_multi_block)
                                mc_state <= MC_RPMB_CMD23;  // CMD23 while UART fills FIFO
                            else if (wr_sector_valid_d)
                                mc_state <= MC_WRITE_CMD;
                        end
                        else if (cmd_is_ext_csd) begin
                            mc_state <= MC_EXT_CSD_CMD;
                        end
                        else if (cmd_is_erase || cmd_is_secure_erase) begin
                            current_lba   <= cmd_lba;
                            sectors_left  <= cmd_count;
                            erase_secure  <= cmd_is_secure_erase;
                            erase_end_lba <= pre_erase_end_lba;
                            mc_state      <= MC_ERASE_START;
                        end
                        else if (cmd_is_partition) begin
                            current_partition <= cmd_lba[1:0];
                            mc_state <= MC_SWITCH_CMD;
                        end
                        else if (cmd_is_write_ext_csd) begin
                            mc_state <= MC_SWITCH_CMD;
                        end
                        else if (cmd_is_status) begin
                            mc_state <= MC_STATUS_CMD;
                        end
                        else if (cmd_is_reinit) begin
                            reinit_pending <= 1'b1;
                            use_fast_clk   <= 1'b0;
                            mc_state       <= MC_IDLE;
                        end
                        else if (cmd_is_set_clk) begin
                            if (cmd_lba[2:0] <= 3'd6) begin
                                fast_clk_div_reload <= preset_to_div(cmd_lba[2:0]) - 1'b1;
                                current_clk_preset  <= cmd_lba[2:0];
                                resp_status <= STATUS_OK; // STATUS_OK
                            end else begin
                                resp_status <= STATUS_CMD_ERR; // ERR_CMD: invalid preset
                            end
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                        end
                        else if (cmd_is_set_rpmb_mode) begin
                            force_multi_block <= cmd_lba[0]; // 0=normal, 1=force CMD25/CMD18
                            resp_status <= STATUS_OK; // STATUS_OK
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                        end
                        else if (cmd_is_raw) begin
                            raw_check_busy <= cmd_count[RAW_FLAG_BUSY_WAIT]; // FLAGS[2]
                            raw_resp_long  <= cmd_count[RAW_FLAG_RESP_LONG];  // FLAGS[1]
                            mc_state       <= MC_RAW_CMD;
                        end
                        else begin
                            resp_status <= STATUS_CMD_ERR; // ERR_CMD
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                        end
                    end
                end

                MC_READ_CMD: begin
                    // Send CMD17 (single-block) or CMD18 (multi-block read)
                    is_init_mode <= 1'b0;
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            dat_rd_start <= 1'b1;
                            mc_state <= MC_READ_DAT;
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                MC_READ_DAT: begin
                    if (dat_rd_done) begin
                        if (dat_rd_crc_err) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            rd_sector_ready   <= 1'b1;
                            uart_rd_bank_next <= emmc_bank[1:0];    // stage bank (promoted on ACK)
                            emmc_bank         <= emmc_bank + 4'd1;  // advance to next bank
                            sectors_left      <= sectors_left - 1'b1;
                            current_lba       <= next_lba;
                            mc_cmd_argument   <= next_lba;
                            mc_state <= MC_READ_DONE;
                        end
                    end
                end

                MC_READ_DONE: begin
                    if (sectors_left == 0) begin
                        // All sectors read
                        clk_pause <= 1'b0;
                        if (use_multi_block && !force_multi_block) begin
                            // CMD12 STOP_TRANSMISSION required for CMD18 (open-ended)
                            // Not needed when CMD23 was used — card auto-terminates
                            mc_cmd_index    <= 6'd12;
                            mc_cmd_argument <= 32'd0;
                            mc_cmd_resp_exp <= 1'b1;
                            mc_state        <= MC_STOP_CMD;
                        end else begin
                            resp_status <= STATUS_OK;
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                            mc_state    <= MC_READY;
                        end
                    end else begin
                        // More sectors to read
                        if (use_multi_block) begin
                            // Multi-block: backpressure — pause eMMC CLK while UART drains
                            if (!rd_sector_ready || rd_sector_ack) begin
                                clk_pause    <= 1'b0;  // resume CLK
                                dat_rd_start <= 1'b1;
                                mc_state     <= MC_READ_DAT;
                            end else begin
                                clk_pause <= 1'b1;  // pause CLK while UART drains
                            end
                        end else begin
                            // Single-block: issue new CMD17
                            mc_state <= MC_READ_CMD;
                        end
                    end
                end

                MC_WRITE_CMD: begin
                    // Send CMD24 (single-block) or CMD25 (multi-block write)
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            dat_wr_start <= 1'b1;
                            mc_state <= MC_WRITE_DAT;
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                MC_WRITE_DAT: begin
                    if (dat_wr_done) begin
                        if (dat_wr_crc_err) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            sectors_left    <= sectors_left - 1'b1;
                            current_lba     <= next_lba;
                            mc_cmd_argument <= next_lba;
                            wr_done_watchdog <= 0;
                            mc_state <= MC_WRITE_DONE;
                        end
                    end
                end

                MC_WRITE_DONE: begin
                    if (sectors_left == 0) begin
                        // All sectors written
                        wr_done_watchdog <= 0;
                        if (use_multi_block && !force_multi_block) begin
                            // CMD12 STOP_TRANSMISSION required for CMD25 (open-ended)
                            // Not needed when CMD23 was used — card auto-terminates
                            mc_cmd_index    <= 6'd12;
                            mc_cmd_argument <= 32'd0;
                            mc_cmd_resp_exp <= 1'b1;
                            mc_state        <= MC_STOP_CMD;
                        end else begin
                            resp_status <= STATUS_OK;
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                            mc_state    <= MC_READY;
                        end
                    end else begin
                        // More sectors to write — wait for next sector data
                        // Watchdog: if UART bridge doesn't provide data within ~280ms,
                        // abort multi-write with CMD12 + error (prevents deadlock on
                        // broken UART connection)
                        wr_done_watchdog <= wr_done_watchdog + 1'b1;
                        if (wr_done_watchdog == {24{1'b1}}) begin
                            // Timeout — abort write
                            if (use_multi_block) begin
                                mc_cmd_index    <= 6'd12;
                                mc_cmd_argument <= 32'd0;
                                mc_cmd_resp_exp <= 1'b1;
                                mc_state        <= MC_ERROR_STOP;
                            end else begin
                                resp_status <= STATUS_EMMC_ERR; // ERR_EMMC
                                resp_valid  <= 1'b1;
                                cmd_ready   <= 1'b1;
                                mc_state    <= MC_READY;
                            end
                            wr_done_timeout <= 1'b1;
                        end else if (use_multi_block) begin
                            // Multi-block: wait for next sector data, then continue DAT
                            if (uart_wr_sector_valid) begin
                                wr_done_watchdog <= 0;
                                wr_sector_ack <= 1'b1;
                                emmc_bank     <= emmc_bank + 4'd1;  // advance to next bank
                                dat_wr_start  <= 1'b1;
                                mc_state      <= MC_WRITE_DAT;
                            end
                        end else begin
                            // Single-block: wait for sector then issue new CMD24
                            if (uart_wr_sector_valid) begin
                                wr_done_watchdog <= 0;
                                wr_sector_ack <= 1'b1;
                                emmc_bank     <= emmc_bank + 4'd1;  // advance to next bank
                                mc_state <= MC_WRITE_CMD;
                            end
                        end
                    end
                end

                MC_STOP_CMD: begin
                    // Send CMD12 (STOP_TRANSMISSION) — R1b response
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            switch_wait_cnt <= 0;
                            mc_state <= MC_STOP_WAIT;
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                MC_STOP_WAIT: begin
                    // Poll DAT0: card holds low while busy (R1b), releases high when done
                    if (clk_en) begin
                        if (dat_in_w == 1'b1) begin
                            // DAT0 released — stop complete
                            resp_status <= STATUS_OK;
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                            mc_state    <= MC_READY;
                        end else begin
                            switch_wait_cnt <= switch_wait_cnt + 1'b1;
                            if (switch_wait_cnt == 20'hF_FFFF) begin
                                // Timeout — report error
                                resp_status <= STATUS_EMMC_ERR;
                                mc_state    <= MC_ERROR;
                            end
                        end
                    end
                end

                // ===========================================
                // Extended CSD (CMD8 SEND_EXT_CSD)
                // ===========================================
                MC_EXT_CSD_CMD: begin
                    // Send CMD8 - reads 512-byte Extended CSD
                    is_init_mode <= 1'b0;
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            dat_rd_start <= 1'b1;
                            mc_state <= MC_EXT_CSD_DAT;
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                MC_EXT_CSD_DAT: begin
                    // Read 512 bytes of ExtCSD into sector buffer
                    if (dat_rd_done) begin
                        if (dat_rd_crc_err) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            rd_sector_ready   <= 1'b1;
                            uart_rd_bank_next <= emmc_bank[1:0];    // stage bank (promoted on ACK)
                            emmc_bank         <= emmc_bank + 4'd1;  // advance so UART reads correct bank
                            resp_status     <= 8'h00;
                            resp_valid      <= 1'b1;
                            cmd_ready       <= 1'b1;
                            mc_state        <= MC_READY;
                        end
                    end
                end

                // ===========================================
                // Partition Switch (CMD6 SWITCH)
                // ===========================================
                MC_SWITCH_CMD: begin
                    // Send CMD6 SWITCH
                    is_init_mode <= 1'b0;
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            // Wait for DAT0 busy signal to clear
                            switch_wait_cnt <= 0;
                            mc_state <= MC_SWITCH_WAIT;
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                MC_SWITCH_WAIT: begin
                    // Poll DAT0: card holds low while busy, releases high when done
                    if (clk_en) begin
                        if (dat_in_w == 1'b1) begin
                            // DAT0 released — switch complete
                            resp_status <= STATUS_OK;
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                            mc_state    <= MC_READY;
                        end else begin
                            switch_wait_cnt <= switch_wait_cnt + 1'b1;
                            if (switch_wait_cnt == 20'hF_FFFF) begin
                                // Timeout (~10ms) — report error
                                resp_status <= STATUS_EMMC_ERR;
                                mc_state    <= MC_ERROR;
                            end
                        end
                    end
                end

                // ===========================================
                // Erase (CMD35 → CMD36 → CMD38 + busy)
                // ===========================================
                MC_ERASE_START: begin
                    // Send CMD35 ERASE_GROUP_START
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            // CMD36 ERASE_GROUP_END: use pre-computed end address
                            mc_cmd_index    <= 6'd36;
                            mc_cmd_argument <= erase_end_lba;
                            mc_state        <= MC_ERASE_END;
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                MC_ERASE_END: begin
                    // Send CMD36 ERASE_GROUP_END
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            // CMD38 ERASE (arg=0 normal, arg=0x80000000 secure)
                            mc_cmd_index    <= 6'd38;
                            mc_cmd_argument <= erase_secure ? 32'h8000_0000 : 32'd0;
                            mc_state        <= MC_ERASE_CMD;
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                MC_ERASE_CMD: begin
                    // Send CMD38 ERASE, then wait for DAT0 busy
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            switch_wait_cnt <= 0;
                            mc_state <= MC_SWITCH_WAIT;
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                // ===========================================
                // Card Status (CMD13 SEND_STATUS)
                // ===========================================
                MC_STATUS_CMD: begin
                    // Send CMD13 SEND_STATUS, capture Card Status Register
                    is_init_mode <= 1'b0;
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else begin
                            card_status <= cmd_resp_status;
                            resp_status <= STATUS_OK;
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                            mc_state    <= MC_READY;
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                // ===========================================
                // RPMB CMD23 SET_BLOCK_COUNT (internal)
                // Sends CMD23 back-to-back before CMD25/CMD18
                // ===========================================
                MC_RPMB_CMD23: begin
                    if (cmd_done) begin
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR;
                            mc_state <= MC_ERROR;
                        end else if (is_read_op) begin
                            mc_cmd_index    <= pre_cmd_index;    // CMD18
                            mc_cmd_argument <= pre_cmd_argument; // LBA
                            mc_cmd_resp_exp <= 1'b1;
                            mc_state        <= MC_READ_CMD;
                        end else if (wr_sector_valid_d) begin
                            mc_cmd_index    <= pre_cmd_index;    // CMD25
                            mc_cmd_argument <= pre_cmd_argument; // LBA
                            mc_cmd_resp_exp <= 1'b1;
                            mc_state        <= MC_WRITE_CMD;
                        end else begin
                            // CMD23 done, but FIFO not ready yet — wait
                            wr_done_watchdog <= 0;
                            mc_state <= MC_RPMB_FIFO_WAIT;
                        end
                    end else begin
                        // Send CMD23: arg = block_count (reliable write bit for writes)
                        mc_cmd_index    <= 6'd23;
                        mc_cmd_argument <= is_read_op ? 32'h0000_0001 : 32'h8000_0001;
                        mc_cmd_resp_exp <= 1'b1;
                        mc_cmd_start    <= 1'b1;
                    end
                end

                MC_RPMB_FIFO_WAIT: begin
                    // Wait for write FIFO data after CMD23 completed
                    if (wr_sector_valid_d) begin
                        wr_done_watchdog <= 0;
                        mc_cmd_index    <= pre_cmd_index;    // CMD25
                        mc_cmd_argument <= pre_cmd_argument; // LBA
                        mc_cmd_resp_exp <= 1'b1;
                        mc_state        <= MC_WRITE_CMD;
                    end else begin
                        // Watchdog: abort if UART doesn't provide data within ~280ms
                        // Reuses wr_done_watchdog (free in this state, same 24-bit width)
                        wr_done_watchdog <= wr_done_watchdog + 1'b1;
                        if (wr_done_watchdog == {24{1'b1}}) begin
                            resp_status <= STATUS_EMMC_ERR;
                            wr_done_timeout <= 1'b1;
                            // CMD23 already sent — card expects CMD25, send error response
                            // No CMD12 needed: CMD23 set block count, no open-ended transfer
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                            mc_state    <= MC_READY;
                        end
                    end
                end

                // ===========================================
                // Raw CMD (arbitrary eMMC command)
                // ===========================================
                MC_RAW_CMD: begin
                    if (cmd_done) begin
                        raw_resp_long <= 1'b0; // clear for CMD mux safety
                        if (cmd_error) begin
                            resp_status <= STATUS_EMMC_ERR; // ERR_EMMC
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                            mc_state    <= MC_READY;
                        end else begin
                            card_status   <= cmd_resp_status; // R1 short response
                            raw_resp_data <= cmd_resp_data;   // R2 long response
                            if (raw_check_busy) begin
                                switch_wait_cnt <= 0;
                                mc_state <= MC_RAW_WAIT;
                            end else begin
                                resp_status <= STATUS_OK;
                                resp_valid  <= 1'b1;
                                cmd_ready   <= 1'b1;
                                mc_state    <= MC_READY;
                            end
                        end
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end

                MC_RAW_WAIT: begin
                    // Poll DAT0: card holds low while busy, releases high when done
                    if (clk_en) begin
                        if (dat_in_w == 1'b1) begin
                            resp_status <= STATUS_OK;
                            resp_valid  <= 1'b1;
                            cmd_ready   <= 1'b1;
                            mc_state    <= MC_READY;
                        end else begin
                            switch_wait_cnt <= switch_wait_cnt + 1'b1;
                            if (switch_wait_cnt == 20'hF_FFFF) begin
                                resp_status <= STATUS_EMMC_ERR;
                                mc_state    <= MC_ERROR;
                            end
                        end
                    end
                end

                MC_ERROR: begin
                    if (use_multi_block) begin
                        // Send CMD12 STOP_TRANSMISSION before returning
                        mc_cmd_index    <= 6'd12;
                        mc_cmd_argument <= 32'd0;
                        mc_cmd_resp_exp <= 1'b1;
                        mc_state        <= MC_ERROR_STOP;
                    end else begin
                        resp_valid <= 1'b1;
                        cmd_ready  <= 1'b1;
                        mc_state   <= MC_READY;
                    end
                end

                MC_ERROR_STOP: begin
                    // Send CMD12 after multi-block error, preserve resp_status
                    if (cmd_done) begin
                        resp_valid <= 1'b1;
                        cmd_ready  <= 1'b1;
                        mc_state   <= MC_READY;
                    end else begin
                        mc_cmd_start <= 1'b1;
                    end
                end
            endcase

        end
    end

endmodule
