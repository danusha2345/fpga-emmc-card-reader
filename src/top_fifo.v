// Top Module - eMMC Card Reader on Tang Nano 9K (FT245 FIFO variant)
// GW1NR-9 QN88P
// Replaces UART transport with FT232H async 245 FIFO (~8 MB/s vs ~600 KB/s)

module top (
    input  wire       clk_27m,      // 27 MHz crystal oscillator

    // FT245 FIFO (FT232H, async 245 mode)
    inout  wire [7:0] fifo_d,       // Bidirectional data D[7:0]
    input  wire       fifo_rxf_n,   // RXF# : FT has data (active low)
    input  wire       fifo_txe_n,   // TXE# : FT has room (active low)
    output wire       fifo_rd_n,    // RD#  : read strobe (active low)
    output wire       fifo_wr_n,    // WR#  : write strobe (active low)

    // LEDs (active low)
    output wire [5:0] led,

    // Buttons (active low)
    input  wire       btn_s1,       // Reset
    input  wire       btn_s2,       // Mode (reserved)

    // eMMC interface (BANK3, 1.8V)
    output wire       emmc_clk,
    output wire       emmc_rstn,
    inout  wire       emmc_cmd,
    inout  wire       emmc_dat0,
    inout  wire       emmc_dat1,
    inout  wire       emmc_dat2,
    inout  wire       emmc_dat3
);

    // =========================================================
    // PLL: 27 MHz -> 60 MHz
    // =========================================================
    wire sys_clk;
    wire pll_lock;

    pll u_pll (
        .clkin  (clk_27m),
        .clkout (sys_clk),
        .lock   (pll_lock)
    );

    // =========================================================
    // Reset
    // =========================================================
    wire rst_n_raw = btn_s1 & pll_lock;

    reg [2:0] rst_sync;
    always @(posedge sys_clk or negedge rst_n_raw) begin
        if (!rst_n_raw)
            rst_sync <= 3'b000;
        else
            rst_sync <= {rst_sync[1:0], 1'b1};
    end
    wire rst_n = rst_sync[2];

    // =========================================================
    // Tristate buffers for eMMC CMD and DAT[3:0]
    // =========================================================
    wire emmc_cmd_out, emmc_cmd_oe, emmc_cmd_in;
    wire [3:0] emmc_dat_out;
    wire [3:0] emmc_dat_in;
    wire       emmc_dat_oe;

    assign emmc_cmd    = emmc_cmd_oe ? emmc_cmd_out : 1'bz;
    assign emmc_cmd_in = emmc_cmd;

    assign emmc_dat0      = emmc_dat_oe ? emmc_dat_out[0] : 1'bz;
    assign emmc_dat_in[0] = emmc_dat0;
    assign emmc_dat1      = emmc_dat_oe ? emmc_dat_out[1] : 1'bz;
    assign emmc_dat2      = emmc_dat_oe ? emmc_dat_out[2] : 1'bz;
    assign emmc_dat3      = emmc_dat_oe ? emmc_dat_out[3] : 1'bz;
    assign emmc_dat_in[1] = emmc_dat1;
    assign emmc_dat_in[2] = emmc_dat2;
    assign emmc_dat_in[3] = emmc_dat3;

    // =========================================================
    // Tristate buffer for FT245 FIFO data bus
    // =========================================================
    wire [7:0] fifo_data_write;
    wire [7:0] fifo_data_read;
    wire       fifo_data_oe;

    assign fifo_d         = fifo_data_oe ? fifo_data_write : 8'bz;
    assign fifo_data_read = fifo_d;

    // =========================================================
    // eMMC Controller (SpinalHDL-generated)
    // =========================================================
    wire        emmc_cmd_valid;
    wire [7:0]  emmc_cmd_id;
    wire [31:0] emmc_cmd_lba;
    wire [15:0] emmc_cmd_count;
    wire        emmc_cmd_ready;
    wire [7:0]  emmc_resp_status;
    wire        emmc_resp_valid;
    wire [8:0]  emmc_rd_addr;
    wire [7:0]  emmc_rd_data;
    wire        emmc_rd_sector_ready;
    wire        emmc_rd_sector_ack;
    wire [7:0]  emmc_wr_data;
    wire [8:0]  emmc_wr_addr;
    wire        emmc_wr_en;
    wire        emmc_wr_sector_valid;
    wire        emmc_wr_sector_ack;
    wire [3:0]  emmc_wr_bank;
    wire [127:0] emmc_cid;
    wire [127:0] emmc_csd;
    wire         emmc_info_valid;
    wire         emmc_active;
    wire         emmc_ready;
    wire         emmc_error;
    wire [31:0]  emmc_card_status;
    wire [127:0] emmc_raw_resp;
    wire [3:0]   emmc_dbg_init_state;
    wire [4:0]   emmc_dbg_mc_state;
    wire         emmc_dbg_cmd_pin;
    wire         emmc_dbg_dat0_pin;
    wire [2:0]   emmc_dbg_cmd_fsm;
    wire [3:0]   emmc_dbg_dat_fsm;
    wire [1:0]   emmc_dbg_partition;
    wire         emmc_dbg_use_fast_clk;
    wire         emmc_dbg_reinit_pending;
    wire [7:0]   emmc_dbg_err_cmd_timeout;
    wire [7:0]   emmc_dbg_err_cmd_crc;
    wire [7:0]   emmc_dbg_err_dat_rd;
    wire [7:0]   emmc_dbg_err_dat_wr;
    wire [7:0]   emmc_dbg_init_retry_cnt;
    wire [2:0]   emmc_dbg_clk_preset;

    emmc_controller u_emmc (
        .clk                (sys_clk),
        .resetn             (rst_n),
        .emmcClk            (emmc_clk),
        .emmcRstn           (emmc_rstn),
        .cmdOut             (emmc_cmd_out),
        .cmdOe              (emmc_cmd_oe),
        .cmdIn              (emmc_cmd_in),
        .datOut             (emmc_dat_out),
        .datOe              (emmc_dat_oe),
        .datIn              (emmc_dat_in),
        .cmdValid           (emmc_cmd_valid),
        .cmdId              (emmc_cmd_id),
        .cmdLba             (emmc_cmd_lba),
        .cmdCount           (emmc_cmd_count),
        .cmdReady           (emmc_cmd_ready),
        .respStatus         (emmc_resp_status),
        .respValid          (emmc_resp_valid),
        .uartRdAddr         (emmc_rd_addr),
        .uartRdData         (emmc_rd_data),
        .rdSectorReady      (emmc_rd_sector_ready),
        .rdSectorAck        (emmc_rd_sector_ack),
        .uartWrData         (emmc_wr_data),
        .uartWrAddr         (emmc_wr_addr),
        .uartWrEn           (emmc_wr_en),
        .uartWrSectorValid  (emmc_wr_sector_valid),
        .uartWrBank         (emmc_wr_bank),
        .wrSectorAck        (emmc_wr_sector_ack),
        .cid                (emmc_cid),
        .csd                (emmc_csd),
        .infoValid          (emmc_info_valid),
        .cardStatus         (emmc_card_status),
        .rawRespData        (emmc_raw_resp),
        .active             (emmc_active),
        .ready              (emmc_ready),
        .error              (emmc_error),
        .dbgInitState       (emmc_dbg_init_state),
        .dbgMcState         (emmc_dbg_mc_state),
        .dbgCmdPin          (emmc_dbg_cmd_pin),
        .dbgDat0Pin         (emmc_dbg_dat0_pin),
        .dbgCmdFsm          (emmc_dbg_cmd_fsm),
        .dbgDatFsm          (emmc_dbg_dat_fsm),
        .dbgPartition       (emmc_dbg_partition),
        .dbgUseFastClk      (emmc_dbg_use_fast_clk),
        .dbgReinitPending   (emmc_dbg_reinit_pending),
        .dbgErrCmdTimeout   (emmc_dbg_err_cmd_timeout),
        .dbgErrCmdCrc       (emmc_dbg_err_cmd_crc),
        .dbgErrDatRd        (emmc_dbg_err_dat_rd),
        .dbgErrDatWr        (emmc_dbg_err_dat_wr),
        .dbgInitRetryCnt    (emmc_dbg_init_retry_cnt),
        .dbgClkPreset       (emmc_dbg_clk_preset)
    );

    // =========================================================
    // FIFO Bridge (SpinalHDL-generated, useFifo=true)
    // =========================================================
    wire fifo_activity;
    wire protocol_error;

    fifo_bridge u_fifo_bridge (
        .clk                (sys_clk),
        .resetn             (rst_n),
        .fifoDataRead       (fifo_data_read),
        .fifoDataWrite      (fifo_data_write),
        .fifoDataOe         (fifo_data_oe),
        .fifoRxfN           (fifo_rxf_n),
        .fifoTxeN           (fifo_txe_n),
        .fifoRdN            (fifo_rd_n),
        .fifoWrN            (fifo_wr_n),
        .emmcCmdValid       (emmc_cmd_valid),
        .emmcCmdId          (emmc_cmd_id),
        .emmcCmdLba         (emmc_cmd_lba),
        .emmcCmdCount       (emmc_cmd_count),
        .emmcCmdReady       (emmc_cmd_ready),
        .emmcRespStatus     (emmc_resp_status),
        .emmcRespValid      (emmc_resp_valid),
        .emmcRdData         (emmc_rd_data),
        .emmcRdAddr         (emmc_rd_addr),
        .emmcRdSectorReady  (emmc_rd_sector_ready),
        .emmcRdSectorAck    (emmc_rd_sector_ack),
        .emmcWrData         (emmc_wr_data),
        .emmcWrAddr         (emmc_wr_addr),
        .emmcWrEn           (emmc_wr_en),
        .emmcWrSectorValid  (emmc_wr_sector_valid),
        .emmcWrSectorAck    (emmc_wr_sector_ack),
        .emmcWrBank         (emmc_wr_bank),
        .emmcCid            (emmc_cid),
        .emmcCsd            (emmc_csd),
        .emmcInfoValid      (emmc_info_valid),
        .emmcCardStatus     (emmc_card_status),
        .emmcRawResp        (emmc_raw_resp),
        .emmcDbgInitState   (emmc_dbg_init_state),
        .emmcDbgMcState     (emmc_dbg_mc_state),
        .emmcDbgCmdPin      (emmc_dbg_cmd_pin),
        .emmcDbgDat0Pin     (emmc_dbg_dat0_pin),
        .emmcDbgCmdFsm      (emmc_dbg_cmd_fsm),
        .emmcDbgDatFsm      (emmc_dbg_dat_fsm),
        .emmcDbgPartition   (emmc_dbg_partition),
        .emmcDbgUseFastClk  (emmc_dbg_use_fast_clk),
        .emmcDbgReinitPending(emmc_dbg_reinit_pending),
        .emmcDbgErrCmdTimeout(emmc_dbg_err_cmd_timeout),
        .emmcDbgErrCmdCrc   (emmc_dbg_err_cmd_crc),
        .emmcDbgErrDatRd    (emmc_dbg_err_dat_rd),
        .emmcDbgErrDatWr    (emmc_dbg_err_dat_wr),
        .emmcDbgInitRetryCnt(emmc_dbg_init_retry_cnt),
        .emmcDbgClkPreset   (emmc_dbg_clk_preset),
        .uartActivity       (fifo_activity),
        .protocolError      (protocol_error)
    );

    // =========================================================
    // LED Status (SpinalHDL-generated)
    // =========================================================
    led_status u_led_status (
        .clk         (sys_clk),
        .resetn      (rst_n),
        .emmcActive  (emmc_active),
        .uartActive  (fifo_activity),
        .emmcReady   (emmc_ready),
        .error       (emmc_error | protocol_error),
        .ledN        (led)
    );

endmodule
