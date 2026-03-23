// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : uart_bridge
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module uart_bridge (
  input  wire          uartRxPin,
  output wire          uartTxPin,
  output wire          emmcCmdValid,
  output wire [7:0]    emmcCmdId,
  output wire [31:0]   emmcCmdLba,
  output wire [15:0]   emmcCmdCount,
  input  wire          emmcCmdReady,
  input  wire [7:0]    emmcRespStatus,
  input  wire          emmcRespValid,
  input  wire [7:0]    emmcRdData,
  output wire [8:0]    emmcRdAddr,
  input  wire          emmcRdSectorReady,
  output wire          emmcRdSectorAck,
  output wire [7:0]    emmcWrData,
  output wire [8:0]    emmcWrAddr,
  output wire          emmcWrEn,
  output wire          emmcWrSectorValid,
  input  wire          emmcWrSectorAck,
  output wire [3:0]    emmcWrBank,
  input  wire [127:0]  emmcCid,
  input  wire [127:0]  emmcCsd,
  input  wire          emmcInfoValid,
  input  wire [31:0]   emmcCardStatus,
  input  wire [127:0]  emmcRawResp,
  input  wire [3:0]    emmcDbgInitState,
  input  wire [4:0]    emmcDbgMcState,
  input  wire          emmcDbgCmdPin,
  input  wire          emmcDbgDat0Pin,
  input  wire [2:0]    emmcDbgCmdFsm,
  input  wire [3:0]    emmcDbgDatFsm,
  input  wire [1:0]    emmcDbgPartition,
  input  wire          emmcDbgUseFastClk,
  input  wire          emmcDbgReinitPending,
  input  wire [7:0]    emmcDbgErrCmdTimeout,
  input  wire [7:0]    emmcDbgErrCmdCrc,
  input  wire [7:0]    emmcDbgErrDatRd,
  input  wire [7:0]    emmcDbgErrDatWr,
  input  wire [7:0]    emmcDbgInitRetryCnt,
  input  wire [2:0]    emmcDbgClkPreset,
  output wire          uartActivity,
  output wire          protocolError,
  input  wire          clk,
  input  wire          resetn
);

  wire       [7:0]    uartRx_1_io_dataOut;
  wire                uartRx_1_io_dataValid;
  wire                uartRx_1_io_frameErr;
  wire                uartTx_1_io_tx;
  wire                uartTx_1_io_busy;
  wire       [7:0]    uRxCrc_io_crcOut;
  wire       [7:0]    uTxCrc_io_crcOut;
  wire       [7:0]    CMD_PING;
  wire       [7:0]    CMD_GET_INFO;
  wire       [7:0]    CMD_READ_SECTOR;
  wire       [7:0]    CMD_WRITE_SECTOR;
  wire       [7:0]    CMD_ERASE;
  wire       [7:0]    CMD_GET_STATUS;
  wire       [7:0]    CMD_GET_EXT_CSD;
  wire       [7:0]    CMD_SET_PARTITION;
  wire       [7:0]    CMD_WRITE_EXT_CSD;
  wire       [7:0]    CMD_GET_CARD_STATUS;
  wire       [7:0]    CMD_REINIT;
  wire       [7:0]    CMD_SECURE_ERASE;
  wire       [7:0]    CMD_SET_CLK_DIV;
  wire       [7:0]    CMD_SEND_RAW;
  wire       [7:0]    CMD_SET_BAUD;
  wire       [7:0]    CMD_SET_RPMB_MODE;
  wire       [7:0]    CMD_SET_BUS_WIDTH;
  wire       [7:0]    STATUS_OK;
  wire       [7:0]    STATUS_ERR_CRC;
  wire       [7:0]    STATUS_ERR_CMD;
  wire       [7:0]    STATUS_ERR_EMMC;
  wire       [7:0]    STATUS_BUSY;
  wire       [3:0]    RX_IDLE;
  wire       [3:0]    RX_CMD;
  wire       [3:0]    RX_LEN_H;
  wire       [3:0]    RX_LEN_L;
  wire       [3:0]    RX_PAYLOAD;
  wire       [3:0]    RX_CRC;
  wire       [3:0]    RX_EXEC1;
  wire       [3:0]    RX_EXEC2;
  wire       [3:0]    TX_IDLE;
  wire       [3:0]    TX_HEADER;
  wire       [3:0]    TX_CMD;
  wire       [3:0]    TX_STATUS;
  wire       [3:0]    TX_LEN_H;
  wire       [3:0]    TX_LEN_L;
  wire       [3:0]    TX_PAYLOAD;
  wire       [3:0]    TX_CRC;
  wire       [3:0]    TX_PREFETCH;
  wire       [3:0]    TX_BAUD_WAIT;
  reg        [7:0]    uartClksPerBit;
  reg        [7:0]    baudSwitchCpb;
  reg        [1:0]    baudSwitchPreset;
  reg                 baudSwitchPending;
  reg        [1:0]    currentBaudPreset;
  reg        [29:0]   baudWatchdogCnt;
  reg        [7:0]    txDataR;
  reg                 txValidR;
  reg                 rxCrcClearR;
  reg                 rxCrcEnR;
  reg                 txCrcClearR;
  reg                 txCrcEnR;
  reg        [7:0]    txCrcDataR;
  reg        [3:0]    rxState;
  reg        [7:0]    rxCmdId;
  reg        [15:0]   rxPayloadLen;
  reg        [15:0]   rxPayloadCnt;
  reg        [7:0]    rxPayloadBuf_0;
  reg        [7:0]    rxPayloadBuf_1;
  reg        [7:0]    rxPayloadBuf_2;
  reg        [7:0]    rxPayloadBuf_3;
  reg        [7:0]    rxPayloadBuf_4;
  reg        [7:0]    rxPayloadBuf_5;
  reg        [7:0]    rxPayloadBuf_6;
  reg        [7:0]    rxPayloadBuf_7;
  reg        [3:0]    txState;
  reg        [7:0]    txCmdId;
  reg        [7:0]    txStatus;
  reg        [15:0]   txPayloadLen;
  reg        [15:0]   txPayloadCnt;
  reg                 txStart;
  reg                 txStartD;
  reg        [1:0]    txPayloadSrc;
  reg        [255:0]  infoShift;
  reg        [7:0]    emmcRdDataReg;
  reg                 txBusyR;
  reg                 rxCrcMatch;
  reg                 isWriteCmd;
  reg                 txPayloadLast;
  reg                 rxPayloadLast;
  reg        [3:0]    rxByteNum;
  reg                 cardStatusPending;
  reg                 rawCmdPending;
  reg                 rawRespIsLong;
  reg                 rawRespExpected;
  reg                 earlyWriteDispatched;
  reg                 respValidR;
  reg        [7:0]    respStatusR;
  reg        [7:0]    respCmdIdR;
  reg        [31:0]   respCardStatusR;
  reg                 respStatusIsOk;
  reg        [22:0]   rxTimeoutCnt;
  reg                 rxTimeout;
  reg        [15:0]   sectorsRemaining;
  reg        [15:0]   sectorsRemainingNext;
  reg                 sectorsPending;
  reg        [15:0]   wrSectorsLeft;
  reg        [4:0]    wrSectorsReady;
  reg        [8:0]    wrByteInSector;
  reg                 wrByteIsLast;
  reg                 wrHasSectorsLeft;
  reg                 wrBankIncPending;
  reg                 emmcCmdValidR;
  reg        [7:0]    emmcCmdIdR;
  reg        [31:0]   emmcCmdLbaR;
  reg        [15:0]   emmcCmdCountR;
  reg                 emmcWrEnR;
  reg        [8:0]    emmcWrAddrR;
  reg        [7:0]    emmcWrDataR;
  reg                 emmcWrSectorValidR;
  reg        [3:0]    emmcWrBankR;
  reg        [8:0]    emmcRdAddrR;
  reg                 emmcRdSectorAckR;
  reg                 protocolErrorR;
  wire                when_UartBridge_l366;
  wire                when_UartBridge_l398;
  wire                when_UartBridge_l403;
  wire                when_UartBridge_l411;
  wire                when_UartBridge_l413;
  wire                when_UartBridge_l415;
  wire                when_UartBridge_l427;
  wire                when_UartBridge_l435;
  wire       [15:0]   _zz_rxPayloadCnt;
  wire                when_UartBridge_l465;
  wire                when_UartBridge_l477;
  wire       [7:0]    _zz_1;
  wire                when_UartBridge_l482;
  wire       [15:0]   _zz_wrSectorsLeft;
  wire                when_UartBridge_l492;
  wire                when_UartBridge_l500;
  wire                when_UartBridge_l501;
  wire                when_UartBridge_l511;
  wire                when_UartBridge_l524;
  wire                when_UartBridge_l522;
  wire                when_UartBridge_l533;
  wire                when_UartBridge_l575;
  wire                when_UartBridge_l597;
  wire                when_UartBridge_l687;
  reg        [7:0]    _zz_baudSwitchCpb;
  wire                when_UartBridge_l148;
  wire                when_UartBridge_l149;
  wire                when_UartBridge_l150;
  wire                when_UartBridge_l582;
  wire                when_UartBridge_l589;
  wire                when_UartBridge_l596;
  wire                when_UartBridge_l603;
  wire                when_UartBridge_l607;
  wire                when_UartBridge_l629;
  wire                when_UartBridge_l636;
  wire                when_UartBridge_l641;
  wire                when_UartBridge_l646;
  wire                when_UartBridge_l651;
  wire                when_UartBridge_l655;
  wire                when_UartBridge_l659;
  wire                when_UartBridge_l664;
  wire                when_UartBridge_l673;
  wire                when_UartBridge_l678;
  wire                when_UartBridge_l683;
  wire                when_UartBridge_l431;
  wire                when_UartBridge_l441;
  wire                when_UartBridge_l449;
  wire                when_UartBridge_l456;
  wire                when_UartBridge_l472;
  wire                when_UartBridge_l545;
  wire                when_UartBridge_l551;
  wire                when_UartBridge_l573;
  wire                when_UartBridge_l727;
  wire                when_UartBridge_l748;
  wire                when_UartBridge_l750;
  wire                when_UartBridge_l770;
  wire                when_UartBridge_l731;
  wire                when_UartBridge_l783;
  wire                when_UartBridge_l790;
  wire                when_UartBridge_l799;
  wire                when_UartBridge_l808;
  wire                when_UartBridge_l817;
  wire                when_UartBridge_l825;
  wire                when_UartBridge_l833;
  wire                when_UartBridge_l861;
  wire                when_UartBridge_l869;
  wire                when_UartBridge_l782;
  wire                when_UartBridge_l789;
  wire                when_UartBridge_l798;
  wire                when_UartBridge_l807;
  wire                when_UartBridge_l816;
  wire                when_UartBridge_l832;
  wire                when_UartBridge_l860;
  wire                when_UartBridge_l867;

  UartRx uartRx_1 (
    .io_rx         (uartRxPin               ), //i
    .io_clksPerBit (uartClksPerBit[7:0]     ), //i
    .io_dataOut    (uartRx_1_io_dataOut[7:0]), //o
    .io_dataValid  (uartRx_1_io_dataValid   ), //o
    .io_frameErr   (uartRx_1_io_frameErr    ), //o
    .clk           (clk                     ), //i
    .resetn        (resetn                  )  //i
  );
  UartTx uartTx_1 (
    .io_dataIn     (txDataR[7:0]       ), //i
    .io_dataValid  (txValidR           ), //i
    .io_clksPerBit (uartClksPerBit[7:0]), //i
    .io_tx         (uartTx_1_io_tx     ), //o
    .io_busy       (uartTx_1_io_busy   ), //o
    .clk           (clk                ), //i
    .resetn        (resetn             )  //i
  );
  Crc8 uRxCrc (
    .io_clear  (rxCrcClearR             ), //i
    .io_enable (rxCrcEnR                ), //i
    .io_dataIn (uartRx_1_io_dataOut[7:0]), //i
    .io_crcOut (uRxCrc_io_crcOut[7:0]   ), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc8 uTxCrc (
    .io_clear  (txCrcClearR          ), //i
    .io_enable (txCrcEnR             ), //i
    .io_dataIn (txCrcDataR[7:0]      ), //i
    .io_crcOut (uTxCrc_io_crcOut[7:0]), //o
    .clk       (clk                  ), //i
    .resetn    (resetn               )  //i
  );
  assign CMD_PING = 8'h01;
  assign CMD_GET_INFO = 8'h02;
  assign CMD_READ_SECTOR = 8'h03;
  assign CMD_WRITE_SECTOR = 8'h04;
  assign CMD_ERASE = 8'h05;
  assign CMD_GET_STATUS = 8'h06;
  assign CMD_GET_EXT_CSD = 8'h07;
  assign CMD_SET_PARTITION = 8'h08;
  assign CMD_WRITE_EXT_CSD = 8'h09;
  assign CMD_GET_CARD_STATUS = 8'h0a;
  assign CMD_REINIT = 8'h0b;
  assign CMD_SECURE_ERASE = 8'h0c;
  assign CMD_SET_CLK_DIV = 8'h0d;
  assign CMD_SEND_RAW = 8'h0e;
  assign CMD_SET_BAUD = 8'h0f;
  assign CMD_SET_RPMB_MODE = 8'h10;
  assign CMD_SET_BUS_WIDTH = 8'h11;
  assign STATUS_OK = 8'h0;
  assign STATUS_ERR_CRC = 8'h01;
  assign STATUS_ERR_CMD = 8'h02;
  assign STATUS_ERR_EMMC = 8'h03;
  assign STATUS_BUSY = 8'h04;
  assign RX_IDLE = 4'b0000;
  assign RX_CMD = 4'b0001;
  assign RX_LEN_H = 4'b0010;
  assign RX_LEN_L = 4'b0011;
  assign RX_PAYLOAD = 4'b0100;
  assign RX_CRC = 4'b0101;
  assign RX_EXEC1 = 4'b0110;
  assign RX_EXEC2 = 4'b0111;
  assign TX_IDLE = 4'b0000;
  assign TX_HEADER = 4'b0001;
  assign TX_CMD = 4'b0010;
  assign TX_STATUS = 4'b0011;
  assign TX_LEN_H = 4'b0100;
  assign TX_LEN_L = 4'b0101;
  assign TX_PAYLOAD = 4'b0110;
  assign TX_CRC = 4'b0111;
  assign TX_PREFETCH = 4'b1000;
  assign TX_BAUD_WAIT = 4'b1001;
  assign uartTxPin = uartTx_1_io_tx;
  assign emmcCmdValid = emmcCmdValidR;
  assign emmcCmdId = emmcCmdIdR;
  assign emmcCmdLba = emmcCmdLbaR;
  assign emmcCmdCount = emmcCmdCountR;
  assign emmcRdAddr = emmcRdAddrR;
  assign emmcRdSectorAck = emmcRdSectorAckR;
  assign emmcWrData = emmcWrDataR;
  assign emmcWrAddr = emmcWrAddrR;
  assign emmcWrEn = emmcWrEnR;
  assign emmcWrSectorValid = emmcWrSectorValidR;
  assign emmcWrBank = emmcWrBankR;
  assign protocolError = protocolErrorR;
  assign uartActivity = (uartRx_1_io_dataValid || uartTx_1_io_busy);
  assign when_UartBridge_l366 = ((wrSectorsReady != 5'h0) && (! emmcWrSectorValidR));
  assign when_UartBridge_l398 = (uartRx_1_io_dataValid || (rxState == RX_IDLE));
  assign when_UartBridge_l403 = (&rxTimeoutCnt);
  assign when_UartBridge_l411 = (uartClksPerBit == 8'h0);
  assign when_UartBridge_l413 = ((rxState == RX_EXEC1) && rxCrcMatch);
  assign when_UartBridge_l415 = (&baudWatchdogCnt);
  assign when_UartBridge_l427 = (((rxTimeout && (rxState != RX_IDLE)) && (rxState != RX_EXEC1)) && (rxState != RX_EXEC2));
  assign when_UartBridge_l435 = (uartRx_1_io_dataOut == 8'haa);
  assign _zz_rxPayloadCnt = {rxPayloadLen[15 : 8],uartRx_1_io_dataOut};
  assign when_UartBridge_l465 = (_zz_rxPayloadCnt == 16'h0);
  assign when_UartBridge_l477 = (! rxByteNum[3]);
  assign _zz_1 = ({7'd0,1'b1} <<< rxByteNum[2 : 0]);
  assign when_UartBridge_l482 = (isWriteCmd && (rxByteNum == 4'b0101));
  assign _zz_wrSectorsLeft = {rxPayloadBuf_4,uartRx_1_io_dataOut};
  assign when_UartBridge_l492 = (isWriteCmd && (rxByteNum[3] || (4'b0110 <= rxByteNum)));
  assign when_UartBridge_l500 = (wrByteIsLast && wrHasSectorsLeft);
  assign when_UartBridge_l501 = (! earlyWriteDispatched);
  assign when_UartBridge_l511 = ((wrSectorsReady != 5'h0) && (! emmcWrSectorValidR));
  assign when_UartBridge_l524 = ((wrSectorsReady != 5'h0) && (! emmcWrSectorValidR));
  assign when_UartBridge_l522 = ((wrByteIsLast && (! wrHasSectorsLeft)) && earlyWriteDispatched);
  assign when_UartBridge_l533 = (! rxByteNum[3]);
  assign when_UartBridge_l575 = (rxCmdId == CMD_PING);
  assign when_UartBridge_l597 = (! earlyWriteDispatched);
  assign when_UartBridge_l687 = (((rxPayloadBuf_0[7 : 2] == 6'h0) && (rxPayloadBuf_0[1 : 0] <= 2'b11)) && (rxPayloadBuf_0[1 : 0] != 2'b10));
  always @(*) begin
    _zz_baudSwitchCpb = 8'h14;
    if(when_UartBridge_l148) begin
      _zz_baudSwitchCpb = 8'h0a;
    end
    if(when_UartBridge_l149) begin
      _zz_baudSwitchCpb = 8'h08;
    end
    if(when_UartBridge_l150) begin
      _zz_baudSwitchCpb = 8'h05;
    end
  end

  assign when_UartBridge_l148 = (rxPayloadBuf_0[1 : 0] == 2'b01);
  assign when_UartBridge_l149 = (rxPayloadBuf_0[1 : 0] == 2'b10);
  assign when_UartBridge_l150 = (rxPayloadBuf_0[1 : 0] == 2'b11);
  assign when_UartBridge_l582 = (rxCmdId == CMD_GET_INFO);
  assign when_UartBridge_l589 = (rxCmdId == CMD_READ_SECTOR);
  assign when_UartBridge_l596 = (rxCmdId == CMD_WRITE_SECTOR);
  assign when_UartBridge_l603 = (rxCmdId == CMD_ERASE);
  assign when_UartBridge_l607 = (rxCmdId == CMD_GET_STATUS);
  assign when_UartBridge_l629 = (rxCmdId == CMD_GET_EXT_CSD);
  assign when_UartBridge_l636 = (rxCmdId == CMD_SET_PARTITION);
  assign when_UartBridge_l641 = (rxCmdId == CMD_WRITE_EXT_CSD);
  assign when_UartBridge_l646 = (rxCmdId == CMD_GET_CARD_STATUS);
  assign when_UartBridge_l651 = (rxCmdId == CMD_REINIT);
  assign when_UartBridge_l655 = (rxCmdId == CMD_SECURE_ERASE);
  assign when_UartBridge_l659 = (rxCmdId == CMD_SET_CLK_DIV);
  assign when_UartBridge_l664 = (rxCmdId == CMD_SEND_RAW);
  assign when_UartBridge_l673 = (rxCmdId == CMD_SET_RPMB_MODE);
  assign when_UartBridge_l678 = (rxCmdId == CMD_SET_BUS_WIDTH);
  assign when_UartBridge_l683 = (rxCmdId == CMD_SET_BAUD);
  assign when_UartBridge_l431 = (rxState == RX_IDLE);
  assign when_UartBridge_l441 = (rxState == RX_CMD);
  assign when_UartBridge_l449 = (rxState == RX_LEN_H);
  assign when_UartBridge_l456 = (rxState == RX_LEN_L);
  assign when_UartBridge_l472 = (rxState == RX_PAYLOAD);
  assign when_UartBridge_l545 = (rxState == RX_CRC);
  assign when_UartBridge_l551 = (rxState == RX_EXEC1);
  assign when_UartBridge_l573 = (rxState == RX_EXEC2);
  assign when_UartBridge_l727 = (txState == TX_IDLE);
  assign when_UartBridge_l748 = (rawCmdPending && respStatusIsOk);
  assign when_UartBridge_l750 = (! rawRespExpected);
  assign when_UartBridge_l770 = (cardStatusPending && respStatusIsOk);
  assign when_UartBridge_l731 = (emmcRdSectorReady && sectorsPending);
  assign when_UartBridge_l783 = (! uartTx_1_io_busy);
  assign when_UartBridge_l790 = ((! uartTx_1_io_busy) && (! txValidR));
  assign when_UartBridge_l799 = ((! uartTx_1_io_busy) && (! txValidR));
  assign when_UartBridge_l808 = ((! uartTx_1_io_busy) && (! txValidR));
  assign when_UartBridge_l817 = ((! uartTx_1_io_busy) && (! txValidR));
  assign when_UartBridge_l825 = (txPayloadLen == 16'h0);
  assign when_UartBridge_l833 = ((! uartTx_1_io_busy) && (! txValidR));
  assign when_UartBridge_l861 = ((! uartTx_1_io_busy) && (! txValidR));
  assign when_UartBridge_l869 = ((! uartTx_1_io_busy) && (! txValidR));
  assign when_UartBridge_l782 = (txState == TX_HEADER);
  assign when_UartBridge_l789 = (txState == TX_CMD);
  assign when_UartBridge_l798 = (txState == TX_STATUS);
  assign when_UartBridge_l807 = (txState == TX_LEN_H);
  assign when_UartBridge_l816 = (txState == TX_LEN_L);
  assign when_UartBridge_l832 = (txState == TX_PAYLOAD);
  assign when_UartBridge_l860 = (txState == TX_CRC);
  assign when_UartBridge_l867 = (txState == TX_BAUD_WAIT);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      uartClksPerBit <= 8'h0;
      baudSwitchCpb <= 8'h0;
      baudSwitchPreset <= 2'b00;
      baudSwitchPending <= 1'b0;
      currentBaudPreset <= 2'b00;
      baudWatchdogCnt <= 30'h0;
      txDataR <= 8'h0;
      txValidR <= 1'b0;
      rxCrcClearR <= 1'b1;
      rxCrcEnR <= 1'b0;
      txCrcClearR <= 1'b1;
      txCrcEnR <= 1'b0;
      txCrcDataR <= 8'h0;
      rxState <= 4'b0000;
      rxCmdId <= 8'h0;
      rxPayloadLen <= 16'h0;
      rxPayloadCnt <= 16'h0;
      rxPayloadBuf_0 <= 8'h0;
      rxPayloadBuf_1 <= 8'h0;
      rxPayloadBuf_2 <= 8'h0;
      rxPayloadBuf_3 <= 8'h0;
      rxPayloadBuf_4 <= 8'h0;
      rxPayloadBuf_5 <= 8'h0;
      rxPayloadBuf_6 <= 8'h0;
      rxPayloadBuf_7 <= 8'h0;
      txState <= 4'b0000;
      txCmdId <= 8'h0;
      txStatus <= 8'h0;
      txPayloadLen <= 16'h0;
      txPayloadCnt <= 16'h0;
      txStart <= 1'b0;
      txStartD <= 1'b0;
      txPayloadSrc <= 2'b00;
      infoShift <= 256'h0;
      emmcRdDataReg <= 8'h0;
      txBusyR <= 1'b0;
      rxCrcMatch <= 1'b0;
      isWriteCmd <= 1'b0;
      txPayloadLast <= 1'b0;
      rxPayloadLast <= 1'b0;
      rxByteNum <= 4'b0000;
      cardStatusPending <= 1'b0;
      rawCmdPending <= 1'b0;
      rawRespIsLong <= 1'b0;
      rawRespExpected <= 1'b0;
      earlyWriteDispatched <= 1'b0;
      respValidR <= 1'b0;
      respStatusR <= 8'h0;
      respCmdIdR <= 8'h0;
      respCardStatusR <= 32'h0;
      respStatusIsOk <= 1'b0;
      rxTimeoutCnt <= 23'h0;
      rxTimeout <= 1'b0;
      sectorsRemaining <= 16'h0;
      sectorsRemainingNext <= 16'h0;
      sectorsPending <= 1'b0;
      wrSectorsLeft <= 16'h0;
      wrSectorsReady <= 5'h0;
      wrByteInSector <= 9'h0;
      wrByteIsLast <= 1'b0;
      wrHasSectorsLeft <= 1'b0;
      wrBankIncPending <= 1'b0;
      emmcCmdValidR <= 1'b0;
      emmcCmdIdR <= 8'h0;
      emmcCmdLbaR <= 32'h0;
      emmcCmdCountR <= 16'h0;
      emmcWrEnR <= 1'b0;
      emmcWrAddrR <= 9'h0;
      emmcWrDataR <= 8'h0;
      emmcWrSectorValidR <= 1'b0;
      emmcWrBankR <= 4'b0000;
      emmcRdAddrR <= 9'h0;
      emmcRdSectorAckR <= 1'b0;
      protocolErrorR <= 1'b0;
    end else begin
      rxCrcClearR <= 1'b0;
      rxCrcEnR <= 1'b0;
      emmcCmdValidR <= 1'b0;
      emmcWrEnR <= 1'b0;
      emmcRdSectorAckR <= 1'b0;
      txStart <= 1'b0;
      txValidR <= 1'b0;
      txCrcClearR <= 1'b0;
      txCrcEnR <= 1'b0;
      if(emmcWrSectorAck) begin
        emmcWrSectorValidR <= 1'b0;
      end
      if(when_UartBridge_l366) begin
        emmcWrSectorValidR <= 1'b1;
        wrSectorsReady <= (wrSectorsReady - 5'h01);
      end
      if(wrBankIncPending) begin
        emmcWrBankR <= (emmcWrBankR + 4'b0001);
        wrBankIncPending <= 1'b0;
      end
      emmcRdDataReg <= emmcRdData;
      txBusyR <= uartTx_1_io_busy;
      txStartD <= txStart;
      if(emmcRespValid) begin
        respValidR <= 1'b1;
        respStatusR <= emmcRespStatus;
        respCmdIdR <= emmcCmdIdR;
        respCardStatusR <= emmcCardStatus;
        respStatusIsOk <= (emmcRespStatus == STATUS_OK);
      end
      if(when_UartBridge_l398) begin
        rxTimeoutCnt <= 23'h0;
        rxTimeout <= 1'b0;
      end else begin
        rxTimeoutCnt <= (rxTimeoutCnt + 23'h000001);
        if(when_UartBridge_l403) begin
          rxTimeout <= 1'b1;
        end
      end
      if(when_UartBridge_l411) begin
        baudWatchdogCnt <= 30'h0;
      end else begin
        if(when_UartBridge_l413) begin
          baudWatchdogCnt <= 30'h0;
        end else begin
          if(when_UartBridge_l415) begin
            uartClksPerBit <= 8'h0;
            currentBaudPreset <= 2'b00;
            baudSwitchPending <= 1'b0;
            baudWatchdogCnt <= 30'h0;
          end else begin
            baudWatchdogCnt <= (baudWatchdogCnt + 30'h00000001);
          end
        end
      end
      if(when_UartBridge_l427) begin
        rxState <= RX_IDLE;
        protocolErrorR <= 1'b1;
        wrSectorsReady <= 5'h0;
      end else begin
        if(when_UartBridge_l431) begin
          protocolErrorR <= 1'b0;
          earlyWriteDispatched <= 1'b0;
          if(uartRx_1_io_dataValid) begin
            if(when_UartBridge_l435) begin
              rxState <= RX_CMD;
              rxCrcClearR <= 1'b1;
            end
          end
        end else begin
          if(when_UartBridge_l441) begin
            if(uartRx_1_io_dataValid) begin
              rxCmdId <= uartRx_1_io_dataOut;
              isWriteCmd <= (uartRx_1_io_dataOut == CMD_WRITE_SECTOR);
              rxCrcEnR <= 1'b1;
              rxState <= RX_LEN_H;
            end
          end else begin
            if(when_UartBridge_l449) begin
              if(uartRx_1_io_dataValid) begin
                rxPayloadLen[15 : 8] <= uartRx_1_io_dataOut;
                rxCrcEnR <= 1'b1;
                rxState <= RX_LEN_L;
              end
            end else begin
              if(when_UartBridge_l456) begin
                if(uartRx_1_io_dataValid) begin
                  rxPayloadLen[7 : 0] <= uartRx_1_io_dataOut;
                  rxCrcEnR <= 1'b1;
                  rxPayloadCnt <= (_zz_rxPayloadCnt - 16'h0001);
                  rxPayloadLast <= (_zz_rxPayloadCnt == 16'h0001);
                  rxByteNum <= 4'b0000;
                  emmcWrAddrR <= 9'h1ff;
                  if(when_UartBridge_l465) begin
                    rxState <= RX_CRC;
                  end else begin
                    rxState <= RX_PAYLOAD;
                  end
                end
              end else begin
                if(when_UartBridge_l472) begin
                  if(uartRx_1_io_dataValid) begin
                    rxCrcEnR <= 1'b1;
                    if(when_UartBridge_l477) begin
                      if(_zz_1[0]) begin
                        rxPayloadBuf_0 <= uartRx_1_io_dataOut;
                      end
                      if(_zz_1[1]) begin
                        rxPayloadBuf_1 <= uartRx_1_io_dataOut;
                      end
                      if(_zz_1[2]) begin
                        rxPayloadBuf_2 <= uartRx_1_io_dataOut;
                      end
                      if(_zz_1[3]) begin
                        rxPayloadBuf_3 <= uartRx_1_io_dataOut;
                      end
                      if(_zz_1[4]) begin
                        rxPayloadBuf_4 <= uartRx_1_io_dataOut;
                      end
                      if(_zz_1[5]) begin
                        rxPayloadBuf_5 <= uartRx_1_io_dataOut;
                      end
                      if(_zz_1[6]) begin
                        rxPayloadBuf_6 <= uartRx_1_io_dataOut;
                      end
                      if(_zz_1[7]) begin
                        rxPayloadBuf_7 <= uartRx_1_io_dataOut;
                      end
                    end
                    if(when_UartBridge_l482) begin
                      wrSectorsLeft <= (_zz_wrSectorsLeft - 16'h0001);
                      wrHasSectorsLeft <= (16'h0001 < _zz_wrSectorsLeft);
                      wrByteInSector <= 9'h0;
                      wrByteIsLast <= 1'b0;
                      emmcWrBankR <= 4'b0000;
                      wrSectorsReady <= 5'h0;
                    end
                    if(when_UartBridge_l492) begin
                      emmcWrDataR <= uartRx_1_io_dataOut;
                      emmcWrEnR <= 1'b1;
                      emmcWrAddrR <= (emmcWrAddrR + 9'h001);
                      wrByteInSector <= (wrByteInSector + 9'h001);
                      wrByteIsLast <= (wrByteInSector == 9'h1fe);
                      if(when_UartBridge_l500) begin
                        if(when_UartBridge_l501) begin
                          emmcCmdLbaR <= {{{rxPayloadBuf_0,rxPayloadBuf_1},rxPayloadBuf_2},rxPayloadBuf_3};
                          emmcCmdCountR <= {rxPayloadBuf_4,rxPayloadBuf_5};
                          emmcCmdIdR <= CMD_WRITE_SECTOR;
                          emmcCmdValidR <= 1'b1;
                          emmcWrSectorValidR <= 1'b1;
                          earlyWriteDispatched <= 1'b1;
                        end else begin
                          if(when_UartBridge_l511) begin
                            wrSectorsReady <= wrSectorsReady;
                          end else begin
                            wrSectorsReady <= (wrSectorsReady + 5'h01);
                          end
                        end
                        wrSectorsLeft <= (wrSectorsLeft - 16'h0001);
                        wrHasSectorsLeft <= (wrSectorsLeft != 16'h0001);
                        wrByteInSector <= 9'h0;
                        wrByteIsLast <= 1'b0;
                        wrBankIncPending <= 1'b1;
                      end else begin
                        if(when_UartBridge_l522) begin
                          if(when_UartBridge_l524) begin
                            wrSectorsReady <= wrSectorsReady;
                          end else begin
                            wrSectorsReady <= (wrSectorsReady + 5'h01);
                          end
                        end
                      end
                    end
                    if(when_UartBridge_l533) begin
                      rxByteNum <= (rxByteNum + 4'b0001);
                    end
                    rxPayloadCnt <= (rxPayloadCnt - 16'h0001);
                    rxPayloadLast <= (rxPayloadCnt == 16'h0001);
                    if(rxPayloadLast) begin
                      rxState <= RX_CRC;
                    end
                  end
                end else begin
                  if(when_UartBridge_l545) begin
                    if(uartRx_1_io_dataValid) begin
                      rxCrcMatch <= (uartRx_1_io_dataOut == uRxCrc_io_crcOut);
                      rxState <= RX_EXEC1;
                    end
                  end else begin
                    if(when_UartBridge_l551) begin
                      if(rxCrcMatch) begin
                        infoShift <= {emmcCid,emmcCsd};
                        emmcCmdLbaR <= {{{rxPayloadBuf_0,rxPayloadBuf_1},rxPayloadBuf_2},rxPayloadBuf_3};
                        emmcCmdCountR <= {rxPayloadBuf_4,rxPayloadBuf_5};
                        rxState <= RX_EXEC2;
                      end else begin
                        protocolErrorR <= 1'b1;
                        txStart <= 1'b1;
                        txCmdId <= rxCmdId;
                        txStatus <= STATUS_ERR_CRC;
                        txPayloadLen <= 16'h0;
                        txPayloadSrc <= 2'b00;
                        rxState <= RX_IDLE;
                      end
                    end else begin
                      if(when_UartBridge_l573) begin
                        if(when_UartBridge_l575) begin
                          txStart <= 1'b1;
                          txCmdId <= CMD_PING;
                          txStatus <= STATUS_OK;
                          txPayloadLen <= 16'h0;
                          txPayloadSrc <= 2'b00;
                        end else begin
                          if(when_UartBridge_l582) begin
                            txStart <= 1'b1;
                            txCmdId <= CMD_GET_INFO;
                            txStatus <= (emmcInfoValid ? STATUS_OK : STATUS_ERR_EMMC);
                            txPayloadLen <= 16'h0020;
                            txPayloadSrc <= 2'b01;
                          end else begin
                            if(when_UartBridge_l589) begin
                              emmcCmdIdR <= CMD_READ_SECTOR;
                              emmcCmdValidR <= 1'b1;
                              sectorsRemaining <= emmcCmdCountR;
                              sectorsRemainingNext <= (emmcCmdCountR - 16'h0001);
                              sectorsPending <= (emmcCmdCountR != 16'h0);
                            end else begin
                              if(when_UartBridge_l596) begin
                                if(when_UartBridge_l597) begin
                                  emmcCmdIdR <= CMD_WRITE_SECTOR;
                                  emmcCmdValidR <= 1'b1;
                                  emmcWrSectorValidR <= 1'b1;
                                end
                              end else begin
                                if(when_UartBridge_l603) begin
                                  emmcCmdIdR <= CMD_ERASE;
                                  emmcCmdValidR <= 1'b1;
                                end else begin
                                  if(when_UartBridge_l607) begin
                                    infoShift[255 : 248] <= emmcRespStatus;
                                    infoShift[247 : 240] <= {{emmcDbgInitState,1'b0},emmcDbgMcState[4 : 2]};
                                    infoShift[239 : 232] <= {{{emmcDbgMcState[1 : 0],emmcInfoValid},emmcCmdReady},4'b0000};
                                    infoShift[231 : 224] <= {{emmcDbgCmdPin,emmcDbgDat0Pin},6'h0};
                                    infoShift[223 : 216] <= {{emmcDbgCmdFsm,emmcDbgDatFsm},emmcDbgUseFastClk};
                                    infoShift[215 : 208] <= {{emmcDbgPartition,emmcDbgReinitPending},5'h0};
                                    infoShift[207 : 200] <= emmcDbgErrCmdTimeout;
                                    infoShift[199 : 192] <= emmcDbgErrCmdCrc;
                                    infoShift[191 : 184] <= emmcDbgErrDatRd;
                                    infoShift[183 : 176] <= emmcDbgErrDatWr;
                                    infoShift[175 : 168] <= emmcDbgInitRetryCnt;
                                    infoShift[167 : 160] <= {{3'b000,currentBaudPreset},emmcDbgClkPreset};
                                    txStart <= 1'b1;
                                    txCmdId <= CMD_GET_STATUS;
                                    txStatus <= STATUS_OK;
                                    txPayloadLen <= 16'h000c;
                                    txPayloadSrc <= 2'b01;
                                  end else begin
                                    if(when_UartBridge_l629) begin
                                      emmcCmdIdR <= CMD_GET_EXT_CSD;
                                      emmcCmdValidR <= 1'b1;
                                      sectorsRemaining <= 16'h0001;
                                      sectorsRemainingNext <= 16'h0;
                                      sectorsPending <= 1'b1;
                                    end else begin
                                      if(when_UartBridge_l636) begin
                                        emmcCmdIdR <= CMD_SET_PARTITION;
                                        emmcCmdLbaR <= {24'h0,rxPayloadBuf_0};
                                        emmcCmdValidR <= 1'b1;
                                      end else begin
                                        if(when_UartBridge_l641) begin
                                          emmcCmdIdR <= CMD_WRITE_EXT_CSD;
                                          emmcCmdLbaR <= {{16'h0,rxPayloadBuf_0},rxPayloadBuf_1};
                                          emmcCmdValidR <= 1'b1;
                                        end else begin
                                          if(when_UartBridge_l646) begin
                                            emmcCmdIdR <= CMD_GET_CARD_STATUS;
                                            emmcCmdValidR <= 1'b1;
                                            cardStatusPending <= 1'b1;
                                          end else begin
                                            if(when_UartBridge_l651) begin
                                              emmcCmdIdR <= CMD_REINIT;
                                              emmcCmdValidR <= 1'b1;
                                            end else begin
                                              if(when_UartBridge_l655) begin
                                                emmcCmdIdR <= CMD_SECURE_ERASE;
                                                emmcCmdValidR <= 1'b1;
                                              end else begin
                                                if(when_UartBridge_l659) begin
                                                  emmcCmdIdR <= CMD_SET_CLK_DIV;
                                                  emmcCmdLbaR <= {29'h0,rxPayloadBuf_0[2 : 0]};
                                                  emmcCmdValidR <= 1'b1;
                                                end else begin
                                                  if(when_UartBridge_l664) begin
                                                    emmcCmdIdR <= CMD_SEND_RAW;
                                                    emmcCmdLbaR <= {{{rxPayloadBuf_1,rxPayloadBuf_2},rxPayloadBuf_3},rxPayloadBuf_4};
                                                    emmcCmdCountR <= {{{5'h0,rxPayloadBuf_5[2 : 0]},2'b00},rxPayloadBuf_0[5 : 0]};
                                                    emmcCmdValidR <= 1'b1;
                                                    rawCmdPending <= 1'b1;
                                                    rawRespIsLong <= rxPayloadBuf_5[1];
                                                    rawRespExpected <= rxPayloadBuf_5[0];
                                                  end else begin
                                                    if(when_UartBridge_l673) begin
                                                      emmcCmdIdR <= CMD_SET_RPMB_MODE;
                                                      emmcCmdLbaR <= {31'h0,rxPayloadBuf_0[0]};
                                                      emmcCmdValidR <= 1'b1;
                                                    end else begin
                                                      if(when_UartBridge_l678) begin
                                                        emmcCmdIdR <= CMD_SET_BUS_WIDTH;
                                                        emmcCmdLbaR <= {31'h0,rxPayloadBuf_0[0]};
                                                        emmcCmdValidR <= 1'b1;
                                                      end else begin
                                                        if(when_UartBridge_l683) begin
                                                          if(when_UartBridge_l687) begin
                                                            baudSwitchCpb <= _zz_baudSwitchCpb;
                                                            baudSwitchPreset <= rxPayloadBuf_0[1 : 0];
                                                            baudSwitchPending <= 1'b1;
                                                            txStart <= 1'b1;
                                                            txCmdId <= CMD_SET_BAUD;
                                                            txStatus <= STATUS_OK;
                                                            txPayloadLen <= 16'h0;
                                                            txPayloadSrc <= 2'b00;
                                                          end else begin
                                                            txStart <= 1'b1;
                                                            txCmdId <= CMD_SET_BAUD;
                                                            txStatus <= STATUS_ERR_CMD;
                                                            txPayloadLen <= 16'h0;
                                                            txPayloadSrc <= 2'b00;
                                                          end
                                                        end else begin
                                                          protocolErrorR <= 1'b1;
                                                          txStart <= 1'b1;
                                                          txCmdId <= rxCmdId;
                                                          txStatus <= STATUS_ERR_CMD;
                                                          txPayloadLen <= 16'h0;
                                                          txPayloadSrc <= 2'b00;
                                                        end
                                                      end
                                                    end
                                                  end
                                                end
                                              end
                                            end
                                          end
                                        end
                                      end
                                    end
                                  end
                                end
                              end
                            end
                          end
                        end
                        rxState <= RX_IDLE;
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      if(when_UartBridge_l727) begin
        if(txStartD) begin
          txState <= TX_HEADER;
          txCrcClearR <= 1'b1;
        end else begin
          if(when_UartBridge_l731) begin
            emmcRdSectorAckR <= 1'b1;
            txCmdId <= CMD_READ_SECTOR;
            txStatus <= STATUS_OK;
            txPayloadLen <= 16'h0200;
            txPayloadSrc <= 2'b10;
            txState <= TX_HEADER;
            txCrcClearR <= 1'b1;
            sectorsRemaining <= sectorsRemainingNext;
            sectorsRemainingNext <= (sectorsRemainingNext - 16'h0001);
            sectorsPending <= (16'h0001 < sectorsRemaining);
          end else begin
            if(respValidR) begin
              respValidR <= 1'b0;
              txCmdId <= respCmdIdR;
              txStatus <= respStatusR;
              txCrcClearR <= 1'b1;
              txState <= TX_HEADER;
              if(when_UartBridge_l748) begin
                if(when_UartBridge_l750) begin
                  txPayloadLen <= 16'h0;
                  txPayloadSrc <= 2'b00;
                end else begin
                  if(rawRespIsLong) begin
                    infoShift <= {emmcRawResp,128'h0};
                    txPayloadLen <= 16'h0010;
                    txPayloadSrc <= 2'b01;
                  end else begin
                    infoShift[255 : 224] <= respCardStatusR;
                    infoShift[223 : 0] <= 224'h0;
                    txPayloadLen <= 16'h0004;
                    txPayloadSrc <= 2'b01;
                  end
                end
                rawCmdPending <= 1'b0;
                cardStatusPending <= 1'b0;
              end else begin
                if(rawCmdPending) begin
                  txPayloadLen <= 16'h0;
                  txPayloadSrc <= 2'b00;
                  rawCmdPending <= 1'b0;
                  cardStatusPending <= 1'b0;
                end else begin
                  if(when_UartBridge_l770) begin
                    infoShift[255 : 224] <= respCardStatusR;
                    txPayloadLen <= 16'h0004;
                    txPayloadSrc <= 2'b01;
                    cardStatusPending <= 1'b0;
                  end else begin
                    txPayloadLen <= 16'h0;
                    txPayloadSrc <= 2'b00;
                    cardStatusPending <= 1'b0;
                  end
                end
              end
            end
          end
        end
      end else begin
        if(when_UartBridge_l782) begin
          if(when_UartBridge_l783) begin
            txDataR <= 8'h55;
            txValidR <= 1'b1;
            txState <= TX_CMD;
          end
        end else begin
          if(when_UartBridge_l789) begin
            if(when_UartBridge_l790) begin
              txDataR <= txCmdId;
              txValidR <= 1'b1;
              txCrcEnR <= 1'b1;
              txCrcDataR <= txCmdId;
              txState <= TX_STATUS;
            end
          end else begin
            if(when_UartBridge_l798) begin
              if(when_UartBridge_l799) begin
                txDataR <= txStatus;
                txValidR <= 1'b1;
                txCrcEnR <= 1'b1;
                txCrcDataR <= txStatus;
                txState <= TX_LEN_H;
              end
            end else begin
              if(when_UartBridge_l807) begin
                if(when_UartBridge_l808) begin
                  txDataR <= txPayloadLen[15 : 8];
                  txValidR <= 1'b1;
                  txCrcEnR <= 1'b1;
                  txCrcDataR <= txPayloadLen[15 : 8];
                  txState <= TX_LEN_L;
                end
              end else begin
                if(when_UartBridge_l816) begin
                  if(when_UartBridge_l817) begin
                    txDataR <= txPayloadLen[7 : 0];
                    txValidR <= 1'b1;
                    txCrcEnR <= 1'b1;
                    txCrcDataR <= txPayloadLen[7 : 0];
                    txPayloadCnt <= (txPayloadLen - 16'h0001);
                    txPayloadLast <= (txPayloadLen == 16'h0001);
                    emmcRdAddrR <= 9'h0;
                    if(when_UartBridge_l825) begin
                      txState <= TX_CRC;
                    end else begin
                      txState <= TX_PAYLOAD;
                    end
                  end
                end else begin
                  if(when_UartBridge_l832) begin
                    if(when_UartBridge_l833) begin
                      case(txPayloadSrc)
                        2'b01 : begin
                          txDataR <= infoShift[255 : 248];
                          txCrcDataR <= infoShift[255 : 248];
                          infoShift <= {infoShift[247 : 0],8'h0};
                        end
                        2'b10 : begin
                          txDataR <= emmcRdDataReg;
                          txCrcDataR <= emmcRdDataReg;
                          emmcRdAddrR <= (emmcRdAddrR + 9'h001);
                        end
                        default : begin
                          txDataR <= 8'h0;
                          txCrcDataR <= 8'h0;
                        end
                      endcase
                      txValidR <= 1'b1;
                      txCrcEnR <= 1'b1;
                      txPayloadCnt <= (txPayloadCnt - 16'h0001);
                      txPayloadLast <= (txPayloadCnt == 16'h0001);
                      if(txPayloadLast) begin
                        txState <= TX_CRC;
                      end
                    end
                  end else begin
                    if(when_UartBridge_l860) begin
                      if(when_UartBridge_l861) begin
                        txDataR <= uTxCrc_io_crcOut;
                        txValidR <= 1'b1;
                        txState <= (baudSwitchPending ? TX_BAUD_WAIT : TX_IDLE);
                      end
                    end else begin
                      if(when_UartBridge_l867) begin
                        if(when_UartBridge_l869) begin
                          uartClksPerBit <= baudSwitchCpb;
                          currentBaudPreset <= baudSwitchPreset;
                          baudSwitchPending <= 1'b0;
                          txState <= TX_IDLE;
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end


endmodule

//Crc8_1 replaced by Crc8

module Crc8 (
  input  wire          io_clear,
  input  wire          io_enable,
  input  wire [7:0]    io_dataIn,
  output wire [7:0]    io_crcOut,
  input  wire          clk,
  input  wire          resetn
);

  reg        [7:0]    crc;
  reg        [7:0]    nextCrc;

  always @(*) begin
    nextCrc[0] = (((((crc[0] ^ crc[6]) ^ crc[7]) ^ io_dataIn[0]) ^ io_dataIn[6]) ^ io_dataIn[7]);
    nextCrc[1] = (((((crc[0] ^ crc[1]) ^ crc[6]) ^ io_dataIn[0]) ^ io_dataIn[1]) ^ io_dataIn[6]);
    nextCrc[2] = (((((((crc[0] ^ crc[1]) ^ crc[2]) ^ crc[6]) ^ io_dataIn[0]) ^ io_dataIn[1]) ^ io_dataIn[2]) ^ io_dataIn[6]);
    nextCrc[3] = (((((((crc[1] ^ crc[2]) ^ crc[3]) ^ crc[7]) ^ io_dataIn[1]) ^ io_dataIn[2]) ^ io_dataIn[3]) ^ io_dataIn[7]);
    nextCrc[4] = (((((crc[2] ^ crc[3]) ^ crc[4]) ^ io_dataIn[2]) ^ io_dataIn[3]) ^ io_dataIn[4]);
    nextCrc[5] = (((((crc[3] ^ crc[4]) ^ crc[5]) ^ io_dataIn[3]) ^ io_dataIn[4]) ^ io_dataIn[5]);
    nextCrc[6] = (((((crc[4] ^ crc[5]) ^ crc[6]) ^ io_dataIn[4]) ^ io_dataIn[5]) ^ io_dataIn[6]);
    nextCrc[7] = (((((crc[5] ^ crc[6]) ^ crc[7]) ^ io_dataIn[5]) ^ io_dataIn[6]) ^ io_dataIn[7]);
  end

  assign io_crcOut = crc;
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      crc <= 8'h0;
    end else begin
      if(io_clear) begin
        crc <= 8'h0;
      end else begin
        if(io_enable) begin
          crc <= nextCrc;
        end
      end
    end
  end


endmodule

module UartTx (
  input  wire [7:0]    io_dataIn,
  input  wire          io_dataValid,
  input  wire [7:0]    io_clksPerBit,
  output wire          io_tx,
  output wire          io_busy,
  input  wire          clk,
  input  wire          resetn
);

  wire       [7:0]    _zz_when_UartTx_l47;
  wire       [7:0]    _zz_when_UartTx_l55;
  wire       [7:0]    _zz_when_UartTx_l68;
  wire       [7:0]    activeCpb;
  wire       [1:0]    sIdle;
  wire       [1:0]    sStart;
  wire       [1:0]    sData;
  wire       [1:0]    sStop;
  reg        [1:0]    state;
  reg        [7:0]    clkCnt;
  reg        [2:0]    bitIdx;
  reg        [7:0]    shiftReg;
  reg                 txReg;
  wire                when_UartTx_l37;
  wire                when_UartTx_l47;
  wire                when_UartTx_l55;
  wire                when_UartTx_l58;
  wire                when_UartTx_l68;
  wire                when_UartTx_l45;
  wire                when_UartTx_l53;
  wire                when_UartTx_l66;

  assign _zz_when_UartTx_l47 = (activeCpb - 8'h01);
  assign _zz_when_UartTx_l55 = (activeCpb - 8'h01);
  assign _zz_when_UartTx_l68 = (activeCpb - 8'h01);
  assign activeCpb = ((io_clksPerBit != 8'h0) ? io_clksPerBit : 8'h14);
  assign sIdle = 2'b00;
  assign sStart = 2'b01;
  assign sData = 2'b10;
  assign sStop = 2'b11;
  assign io_busy = (state != sIdle);
  assign io_tx = txReg;
  assign when_UartTx_l37 = (state == sIdle);
  assign when_UartTx_l47 = (clkCnt == _zz_when_UartTx_l47);
  assign when_UartTx_l55 = (clkCnt == _zz_when_UartTx_l55);
  assign when_UartTx_l58 = (bitIdx == 3'b111);
  assign when_UartTx_l68 = (clkCnt == _zz_when_UartTx_l68);
  assign when_UartTx_l45 = (state == sStart);
  assign when_UartTx_l53 = (state == sData);
  assign when_UartTx_l66 = (state == sStop);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      state <= 2'b00;
      clkCnt <= 8'h0;
      bitIdx <= 3'b000;
      shiftReg <= 8'h0;
      txReg <= 1'b1;
    end else begin
      if(when_UartTx_l37) begin
        txReg <= 1'b1;
        clkCnt <= 8'h0;
        bitIdx <= 3'b000;
        if(io_dataValid) begin
          shiftReg <= io_dataIn;
          state <= sStart;
        end
      end else begin
        if(when_UartTx_l45) begin
          txReg <= 1'b0;
          if(when_UartTx_l47) begin
            clkCnt <= 8'h0;
            state <= sData;
          end else begin
            clkCnt <= (clkCnt + 8'h01);
          end
        end else begin
          if(when_UartTx_l53) begin
            txReg <= shiftReg[0];
            if(when_UartTx_l55) begin
              clkCnt <= 8'h0;
              shiftReg <= {1'b0,shiftReg[7 : 1]};
              if(when_UartTx_l58) begin
                state <= sStop;
              end else begin
                bitIdx <= (bitIdx + 3'b001);
              end
            end else begin
              clkCnt <= (clkCnt + 8'h01);
            end
          end else begin
            if(when_UartTx_l66) begin
              txReg <= 1'b1;
              if(when_UartTx_l68) begin
                clkCnt <= 8'h0;
                state <= sIdle;
              end else begin
                clkCnt <= (clkCnt + 8'h01);
              end
            end
          end
        end
      end
    end
  end


endmodule

module UartRx (
  input  wire          io_rx,
  input  wire [7:0]    io_clksPerBit,
  output wire [7:0]    io_dataOut,
  output wire          io_dataValid,
  output wire          io_frameErr,
  input  wire          clk,
  input  wire          resetn
);

  wire       [7:0]    _zz_when_UartRx_l59;
  wire       [7:0]    _zz_when_UartRx_l70;
  wire       [7:0]    _zz_when_UartRx_l82;
  wire       [7:0]    activeCpb;
  wire       [7:0]    halfCpb;
  wire       [1:0]    sIdle;
  wire       [1:0]    sStart;
  wire       [1:0]    sData;
  wire       [1:0]    sStop;
  reg                 rxSync1;
  reg                 rxSync2;
  reg        [1:0]    state;
  reg        [7:0]    clkCnt;
  reg        [2:0]    bitIdx;
  reg        [7:0]    shiftReg;
  reg        [7:0]    dataOut;
  reg                 dataValid;
  reg                 frameErr;
  wire                when_UartRx_l52;
  wire                when_UartRx_l55;
  wire                when_UartRx_l59;
  wire                when_UartRx_l61;
  wire                when_UartRx_l70;
  wire                when_UartRx_l73;
  wire                when_UartRx_l82;
  wire                when_UartRx_l58;
  wire                when_UartRx_l69;
  wire                when_UartRx_l81;

  assign _zz_when_UartRx_l59 = (halfCpb - 8'h01);
  assign _zz_when_UartRx_l70 = (activeCpb - 8'h01);
  assign _zz_when_UartRx_l82 = (activeCpb - 8'h01);
  assign activeCpb = ((io_clksPerBit != 8'h0) ? io_clksPerBit : 8'h14);
  assign halfCpb = (activeCpb >>> 1);
  assign sIdle = 2'b00;
  assign sStart = 2'b01;
  assign sData = 2'b10;
  assign sStop = 2'b11;
  assign io_dataOut = dataOut;
  assign io_dataValid = dataValid;
  assign io_frameErr = frameErr;
  assign when_UartRx_l52 = (state == sIdle);
  assign when_UartRx_l55 = (! rxSync2);
  assign when_UartRx_l59 = (clkCnt == _zz_when_UartRx_l59);
  assign when_UartRx_l61 = (! rxSync2);
  assign when_UartRx_l70 = (clkCnt == _zz_when_UartRx_l70);
  assign when_UartRx_l73 = (bitIdx == 3'b111);
  assign when_UartRx_l82 = (clkCnt == _zz_when_UartRx_l82);
  assign when_UartRx_l58 = (state == sStart);
  assign when_UartRx_l69 = (state == sData);
  assign when_UartRx_l81 = (state == sStop);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      rxSync1 <= 1'b1;
      rxSync2 <= 1'b1;
      state <= 2'b00;
      clkCnt <= 8'h0;
      bitIdx <= 3'b000;
      shiftReg <= 8'h0;
      dataOut <= 8'h0;
      dataValid <= 1'b0;
      frameErr <= 1'b0;
    end else begin
      rxSync1 <= io_rx;
      rxSync2 <= rxSync1;
      dataValid <= 1'b0;
      frameErr <= 1'b0;
      if(when_UartRx_l52) begin
        clkCnt <= 8'h0;
        bitIdx <= 3'b000;
        if(when_UartRx_l55) begin
          state <= sStart;
        end
      end else begin
        if(when_UartRx_l58) begin
          if(when_UartRx_l59) begin
            clkCnt <= 8'h0;
            if(when_UartRx_l61) begin
              state <= sData;
            end else begin
              state <= sIdle;
            end
          end else begin
            clkCnt <= (clkCnt + 8'h01);
          end
        end else begin
          if(when_UartRx_l69) begin
            if(when_UartRx_l70) begin
              clkCnt <= 8'h0;
              shiftReg <= {rxSync2,shiftReg[7 : 1]};
              if(when_UartRx_l73) begin
                state <= sStop;
              end else begin
                bitIdx <= (bitIdx + 3'b001);
              end
            end else begin
              clkCnt <= (clkCnt + 8'h01);
            end
          end else begin
            if(when_UartRx_l81) begin
              if(when_UartRx_l82) begin
                clkCnt <= 8'h0;
                if(rxSync2) begin
                  dataOut <= shiftReg;
                  dataValid <= 1'b1;
                end else begin
                  frameErr <= 1'b1;
                end
                state <= sIdle;
              end else begin
                clkCnt <= (clkCnt + 8'h01);
              end
            end
          end
        end
      end
    end
  end


endmodule
