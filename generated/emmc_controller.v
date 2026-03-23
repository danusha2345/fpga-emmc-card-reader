// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : emmc_controller
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module emmc_controller (
  output wire          emmcClk,
  output wire          emmcRstn,
  output wire          cmdOut,
  output wire          cmdOe,
  input  wire          cmdIn,
  output wire [3:0]    datOut,
  output wire          datOe,
  input  wire [3:0]    datIn,
  input  wire          cmdValid,
  input  wire [7:0]    cmdId,
  input  wire [31:0]   cmdLba,
  input  wire [15:0]   cmdCount,
  output wire          cmdReady,
  output wire [7:0]    respStatus,
  output wire          respValid,
  input  wire [8:0]    uartRdAddr,
  output wire [7:0]    uartRdData,
  output wire          rdSectorReady,
  input  wire          rdSectorAck,
  input  wire [7:0]    uartWrData,
  input  wire [8:0]    uartWrAddr,
  input  wire          uartWrEn,
  input  wire          uartWrSectorValid,
  input  wire [3:0]    uartWrBank,
  output wire          wrSectorAck,
  output wire [127:0]  cid,
  output wire [127:0]  csd,
  output wire          infoValid,
  output wire [31:0]   cardStatus,
  output wire [127:0]  rawRespData,
  output wire          active,
  output wire          ready,
  output wire          error,
  output wire [3:0]    dbgInitState,
  output wire [4:0]    dbgMcState,
  output wire          dbgCmdPin,
  output wire          dbgDat0Pin,
  output wire [2:0]    dbgCmdFsm,
  output wire [3:0]    dbgDatFsm,
  output wire [1:0]    dbgPartition,
  output wire          dbgUseFastClk,
  output wire          dbgReinitPending,
  output wire [7:0]    dbgErrCmdTimeout,
  output wire [7:0]    dbgErrCmdCrc,
  output wire [7:0]    dbgErrDatRd,
  output wire [7:0]    dbgErrDatWr,
  output wire [7:0]    dbgInitRetryCnt,
  output wire [2:0]    dbgClkPreset,
  input  wire          clk,
  input  wire          resetn
);

  wire                uCmd_io_cmdStart;
  wire       [5:0]    uCmd_io_cmdIndex;
  wire       [31:0]   uCmd_io_cmdArgument;
  wire                uCmd_io_respTypeLong;
  wire                uCmd_io_respExpected;
  wire       [1:0]    uSectorBuf_io_bufSelA;
  wire       [1:0]    uSectorBuf_io_bufSelB;
  wire                uCmd_io_cmdDone;
  wire                uCmd_io_cmdTimeout;
  wire                uCmd_io_cmdCrcErr;
  wire       [31:0]   uCmd_io_respStatus;
  wire       [127:0]  uCmd_io_respData;
  wire                uCmd_io_cmdOut;
  wire                uCmd_io_cmdOe;
  wire       [2:0]    uCmd_io_dbgState;
  wire                uDat_io_rdDone;
  wire                uDat_io_rdCrcErr;
  wire                uDat_io_wrDone;
  wire                uDat_io_wrCrcErr;
  wire       [7:0]    uDat_io_bufWrData;
  wire       [8:0]    uDat_io_bufWrAddr;
  wire                uDat_io_bufWrEn;
  wire       [8:0]    uDat_io_bufRdAddr;
  wire       [3:0]    uDat_io_datOut;
  wire                uDat_io_datOe;
  wire       [3:0]    uDat_io_dbgState;
  wire                uInit_io_initDone;
  wire                uInit_io_initError;
  wire       [3:0]    uInit_io_initStateDbg;
  wire                uInit_io_cmdStart;
  wire       [5:0]    uInit_io_cmdIndex;
  wire       [31:0]   uInit_io_cmdArgument;
  wire                uInit_io_respTypeLong;
  wire                uInit_io_respExpected;
  wire       [127:0]  uInit_io_cidReg;
  wire       [127:0]  uInit_io_csdReg;
  wire       [15:0]   uInit_io_rcaReg;
  wire                uInit_io_infoValid;
  wire                uInit_io_useFastClk;
  wire                uInit_io_emmcRstnOut;
  wire       [7:0]    uInit_io_dbgRetryCnt;
  wire       [7:0]    uSectorBuf_io_rdataA;
  wire       [7:0]    uSectorBuf_io_rdataB;
  wire       [7:0]    uWriteBuf_io_rdData;
  wire       [31:0]   _zz_preEraseEndLba;
  wire       [31:0]   _zz_preEraseEndLba_1;
  wire       [4:0]    MC_IDLE;
  wire       [4:0]    MC_INIT;
  wire       [4:0]    MC_READY;
  wire       [4:0]    MC_READ_CMD;
  wire       [4:0]    MC_READ_DAT;
  wire       [4:0]    MC_READ_DONE;
  wire       [4:0]    MC_WRITE_CMD;
  wire       [4:0]    MC_WRITE_DAT;
  wire       [4:0]    MC_WRITE_DONE;
  wire       [4:0]    MC_STOP_CMD;
  wire       [4:0]    MC_ERROR;
  wire       [4:0]    MC_STOP_WAIT;
  wire       [4:0]    MC_EXT_CSD_CMD;
  wire       [4:0]    MC_EXT_CSD_DAT;
  wire       [4:0]    MC_SWITCH_CMD;
  wire       [4:0]    MC_SWITCH_WAIT;
  wire       [4:0]    MC_ERASE_START;
  wire       [4:0]    MC_ERASE_END;
  wire       [4:0]    MC_ERASE_CMD;
  wire       [4:0]    MC_STATUS_CMD;
  wire       [4:0]    MC_ERROR_STOP;
  wire       [4:0]    MC_RAW_CMD;
  wire       [4:0]    MC_RAW_WAIT;
  wire       [4:0]    MC_RPMB_CMD23;
  wire       [4:0]    MC_RPMB_FIFO_WAIT;
  wire       [4:0]    MC_SWITCH_STATUS;
  wire       [7:0]    STATUS_OK;
  wire       [7:0]    STATUS_CRC_ERR;
  wire       [7:0]    STATUS_CMD_ERR;
  wire       [7:0]    STATUS_EMMC_ERR;
  wire       [7:0]    STATUS_BUSY;
  reg                 useFastClk;
  reg        [8:0]    fastClkDivReload;
  reg        [2:0]    currentClkPreset;
  reg        [8:0]    clkDivCnt;
  reg        [8:0]    clkDivReload;
  reg                 emmcClkReg;
  reg                 clkEn;
  reg                 clkPause;
  wire                when_EmmcController_l141;
  wire                when_EmmcController_l144;
  wire                when_EmmcController_l147;
  reg                 cmdInMeta;
  reg                 cmdInSync;
  reg        [3:0]    datInMeta;
  reg        [3:0]    datInSync;
  wire                cmdErrorW;
  wire                deviceStatusErr;
  reg                 datRdStart;
  reg                 datWrStart;
  reg                 busWidth4;
  reg                 busWidthSwitchPending;
  reg                 busWidthTarget;
  reg                 initStart;
  reg        [3:0]    emmcBank;
  reg        [1:0]    uartRdBank;
  reg        [1:0]    uartRdBankNext;
  reg                 isInitMode;
  reg                 mcCmdStartR;
  reg        [5:0]    mcCmdIndexR;
  reg        [31:0]   mcCmdArgR;
  reg                 mcCmdRespExpR;
  reg                 rawRespLongR;
  wire       [31:0]   statusArg;
  reg        [4:0]    mcState;
  reg        [31:0]   currentLba;
  reg        [31:0]   nextLba;
  reg        [15:0]   sectorsLeft;
  reg        [31:0]   eraseEndLba;
  reg                 useMultiBlock;
  reg                 isReadOp;
  reg        [1:0]    currentPartition;
  reg                 reinitPending;
  reg                 eraseSecure;
  reg        [1:0]    bootRetryCnt;
  reg                 rawCheckBusy;
  reg                 forceMultiBlock;
  reg                 switchNeedsVerify;
  reg                 cmdReadyR;
  reg        [7:0]    respStatusR;
  reg                 respValidR;
  reg                 rdSectorReadyR;
  reg                 wrSectorAckR;
  reg        [31:0]   cardStatusR;
  reg        [127:0]  rawRespDataR;
  reg        [19:0]   switchWaitCnt;
  reg        [23:0]   wrDoneWatchdog;
  reg                 wrDoneTimeout;
  reg                 activeReg;
  reg        [7:0]    errCmdTimeoutCnt;
  reg        [7:0]    errCmdCrcCnt;
  reg        [7:0]    errDatRdCnt;
  reg        [7:0]    errDatWrCnt;
  wire                when_EmmcController_l357;
  wire                when_EmmcController_l363;
  wire                when_EmmcController_l366;
  wire                when_EmmcController_l369;
  wire                when_EmmcController_l372;
  reg                 cmdIsRead;
  reg                 cmdIsWrite;
  reg                 cmdIsErase;
  reg                 cmdIsExtCsd;
  reg                 cmdIsPartition;
  reg                 cmdIsWriteExtCsd;
  reg                 cmdIsStatus;
  reg                 cmdIsReinit;
  reg                 cmdIsSecureErase;
  reg                 cmdIsSetClk;
  reg                 cmdIsRaw;
  reg                 cmdIsSetRpmbMode;
  reg                 cmdIsSetBusWidth;
  reg                 cmdCountIsZero;
  reg                 cmdCountGtOne;
  reg                 cmdCountGtSixteen;
  reg                 cmdValidD;
  reg                 wrSectorValidD;
  reg        [31:0]   preCmdArgument;
  reg        [5:0]    preCmdIndex;
  reg                 preCmdRespExp;
  reg        [31:0]   preEraseEndLba;
  wire       [2:0]    presetVal;
  reg        [8:0]    presetDivM1;
  wire                when_EmmcController_l468;
  wire                when_EmmcController_l469;
  wire                when_EmmcController_l470;
  wire                when_EmmcController_l471;
  wire                when_EmmcController_l472;
  wire                when_EmmcController_l473;
  wire                when_EmmcController_l497;
  wire                when_EmmcController_l520;
  wire                when_EmmcController_l538;
  wire                when_EmmcController_l596;
  wire                when_EmmcController_l550;
  wire                when_EmmcController_l571;
  wire                when_EmmcController_l632;
  wire                when_EmmcController_l660;
  wire                when_EmmcController_l662;
  wire                when_EmmcController_l677;
  wire                when_EmmcController_l692;
  wire                when_EmmcController_l718;
  wire                when_EmmcController_l720;
  wire                when_EmmcController_l735;
  wire                when_EmmcController_l784;
  wire                when_EmmcController_l791;
  wire                when_EmmcController_l801;
  wire                when_EmmcController_l847;
  wire                when_EmmcController_l864;
  wire                when_EmmcController_l876;
  wire                when_EmmcController_l900;
  wire                when_EmmcController_l915;
  wire                when_EmmcController_l930;
  wire                when_EmmcController_l999;
  wire                when_EmmcController_l1036;
  wire                when_EmmcController_l1043;
  wire                when_EmmcController_l502;
  wire                when_EmmcController_l528;
  wire                when_EmmcController_l629;
  wire                when_EmmcController_l643;
  wire                when_EmmcController_l659;
  wire                when_EmmcController_l690;
  wire                when_EmmcController_l703;
  wire                when_EmmcController_l717;
  wire                when_EmmcController_l768;
  wire                when_EmmcController_l781;
  wire                when_EmmcController_l798;
  wire                when_EmmcController_l812;
  wire                when_EmmcController_l828;
  wire                when_EmmcController_l844;
  wire                when_EmmcController_l872;
  wire                when_EmmcController_l897;
  wire                when_EmmcController_l912;
  wire                when_EmmcController_l927;
  wire                when_EmmcController_l942;
  wire                when_EmmcController_l960;
  wire                when_EmmcController_l989;
  wire                when_EmmcController_l1008;
  wire                when_EmmcController_l1033;
  wire                when_EmmcController_l1050;
  wire                when_EmmcController_l1063;

  assign _zz_preEraseEndLba = (cmdLba + _zz_preEraseEndLba_1);
  assign _zz_preEraseEndLba_1 = {16'd0, cmdCount};
  EmmcCmd uCmd (
    .io_clkEn        (clkEn                    ), //i
    .io_cmdStart     (uCmd_io_cmdStart         ), //i
    .io_cmdIndex     (uCmd_io_cmdIndex[5:0]    ), //i
    .io_cmdArgument  (uCmd_io_cmdArgument[31:0]), //i
    .io_respTypeLong (uCmd_io_respTypeLong     ), //i
    .io_respExpected (uCmd_io_respExpected     ), //i
    .io_cmdDone      (uCmd_io_cmdDone          ), //o
    .io_cmdTimeout   (uCmd_io_cmdTimeout       ), //o
    .io_cmdCrcErr    (uCmd_io_cmdCrcErr        ), //o
    .io_respStatus   (uCmd_io_respStatus[31:0] ), //o
    .io_respData     (uCmd_io_respData[127:0]  ), //o
    .io_cmdOut       (uCmd_io_cmdOut           ), //o
    .io_cmdOe        (uCmd_io_cmdOe            ), //o
    .io_cmdIn        (cmdInSync                ), //i
    .io_dbgState     (uCmd_io_dbgState[2:0]    ), //o
    .clk             (clk                      ), //i
    .resetn          (resetn                   )  //i
  );
  EmmcDat uDat (
    .io_clkEn     (clkEn                   ), //i
    .io_rdStart   (datRdStart              ), //i
    .io_rdDone    (uDat_io_rdDone          ), //o
    .io_rdCrcErr  (uDat_io_rdCrcErr        ), //o
    .io_wrStart   (datWrStart              ), //i
    .io_wrDone    (uDat_io_wrDone          ), //o
    .io_wrCrcErr  (uDat_io_wrCrcErr        ), //o
    .io_bufWrData (uDat_io_bufWrData[7:0]  ), //o
    .io_bufWrAddr (uDat_io_bufWrAddr[8:0]  ), //o
    .io_bufWrEn   (uDat_io_bufWrEn         ), //o
    .io_bufRdAddr (uDat_io_bufRdAddr[8:0]  ), //o
    .io_bufRdData (uWriteBuf_io_rdData[7:0]), //i
    .io_datOut    (uDat_io_datOut[3:0]     ), //o
    .io_datOe     (uDat_io_datOe           ), //o
    .io_datIn     (datInSync[3:0]          ), //i
    .io_busWidth4 (busWidth4               ), //i
    .io_dbgState  (uDat_io_dbgState[3:0]   ), //o
    .clk          (clk                     ), //i
    .resetn       (resetn                  )  //i
  );
  EmmcInit uInit (
    .io_initStart    (initStart                 ), //i
    .io_initDone     (uInit_io_initDone         ), //o
    .io_initError    (uInit_io_initError        ), //o
    .io_initStateDbg (uInit_io_initStateDbg[3:0]), //o
    .io_cmdStart     (uInit_io_cmdStart         ), //o
    .io_cmdIndex     (uInit_io_cmdIndex[5:0]    ), //o
    .io_cmdArgument  (uInit_io_cmdArgument[31:0]), //o
    .io_respTypeLong (uInit_io_respTypeLong     ), //o
    .io_respExpected (uInit_io_respExpected     ), //o
    .io_cmdDone      (uCmd_io_cmdDone           ), //i
    .io_cmdTimeout   (uCmd_io_cmdTimeout        ), //i
    .io_cmdCrcErr    (uCmd_io_cmdCrcErr         ), //i
    .io_respStatus   (uCmd_io_respStatus[31:0]  ), //i
    .io_respData     (uCmd_io_respData[127:0]   ), //i
    .io_cidReg       (uInit_io_cidReg[127:0]    ), //o
    .io_csdReg       (uInit_io_csdReg[127:0]    ), //o
    .io_rcaReg       (uInit_io_rcaReg[15:0]     ), //o
    .io_infoValid    (uInit_io_infoValid        ), //o
    .io_useFastClk   (uInit_io_useFastClk       ), //o
    .io_emmcRstnOut  (uInit_io_emmcRstnOut      ), //o
    .io_dbgRetryCnt  (uInit_io_dbgRetryCnt[7:0] ), //o
    .clk             (clk                       ), //i
    .resetn          (resetn                    )  //i
  );
  SectorBuf uSectorBuf (
    .io_bufSelA (uSectorBuf_io_bufSelA[1:0]), //i
    .io_addrA   (uDat_io_bufWrAddr[8:0]    ), //i
    .io_wdataA  (uDat_io_bufWrData[7:0]    ), //i
    .io_weA     (uDat_io_bufWrEn           ), //i
    .io_rdataA  (uSectorBuf_io_rdataA[7:0] ), //o
    .io_bufSelB (uSectorBuf_io_bufSelB[1:0]), //i
    .io_addrB   (uartRdAddr[8:0]           ), //i
    .io_wdataB  (8'h0                      ), //i
    .io_weB     (1'b0                      ), //i
    .io_rdataB  (uSectorBuf_io_rdataB[7:0] ), //o
    .clk        (clk                       ), //i
    .resetn     (resetn                    )  //i
  );
  SectorBufWr uWriteBuf (
    .io_rdBank (emmcBank[3:0]           ), //i
    .io_rdAddr (uDat_io_bufRdAddr[8:0]  ), //i
    .io_rdData (uWriteBuf_io_rdData[7:0]), //o
    .io_wrBank (uartWrBank[3:0]         ), //i
    .io_wrAddr (uartWrAddr[8:0]         ), //i
    .io_wrData (uartWrData[7:0]         ), //i
    .io_wrEn   (uartWrEn                ), //i
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  assign MC_IDLE = 5'h0;
  assign MC_INIT = 5'h01;
  assign MC_READY = 5'h02;
  assign MC_READ_CMD = 5'h03;
  assign MC_READ_DAT = 5'h04;
  assign MC_READ_DONE = 5'h05;
  assign MC_WRITE_CMD = 5'h06;
  assign MC_WRITE_DAT = 5'h07;
  assign MC_WRITE_DONE = 5'h08;
  assign MC_STOP_CMD = 5'h09;
  assign MC_ERROR = 5'h0a;
  assign MC_STOP_WAIT = 5'h0b;
  assign MC_EXT_CSD_CMD = 5'h0c;
  assign MC_EXT_CSD_DAT = 5'h0d;
  assign MC_SWITCH_CMD = 5'h0e;
  assign MC_SWITCH_WAIT = 5'h0f;
  assign MC_ERASE_START = 5'h10;
  assign MC_ERASE_END = 5'h11;
  assign MC_ERASE_CMD = 5'h12;
  assign MC_STATUS_CMD = 5'h13;
  assign MC_ERROR_STOP = 5'h14;
  assign MC_RAW_CMD = 5'h15;
  assign MC_RAW_WAIT = 5'h16;
  assign MC_RPMB_CMD23 = 5'h17;
  assign MC_RPMB_FIFO_WAIT = 5'h18;
  assign MC_SWITCH_STATUS = 5'h19;
  assign STATUS_OK = 8'h0;
  assign STATUS_CRC_ERR = 8'h01;
  assign STATUS_CMD_ERR = 8'h02;
  assign STATUS_EMMC_ERR = 8'h03;
  assign STATUS_BUSY = 8'h04;
  assign when_EmmcController_l141 = (clkDivCnt == 9'h0);
  assign when_EmmcController_l144 = (! emmcClkReg);
  assign when_EmmcController_l147 = (! clkPause);
  assign emmcClk = emmcClkReg;
  assign cmdErrorW = (uCmd_io_cmdTimeout || uCmd_io_cmdCrcErr);
  assign deviceStatusErr = (|(uCmd_io_respStatus & 32'h80f80080));
  assign cmdOut = uCmd_io_cmdOut;
  assign cmdOe = uCmd_io_cmdOe;
  assign datOut = uDat_io_datOut;
  assign datOe = uDat_io_datOe;
  assign emmcRstn = uInit_io_emmcRstnOut;
  assign cid = uInit_io_cidReg;
  assign csd = uInit_io_csdReg;
  assign infoValid = uInit_io_infoValid;
  assign uSectorBuf_io_bufSelA = emmcBank[1 : 0];
  assign uSectorBuf_io_bufSelB = uartRdBank;
  assign uartRdData = uSectorBuf_io_rdataB;
  assign uCmd_io_cmdStart = (isInitMode ? uInit_io_cmdStart : mcCmdStartR);
  assign uCmd_io_cmdIndex = (isInitMode ? uInit_io_cmdIndex : mcCmdIndexR);
  assign uCmd_io_cmdArgument = (isInitMode ? uInit_io_cmdArgument : mcCmdArgR);
  assign uCmd_io_respTypeLong = (isInitMode ? uInit_io_respTypeLong : rawRespLongR);
  assign uCmd_io_respExpected = (isInitMode ? uInit_io_respExpected : mcCmdRespExpR);
  assign statusArg = {uInit_io_rcaReg,16'h0};
  assign cmdReady = cmdReadyR;
  assign respStatus = respStatusR;
  assign respValid = respValidR;
  assign rdSectorReady = rdSectorReadyR;
  assign wrSectorAck = wrSectorAckR;
  assign cardStatus = cardStatusR;
  assign rawRespData = rawRespDataR;
  assign active = activeReg;
  assign ready = (mcState == MC_READY);
  assign error = (mcState == MC_ERROR);
  assign dbgInitState = uInit_io_initStateDbg;
  assign dbgMcState = mcState;
  assign dbgCmdPin = cmdInSync;
  assign dbgDat0Pin = datInSync[0];
  assign dbgCmdFsm = uCmd_io_dbgState;
  assign dbgDatFsm = uDat_io_dbgState;
  assign dbgPartition = currentPartition;
  assign dbgUseFastClk = useFastClk;
  assign dbgReinitPending = reinitPending;
  assign dbgInitRetryCnt = uInit_io_dbgRetryCnt;
  assign dbgClkPreset = currentClkPreset;
  assign dbgErrCmdTimeout = errCmdTimeoutCnt;
  assign dbgErrCmdCrc = errCmdCrcCnt;
  assign dbgErrDatRd = errDatRdCnt;
  assign dbgErrDatWr = errDatWrCnt;
  assign when_EmmcController_l357 = (reinitPending && (mcState == MC_IDLE));
  assign when_EmmcController_l363 = (uCmd_io_cmdTimeout && (! (&errCmdTimeoutCnt)));
  assign when_EmmcController_l366 = (uCmd_io_cmdCrcErr && (! (&errCmdCrcCnt)));
  assign when_EmmcController_l369 = (uDat_io_rdCrcErr && (! (&errDatRdCnt)));
  assign when_EmmcController_l372 = ((uDat_io_wrCrcErr || wrDoneTimeout) && (! (&errDatWrCnt)));
  assign presetVal = cmdLba[2 : 0];
  always @(*) begin
    presetDivM1 = 9'h00e;
    if(when_EmmcController_l468) begin
      presetDivM1 = 9'h007;
    end
    if(when_EmmcController_l469) begin
      presetDivM1 = 9'h004;
    end
    if(when_EmmcController_l470) begin
      presetDivM1 = 9'h002;
    end
    if(when_EmmcController_l471) begin
      presetDivM1 = 9'h001;
    end
    if(when_EmmcController_l472) begin
      presetDivM1 = 9'h001;
    end
    if(when_EmmcController_l473) begin
      presetDivM1 = 9'h0;
    end
  end

  assign when_EmmcController_l468 = (presetVal == 3'b001);
  assign when_EmmcController_l469 = (presetVal == 3'b010);
  assign when_EmmcController_l470 = (presetVal == 3'b011);
  assign when_EmmcController_l471 = (presetVal == 3'b100);
  assign when_EmmcController_l472 = (presetVal == 3'b101);
  assign when_EmmcController_l473 = (presetVal == 3'b110);
  assign when_EmmcController_l497 = (mcState == MC_IDLE);
  assign when_EmmcController_l520 = (bootRetryCnt < 2'b11);
  assign when_EmmcController_l538 = ((((cmdIsRead || cmdIsWrite) || cmdIsErase) || cmdIsSecureErase) && cmdCountIsZero);
  assign when_EmmcController_l596 = (presetVal <= 3'b110);
  assign when_EmmcController_l550 = (cmdIsWrite && cmdCountGtSixteen);
  assign when_EmmcController_l571 = (cmdIsErase || cmdIsSecureErase);
  assign when_EmmcController_l632 = (cmdErrorW || deviceStatusErr);
  assign when_EmmcController_l660 = (sectorsLeft == 16'h0);
  assign when_EmmcController_l662 = (useMultiBlock && (! forceMultiBlock));
  assign when_EmmcController_l677 = ((! rdSectorReadyR) || rdSectorAck);
  assign when_EmmcController_l692 = (cmdErrorW || deviceStatusErr);
  assign when_EmmcController_l718 = (sectorsLeft == 16'h0);
  assign when_EmmcController_l720 = (useMultiBlock && (! forceMultiBlock));
  assign when_EmmcController_l735 = (&wrDoneWatchdog);
  assign when_EmmcController_l784 = datInSync[0];
  assign when_EmmcController_l791 = (switchWaitCnt == 20'hfffff);
  assign when_EmmcController_l801 = (cmdErrorW || deviceStatusErr);
  assign when_EmmcController_l847 = datInSync[0];
  assign when_EmmcController_l864 = (switchWaitCnt == 20'hfffff);
  assign when_EmmcController_l876 = (cmdErrorW || deviceStatusErr);
  assign when_EmmcController_l900 = (cmdErrorW || deviceStatusErr);
  assign when_EmmcController_l915 = (cmdErrorW || deviceStatusErr);
  assign when_EmmcController_l930 = (cmdErrorW || deviceStatusErr);
  assign when_EmmcController_l999 = (&wrDoneWatchdog);
  assign when_EmmcController_l1036 = datInSync[0];
  assign when_EmmcController_l1043 = (switchWaitCnt == 20'hfffff);
  assign when_EmmcController_l502 = (mcState == MC_INIT);
  assign when_EmmcController_l528 = (mcState == MC_READY);
  assign when_EmmcController_l629 = (mcState == MC_READ_CMD);
  assign when_EmmcController_l643 = (mcState == MC_READ_DAT);
  assign when_EmmcController_l659 = (mcState == MC_READ_DONE);
  assign when_EmmcController_l690 = (mcState == MC_WRITE_CMD);
  assign when_EmmcController_l703 = (mcState == MC_WRITE_DAT);
  assign when_EmmcController_l717 = (mcState == MC_WRITE_DONE);
  assign when_EmmcController_l768 = (mcState == MC_STOP_CMD);
  assign when_EmmcController_l781 = (mcState == MC_STOP_WAIT);
  assign when_EmmcController_l798 = (mcState == MC_EXT_CSD_CMD);
  assign when_EmmcController_l812 = (mcState == MC_EXT_CSD_DAT);
  assign when_EmmcController_l828 = (mcState == MC_SWITCH_CMD);
  assign when_EmmcController_l844 = (mcState == MC_SWITCH_WAIT);
  assign when_EmmcController_l872 = (mcState == MC_SWITCH_STATUS);
  assign when_EmmcController_l897 = (mcState == MC_ERASE_START);
  assign when_EmmcController_l912 = (mcState == MC_ERASE_END);
  assign when_EmmcController_l927 = (mcState == MC_ERASE_CMD);
  assign when_EmmcController_l942 = (mcState == MC_STATUS_CMD);
  assign when_EmmcController_l960 = (mcState == MC_RPMB_CMD23);
  assign when_EmmcController_l989 = (mcState == MC_RPMB_FIFO_WAIT);
  assign when_EmmcController_l1008 = (mcState == MC_RAW_CMD);
  assign when_EmmcController_l1033 = (mcState == MC_RAW_WAIT);
  assign when_EmmcController_l1050 = (mcState == MC_ERROR);
  assign when_EmmcController_l1063 = (mcState == MC_ERROR_STOP);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      useFastClk <= 1'b0;
      fastClkDivReload <= 9'h00e;
      currentClkPreset <= 3'b000;
      clkDivCnt <= 9'h0e0;
      clkDivReload <= 9'h0e0;
      emmcClkReg <= 1'b0;
      clkEn <= 1'b0;
      clkPause <= 1'b0;
      cmdInMeta <= 1'b1;
      cmdInSync <= 1'b1;
      datInMeta <= 4'b1111;
      datInSync <= 4'b1111;
      datRdStart <= 1'b0;
      datWrStart <= 1'b0;
      busWidth4 <= 1'b0;
      busWidthSwitchPending <= 1'b0;
      busWidthTarget <= 1'b0;
      initStart <= 1'b0;
      emmcBank <= 4'b0000;
      uartRdBank <= 2'b00;
      uartRdBankNext <= 2'b00;
      isInitMode <= 1'b1;
      mcCmdStartR <= 1'b0;
      mcCmdIndexR <= 6'h0;
      mcCmdArgR <= 32'h0;
      mcCmdRespExpR <= 1'b0;
      rawRespLongR <= 1'b0;
      mcState <= MC_IDLE;
      currentLba <= 32'h0;
      nextLba <= 32'h00000001;
      sectorsLeft <= 16'h0;
      eraseEndLba <= 32'h0;
      useMultiBlock <= 1'b0;
      isReadOp <= 1'b0;
      currentPartition <= 2'b00;
      reinitPending <= 1'b0;
      eraseSecure <= 1'b0;
      bootRetryCnt <= 2'b00;
      rawCheckBusy <= 1'b0;
      forceMultiBlock <= 1'b0;
      switchNeedsVerify <= 1'b0;
      cmdReadyR <= 1'b0;
      respStatusR <= 8'h0;
      respValidR <= 1'b0;
      rdSectorReadyR <= 1'b0;
      wrSectorAckR <= 1'b0;
      cardStatusR <= 32'h0;
      rawRespDataR <= 128'h0;
      switchWaitCnt <= 20'h0;
      wrDoneWatchdog <= 24'h0;
      wrDoneTimeout <= 1'b0;
      activeReg <= 1'b0;
      errCmdTimeoutCnt <= 8'h0;
      errCmdCrcCnt <= 8'h0;
      errDatRdCnt <= 8'h0;
      errDatWrCnt <= 8'h0;
      cmdIsRead <= 1'b0;
      cmdIsWrite <= 1'b0;
      cmdIsErase <= 1'b0;
      cmdIsExtCsd <= 1'b0;
      cmdIsPartition <= 1'b0;
      cmdIsWriteExtCsd <= 1'b0;
      cmdIsStatus <= 1'b0;
      cmdIsReinit <= 1'b0;
      cmdIsSecureErase <= 1'b0;
      cmdIsSetClk <= 1'b0;
      cmdIsRaw <= 1'b0;
      cmdIsSetRpmbMode <= 1'b0;
      cmdIsSetBusWidth <= 1'b0;
      cmdCountIsZero <= 1'b1;
      cmdCountGtOne <= 1'b0;
      cmdCountGtSixteen <= 1'b0;
      cmdValidD <= 1'b0;
      wrSectorValidD <= 1'b0;
      preCmdArgument <= 32'h0;
      preCmdIndex <= 6'h0;
      preCmdRespExp <= 1'b0;
      preEraseEndLba <= 32'h0;
    end else begin
      clkEn <= 1'b0;
      if(when_EmmcController_l141) begin
        clkDivCnt <= clkDivReload;
        emmcClkReg <= (! emmcClkReg);
        if(when_EmmcController_l144) begin
          clkEn <= 1'b1;
        end
      end else begin
        if(when_EmmcController_l147) begin
          clkDivCnt <= (clkDivCnt - 9'h001);
        end
      end
      if(useFastClk) begin
        clkDivReload <= fastClkDivReload;
      end else begin
        clkDivReload <= 9'h0e0;
      end
      cmdInMeta <= cmdIn;
      cmdInSync <= cmdInMeta;
      datInMeta <= datIn;
      datInSync <= datInMeta;
      activeReg <= ((mcState != MC_IDLE) && (mcState != MC_READY));
      if(when_EmmcController_l357) begin
        errCmdTimeoutCnt <= 8'h0;
        errCmdCrcCnt <= 8'h0;
        errDatRdCnt <= 8'h0;
        errDatWrCnt <= 8'h0;
      end else begin
        if(when_EmmcController_l363) begin
          errCmdTimeoutCnt <= (errCmdTimeoutCnt + 8'h01);
        end
        if(when_EmmcController_l366) begin
          errCmdCrcCnt <= (errCmdCrcCnt + 8'h01);
        end
        if(when_EmmcController_l369) begin
          errDatRdCnt <= (errDatRdCnt + 8'h01);
        end
        if(when_EmmcController_l372) begin
          errDatWrCnt <= (errDatWrCnt + 8'h01);
        end
      end
      cmdIsRead <= (cmdId == 8'h03);
      cmdIsWrite <= (cmdId == 8'h04);
      cmdIsErase <= (cmdId == 8'h05);
      cmdIsExtCsd <= (cmdId == 8'h07);
      cmdIsPartition <= (cmdId == 8'h08);
      cmdIsWriteExtCsd <= (cmdId == 8'h09);
      cmdIsStatus <= (cmdId == 8'h0a);
      cmdIsReinit <= (cmdId == 8'h0b);
      cmdIsSecureErase <= (cmdId == 8'h0c);
      cmdIsSetClk <= (cmdId == 8'h0d);
      cmdIsRaw <= (cmdId == 8'h0e);
      cmdIsSetRpmbMode <= (cmdId == 8'h10);
      cmdIsSetBusWidth <= (cmdId == 8'h11);
      cmdCountIsZero <= (cmdCount == 16'h0);
      cmdCountGtOne <= (16'h0001 < cmdCount);
      cmdCountGtSixteen <= (16'h0010 < cmdCount);
      cmdValidD <= cmdValid;
      wrSectorValidD <= uartWrSectorValid;
      preCmdRespExp <= 1'b1;
      case(cmdId)
        8'h03 : begin
          preCmdArgument <= cmdLba;
          preCmdIndex <= (((16'h0001 < cmdCount) || forceMultiBlock) ? 6'h12 : 6'h11);
        end
        8'h04 : begin
          preCmdArgument <= cmdLba;
          preCmdIndex <= (((16'h0001 < cmdCount) || forceMultiBlock) ? 6'h19 : 6'h18);
        end
        8'h05, 8'h0c : begin
          preCmdArgument <= cmdLba;
          preCmdIndex <= 6'h23;
          preEraseEndLba <= (_zz_preEraseEndLba - 32'h00000001);
        end
        8'h07 : begin
          preCmdArgument <= 32'h0;
          preCmdIndex <= 6'h08;
        end
        8'h08 : begin
          preCmdArgument <= {{{{6'h0,2'b11},8'hb3},cmdLba[7 : 0]},8'h0};
          preCmdIndex <= 6'h06;
        end
        8'h09 : begin
          preCmdArgument <= {{{{6'h0,2'b11},cmdLba[15 : 8]},cmdLba[7 : 0]},8'h0};
          preCmdIndex <= 6'h06;
        end
        8'h0a : begin
          preCmdArgument <= statusArg;
          preCmdIndex <= 6'h0d;
        end
        8'h11 : begin
          preCmdArgument <= {{{{6'h0,2'b11},8'hb7},(cmdLba[0] ? 8'h01 : 8'h0)},8'h0};
          preCmdIndex <= 6'h06;
        end
        8'h0e : begin
          preCmdArgument <= cmdLba;
          preCmdIndex <= cmdCount[5 : 0];
          preCmdRespExp <= cmdCount[8];
        end
        default : begin
          preCmdArgument <= 32'h0;
          preCmdIndex <= 6'h0;
          preCmdRespExp <= 1'b0;
        end
      endcase
      initStart <= 1'b0;
      datRdStart <= 1'b0;
      datWrStart <= 1'b0;
      mcCmdStartR <= 1'b0;
      respValidR <= 1'b0;
      wrSectorAckR <= 1'b0;
      wrDoneTimeout <= 1'b0;
      if(rdSectorAck) begin
        rdSectorReadyR <= 1'b0;
        uartRdBank <= uartRdBankNext;
      end
      nextLba <= (currentLba + 32'h00000001);
      if(when_EmmcController_l497) begin
        isInitMode <= 1'b1;
        initStart <= 1'b1;
        mcState <= MC_INIT;
      end else begin
        if(when_EmmcController_l502) begin
          useFastClk <= uInit_io_useFastClk;
          if(uInit_io_initDone) begin
            isInitMode <= 1'b0;
            cmdReadyR <= 1'b1;
            mcState <= MC_READY;
            if(reinitPending) begin
              respStatusR <= STATUS_OK;
              respValidR <= 1'b1;
              reinitPending <= 1'b0;
            end
          end else begin
            if(uInit_io_initError) begin
              if(reinitPending) begin
                respStatusR <= STATUS_EMMC_ERR;
                respValidR <= 1'b1;
                cmdReadyR <= 1'b1;
                reinitPending <= 1'b0;
                mcState <= MC_READY;
              end else begin
                if(when_EmmcController_l520) begin
                  bootRetryCnt <= (bootRetryCnt + 2'b01);
                  mcState <= MC_IDLE;
                end else begin
                  mcState <= MC_ERROR;
                end
              end
            end
          end
        end else begin
          if(when_EmmcController_l528) begin
            if(cmdValidD) begin
              cmdReadyR <= 1'b0;
              mcCmdArgR <= preCmdArgument;
              mcCmdIndexR <= preCmdIndex;
              mcCmdRespExpR <= preCmdRespExp;
              if(when_EmmcController_l538) begin
                respStatusR <= STATUS_CMD_ERR;
                respValidR <= 1'b1;
                cmdReadyR <= 1'b1;
              end else begin
                if(cmdIsRead) begin
                  currentLba <= cmdLba;
                  sectorsLeft <= cmdCount;
                  isReadOp <= 1'b1;
                  useMultiBlock <= (cmdCountGtOne || forceMultiBlock);
                  mcState <= (forceMultiBlock ? MC_RPMB_CMD23 : MC_READ_CMD);
                end else begin
                  if(when_EmmcController_l550) begin
                    respStatusR <= STATUS_CMD_ERR;
                    respValidR <= 1'b1;
                    cmdReadyR <= 1'b1;
                  end else begin
                    if(cmdIsWrite) begin
                      currentLba <= cmdLba;
                      sectorsLeft <= cmdCount;
                      isReadOp <= 1'b0;
                      useMultiBlock <= (cmdCountGtOne || forceMultiBlock);
                      emmcBank <= 4'b0000;
                      if(forceMultiBlock) begin
                        mcState <= MC_RPMB_CMD23;
                      end else begin
                        if(wrSectorValidD) begin
                          wrSectorAckR <= 1'b1;
                          mcState <= MC_WRITE_CMD;
                        end
                      end
                    end else begin
                      if(cmdIsExtCsd) begin
                        mcState <= MC_EXT_CSD_CMD;
                      end else begin
                        if(when_EmmcController_l571) begin
                          currentLba <= cmdLba;
                          sectorsLeft <= cmdCount;
                          eraseSecure <= cmdIsSecureErase;
                          eraseEndLba <= preEraseEndLba;
                          mcState <= MC_ERASE_START;
                        end else begin
                          if(cmdIsPartition) begin
                            currentPartition <= cmdLba[1 : 0];
                            mcState <= MC_SWITCH_CMD;
                          end else begin
                            if(cmdIsWriteExtCsd) begin
                              mcState <= MC_SWITCH_CMD;
                            end else begin
                              if(cmdIsStatus) begin
                                mcState <= MC_STATUS_CMD;
                              end else begin
                                if(cmdIsReinit) begin
                                  reinitPending <= 1'b1;
                                  useFastClk <= 1'b0;
                                  busWidth4 <= 1'b0;
                                  busWidthSwitchPending <= 1'b0;
                                  mcState <= MC_IDLE;
                                end else begin
                                  if(cmdIsSetClk) begin
                                    if(when_EmmcController_l596) begin
                                      fastClkDivReload <= presetDivM1;
                                      currentClkPreset <= presetVal;
                                      respStatusR <= STATUS_OK;
                                    end else begin
                                      respStatusR <= STATUS_CMD_ERR;
                                    end
                                    respValidR <= 1'b1;
                                    cmdReadyR <= 1'b1;
                                  end else begin
                                    if(cmdIsSetRpmbMode) begin
                                      forceMultiBlock <= cmdLba[0];
                                      respStatusR <= STATUS_OK;
                                      respValidR <= 1'b1;
                                      cmdReadyR <= 1'b1;
                                    end else begin
                                      if(cmdIsSetBusWidth) begin
                                        busWidthSwitchPending <= 1'b1;
                                        busWidthTarget <= cmdLba[0];
                                        mcState <= MC_SWITCH_CMD;
                                      end else begin
                                        if(cmdIsRaw) begin
                                          rawCheckBusy <= cmdCount[10];
                                          rawRespLongR <= cmdCount[9];
                                          mcState <= MC_RAW_CMD;
                                        end else begin
                                          respStatusR <= STATUS_CMD_ERR;
                                          respValidR <= 1'b1;
                                          cmdReadyR <= 1'b1;
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
          end else begin
            if(when_EmmcController_l629) begin
              isInitMode <= 1'b0;
              if(uCmd_io_cmdDone) begin
                if(when_EmmcController_l632) begin
                  respStatusR <= STATUS_EMMC_ERR;
                  mcState <= MC_ERROR;
                end else begin
                  datRdStart <= 1'b1;
                  mcState <= MC_READ_DAT;
                end
              end else begin
                mcCmdStartR <= 1'b1;
              end
            end else begin
              if(when_EmmcController_l643) begin
                if(uDat_io_rdDone) begin
                  if(uDat_io_rdCrcErr) begin
                    respStatusR <= STATUS_EMMC_ERR;
                    mcState <= MC_ERROR;
                  end else begin
                    rdSectorReadyR <= 1'b1;
                    uartRdBankNext <= emmcBank[1 : 0];
                    emmcBank <= (emmcBank + 4'b0001);
                    sectorsLeft <= (sectorsLeft - 16'h0001);
                    currentLba <= nextLba;
                    mcCmdArgR <= nextLba;
                    mcState <= MC_READ_DONE;
                  end
                end
              end else begin
                if(when_EmmcController_l659) begin
                  if(when_EmmcController_l660) begin
                    clkPause <= 1'b0;
                    if(when_EmmcController_l662) begin
                      mcCmdIndexR <= 6'h0c;
                      mcCmdArgR <= 32'h0;
                      mcCmdRespExpR <= 1'b1;
                      mcState <= MC_STOP_CMD;
                    end else begin
                      respStatusR <= STATUS_OK;
                      respValidR <= 1'b1;
                      cmdReadyR <= 1'b1;
                      mcState <= MC_READY;
                    end
                  end else begin
                    if(useMultiBlock) begin
                      if(when_EmmcController_l677) begin
                        clkPause <= 1'b0;
                        datRdStart <= 1'b1;
                        mcState <= MC_READ_DAT;
                      end else begin
                        clkPause <= 1'b1;
                      end
                    end else begin
                      mcState <= MC_READ_CMD;
                    end
                  end
                end else begin
                  if(when_EmmcController_l690) begin
                    if(uCmd_io_cmdDone) begin
                      if(when_EmmcController_l692) begin
                        respStatusR <= STATUS_EMMC_ERR;
                        mcState <= MC_ERROR;
                      end else begin
                        datWrStart <= 1'b1;
                        mcState <= MC_WRITE_DAT;
                      end
                    end else begin
                      mcCmdStartR <= 1'b1;
                    end
                  end else begin
                    if(when_EmmcController_l703) begin
                      if(uDat_io_wrDone) begin
                        if(uDat_io_wrCrcErr) begin
                          respStatusR <= STATUS_EMMC_ERR;
                          mcState <= MC_ERROR;
                        end else begin
                          sectorsLeft <= (sectorsLeft - 16'h0001);
                          currentLba <= nextLba;
                          mcCmdArgR <= nextLba;
                          wrDoneWatchdog <= 24'h0;
                          mcState <= MC_WRITE_DONE;
                        end
                      end
                    end else begin
                      if(when_EmmcController_l717) begin
                        if(when_EmmcController_l718) begin
                          wrDoneWatchdog <= 24'h0;
                          if(when_EmmcController_l720) begin
                            mcCmdIndexR <= 6'h0c;
                            mcCmdArgR <= 32'h0;
                            mcCmdRespExpR <= 1'b1;
                            mcState <= MC_STOP_CMD;
                          end else begin
                            respStatusR <= STATUS_OK;
                            respValidR <= 1'b1;
                            cmdReadyR <= 1'b1;
                            mcState <= MC_READY;
                          end
                        end else begin
                          wrDoneWatchdog <= (wrDoneWatchdog + 24'h000001);
                          if(when_EmmcController_l735) begin
                            if(useMultiBlock) begin
                              mcCmdIndexR <= 6'h0c;
                              mcCmdArgR <= 32'h0;
                              mcCmdRespExpR <= 1'b1;
                              mcState <= MC_ERROR_STOP;
                            end else begin
                              respStatusR <= STATUS_EMMC_ERR;
                              respValidR <= 1'b1;
                              cmdReadyR <= 1'b1;
                              mcState <= MC_READY;
                            end
                            wrDoneTimeout <= 1'b1;
                          end else begin
                            if(useMultiBlock) begin
                              if(uartWrSectorValid) begin
                                wrDoneWatchdog <= 24'h0;
                                wrSectorAckR <= 1'b1;
                                emmcBank <= (emmcBank + 4'b0001);
                                datWrStart <= 1'b1;
                                mcState <= MC_WRITE_DAT;
                              end
                            end else begin
                              if(uartWrSectorValid) begin
                                wrDoneWatchdog <= 24'h0;
                                wrSectorAckR <= 1'b1;
                                emmcBank <= (emmcBank + 4'b0001);
                                mcState <= MC_WRITE_CMD;
                              end
                            end
                          end
                        end
                      end else begin
                        if(when_EmmcController_l768) begin
                          if(uCmd_io_cmdDone) begin
                            if(cmdErrorW) begin
                              respStatusR <= STATUS_EMMC_ERR;
                              mcState <= MC_ERROR;
                            end else begin
                              switchWaitCnt <= 20'h0;
                              mcState <= MC_STOP_WAIT;
                            end
                          end else begin
                            mcCmdStartR <= 1'b1;
                          end
                        end else begin
                          if(when_EmmcController_l781) begin
                            if(clkEn) begin
                              if(when_EmmcController_l784) begin
                                respStatusR <= STATUS_OK;
                                respValidR <= 1'b1;
                                cmdReadyR <= 1'b1;
                                mcState <= MC_READY;
                              end else begin
                                switchWaitCnt <= (switchWaitCnt + 20'h00001);
                                if(when_EmmcController_l791) begin
                                  respStatusR <= STATUS_EMMC_ERR;
                                  mcState <= MC_ERROR;
                                end
                              end
                            end
                          end else begin
                            if(when_EmmcController_l798) begin
                              isInitMode <= 1'b0;
                              if(uCmd_io_cmdDone) begin
                                if(when_EmmcController_l801) begin
                                  respStatusR <= STATUS_EMMC_ERR;
                                  mcState <= MC_ERROR;
                                end else begin
                                  datRdStart <= 1'b1;
                                  mcState <= MC_EXT_CSD_DAT;
                                end
                              end else begin
                                mcCmdStartR <= 1'b1;
                              end
                            end else begin
                              if(when_EmmcController_l812) begin
                                if(uDat_io_rdDone) begin
                                  if(uDat_io_rdCrcErr) begin
                                    respStatusR <= STATUS_EMMC_ERR;
                                    mcState <= MC_ERROR;
                                  end else begin
                                    rdSectorReadyR <= 1'b1;
                                    uartRdBankNext <= emmcBank[1 : 0];
                                    emmcBank <= (emmcBank + 4'b0001);
                                    respStatusR <= STATUS_OK;
                                    respValidR <= 1'b1;
                                    cmdReadyR <= 1'b1;
                                    mcState <= MC_READY;
                                  end
                                end
                              end else begin
                                if(when_EmmcController_l828) begin
                                  isInitMode <= 1'b0;
                                  if(uCmd_io_cmdDone) begin
                                    if(cmdErrorW) begin
                                      busWidthSwitchPending <= 1'b0;
                                      respStatusR <= STATUS_EMMC_ERR;
                                      mcState <= MC_ERROR;
                                    end else begin
                                      switchNeedsVerify <= 1'b1;
                                      switchWaitCnt <= 20'h0;
                                      mcState <= MC_SWITCH_WAIT;
                                    end
                                  end else begin
                                    mcCmdStartR <= 1'b1;
                                  end
                                end else begin
                                  if(when_EmmcController_l844) begin
                                    if(clkEn) begin
                                      if(when_EmmcController_l847) begin
                                        if(switchNeedsVerify) begin
                                          mcCmdIndexR <= 6'h0d;
                                          mcCmdArgR <= statusArg;
                                          mcCmdRespExpR <= 1'b1;
                                          rawRespLongR <= 1'b0;
                                          mcState <= MC_SWITCH_STATUS;
                                        end else begin
                                          respStatusR <= STATUS_OK;
                                          respValidR <= 1'b1;
                                          cmdReadyR <= 1'b1;
                                          mcState <= MC_READY;
                                        end
                                      end else begin
                                        switchWaitCnt <= (switchWaitCnt + 20'h00001);
                                        if(when_EmmcController_l864) begin
                                          busWidthSwitchPending <= 1'b0;
                                          respStatusR <= STATUS_EMMC_ERR;
                                          mcState <= MC_ERROR;
                                        end
                                      end
                                    end
                                  end else begin
                                    if(when_EmmcController_l872) begin
                                      isInitMode <= 1'b0;
                                      if(uCmd_io_cmdDone) begin
                                        if(when_EmmcController_l876) begin
                                          busWidthSwitchPending <= 1'b0;
                                          respStatusR <= STATUS_EMMC_ERR;
                                          respValidR <= 1'b1;
                                          cmdReadyR <= 1'b1;
                                          mcState <= MC_READY;
                                        end else begin
                                          if(busWidthSwitchPending) begin
                                            busWidth4 <= busWidthTarget;
                                            busWidthSwitchPending <= 1'b0;
                                          end
                                          respStatusR <= STATUS_OK;
                                          respValidR <= 1'b1;
                                          cmdReadyR <= 1'b1;
                                          mcState <= MC_READY;
                                        end
                                      end else begin
                                        mcCmdStartR <= 1'b1;
                                      end
                                    end else begin
                                      if(when_EmmcController_l897) begin
                                        if(uCmd_io_cmdDone) begin
                                          if(when_EmmcController_l900) begin
                                            respStatusR <= STATUS_EMMC_ERR;
                                            mcState <= MC_ERROR;
                                          end else begin
                                            mcCmdIndexR <= 6'h24;
                                            mcCmdArgR <= eraseEndLba;
                                            mcState <= MC_ERASE_END;
                                          end
                                        end else begin
                                          mcCmdStartR <= 1'b1;
                                        end
                                      end else begin
                                        if(when_EmmcController_l912) begin
                                          if(uCmd_io_cmdDone) begin
                                            if(when_EmmcController_l915) begin
                                              respStatusR <= STATUS_EMMC_ERR;
                                              mcState <= MC_ERROR;
                                            end else begin
                                              mcCmdIndexR <= 6'h26;
                                              mcCmdArgR <= (eraseSecure ? 32'h80000000 : 32'h0);
                                              mcState <= MC_ERASE_CMD;
                                            end
                                          end else begin
                                            mcCmdStartR <= 1'b1;
                                          end
                                        end else begin
                                          if(when_EmmcController_l927) begin
                                            if(uCmd_io_cmdDone) begin
                                              if(when_EmmcController_l930) begin
                                                respStatusR <= STATUS_EMMC_ERR;
                                                mcState <= MC_ERROR;
                                              end else begin
                                                switchNeedsVerify <= 1'b0;
                                                switchWaitCnt <= 20'h0;
                                                mcState <= MC_SWITCH_WAIT;
                                              end
                                            end else begin
                                              mcCmdStartR <= 1'b1;
                                            end
                                          end else begin
                                            if(when_EmmcController_l942) begin
                                              isInitMode <= 1'b0;
                                              if(uCmd_io_cmdDone) begin
                                                if(cmdErrorW) begin
                                                  respStatusR <= STATUS_EMMC_ERR;
                                                  mcState <= MC_ERROR;
                                                end else begin
                                                  cardStatusR <= uCmd_io_respStatus;
                                                  respStatusR <= STATUS_OK;
                                                  respValidR <= 1'b1;
                                                  cmdReadyR <= 1'b1;
                                                  mcState <= MC_READY;
                                                end
                                              end else begin
                                                mcCmdStartR <= 1'b1;
                                              end
                                            end else begin
                                              if(when_EmmcController_l960) begin
                                                if(uCmd_io_cmdDone) begin
                                                  if(cmdErrorW) begin
                                                    respStatusR <= STATUS_EMMC_ERR;
                                                    mcState <= MC_ERROR;
                                                  end else begin
                                                    if(isReadOp) begin
                                                      mcCmdIndexR <= preCmdIndex;
                                                      mcCmdArgR <= preCmdArgument;
                                                      mcCmdRespExpR <= 1'b1;
                                                      mcState <= MC_READ_CMD;
                                                    end else begin
                                                      if(wrSectorValidD) begin
                                                        mcCmdIndexR <= preCmdIndex;
                                                        mcCmdArgR <= preCmdArgument;
                                                        mcCmdRespExpR <= 1'b1;
                                                        mcState <= MC_WRITE_CMD;
                                                      end else begin
                                                        wrDoneWatchdog <= 24'h0;
                                                        mcState <= MC_RPMB_FIFO_WAIT;
                                                      end
                                                    end
                                                  end
                                                end else begin
                                                  mcCmdIndexR <= 6'h17;
                                                  mcCmdArgR <= (isReadOp ? 32'h00000001 : 32'h80000001);
                                                  mcCmdRespExpR <= 1'b1;
                                                  mcCmdStartR <= 1'b1;
                                                end
                                              end else begin
                                                if(when_EmmcController_l989) begin
                                                  if(wrSectorValidD) begin
                                                    wrDoneWatchdog <= 24'h0;
                                                    mcCmdIndexR <= preCmdIndex;
                                                    mcCmdArgR <= preCmdArgument;
                                                    mcCmdRespExpR <= 1'b1;
                                                    mcState <= MC_WRITE_CMD;
                                                  end else begin
                                                    wrDoneWatchdog <= (wrDoneWatchdog + 24'h000001);
                                                    if(when_EmmcController_l999) begin
                                                      respStatusR <= STATUS_EMMC_ERR;
                                                      wrDoneTimeout <= 1'b1;
                                                      respValidR <= 1'b1;
                                                      cmdReadyR <= 1'b1;
                                                      mcState <= MC_READY;
                                                    end
                                                  end
                                                end else begin
                                                  if(when_EmmcController_l1008) begin
                                                    if(uCmd_io_cmdDone) begin
                                                      rawRespLongR <= 1'b0;
                                                      if(cmdErrorW) begin
                                                        respStatusR <= STATUS_EMMC_ERR;
                                                        respValidR <= 1'b1;
                                                        cmdReadyR <= 1'b1;
                                                        mcState <= MC_READY;
                                                      end else begin
                                                        cardStatusR <= uCmd_io_respStatus;
                                                        rawRespDataR <= uCmd_io_respData;
                                                        if(rawCheckBusy) begin
                                                          switchWaitCnt <= 20'h0;
                                                          mcState <= MC_RAW_WAIT;
                                                        end else begin
                                                          respStatusR <= STATUS_OK;
                                                          respValidR <= 1'b1;
                                                          cmdReadyR <= 1'b1;
                                                          mcState <= MC_READY;
                                                        end
                                                      end
                                                    end else begin
                                                      mcCmdStartR <= 1'b1;
                                                    end
                                                  end else begin
                                                    if(when_EmmcController_l1033) begin
                                                      if(clkEn) begin
                                                        if(when_EmmcController_l1036) begin
                                                          respStatusR <= STATUS_OK;
                                                          respValidR <= 1'b1;
                                                          cmdReadyR <= 1'b1;
                                                          mcState <= MC_READY;
                                                        end else begin
                                                          switchWaitCnt <= (switchWaitCnt + 20'h00001);
                                                          if(when_EmmcController_l1043) begin
                                                            respStatusR <= STATUS_EMMC_ERR;
                                                            mcState <= MC_ERROR;
                                                          end
                                                        end
                                                      end
                                                    end else begin
                                                      if(when_EmmcController_l1050) begin
                                                        if(useMultiBlock) begin
                                                          mcCmdIndexR <= 6'h0c;
                                                          mcCmdArgR <= 32'h0;
                                                          mcCmdRespExpR <= 1'b1;
                                                          mcState <= MC_ERROR_STOP;
                                                        end else begin
                                                          respValidR <= 1'b1;
                                                          cmdReadyR <= 1'b1;
                                                          mcState <= MC_READY;
                                                        end
                                                      end else begin
                                                        if(when_EmmcController_l1063) begin
                                                          if(uCmd_io_cmdDone) begin
                                                            respValidR <= 1'b1;
                                                            cmdReadyR <= 1'b1;
                                                            mcState <= MC_READY;
                                                          end else begin
                                                            mcCmdStartR <= 1'b1;
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

module SectorBufWr (
  input  wire [3:0]    io_rdBank,
  input  wire [8:0]    io_rdAddr,
  output wire [7:0]    io_rdData,
  input  wire [3:0]    io_wrBank,
  input  wire [8:0]    io_wrAddr,
  input  wire [7:0]    io_wrData,
  input  wire          io_wrEn,
  input  wire          clk,
  input  wire          resetn
);

  reg        [7:0]    memLo_spinal_port0;
  reg        [7:0]    memHi_spinal_port0;
  wire                _zz_memLo_port;
  wire                _zz_rdDataLo;
  wire                _zz_memLo_port_1;
  wire                _zz_memHi_port;
  wire                _zz_rdDataHi;
  wire                _zz_memHi_port_1;
  wire                halfSelRd;
  wire                halfSelWr;
  wire       [11:0]   halfRdAddr;
  wire       [11:0]   halfWrAddr;
  wire       [7:0]    rdDataLo;
  wire       [7:0]    rdDataHi;
  reg                 halfSelRdR;
  reg [7:0] memLo [0:4095];
  reg [7:0] memHi [0:4095];

  assign _zz_rdDataLo = 1'b1;
  assign _zz_memLo_port_1 = (io_wrEn && (! halfSelWr));
  assign _zz_rdDataHi = 1'b1;
  assign _zz_memHi_port_1 = (io_wrEn && halfSelWr);
  always @(posedge clk) begin
    if(_zz_rdDataLo) begin
      memLo_spinal_port0 <= memLo[halfRdAddr];
    end
  end

  always @(posedge clk) begin
    if(_zz_memLo_port_1) begin
      memLo[halfWrAddr] <= io_wrData;
    end
  end

  always @(posedge clk) begin
    if(_zz_rdDataHi) begin
      memHi_spinal_port0 <= memHi[halfRdAddr];
    end
  end

  always @(posedge clk) begin
    if(_zz_memHi_port_1) begin
      memHi[halfWrAddr] <= io_wrData;
    end
  end

  assign halfSelRd = io_rdBank[3];
  assign halfSelWr = io_wrBank[3];
  assign halfRdAddr = {io_rdBank[2 : 0],io_rdAddr};
  assign halfWrAddr = {io_wrBank[2 : 0],io_wrAddr};
  assign rdDataLo = memLo_spinal_port0;
  assign rdDataHi = memHi_spinal_port0;
  assign io_rdData = (halfSelRdR ? rdDataHi : rdDataLo);
  always @(posedge clk) begin
    halfSelRdR <= halfSelRd;
  end


endmodule

module SectorBuf (
  input  wire [1:0]    io_bufSelA,
  input  wire [8:0]    io_addrA,
  input  wire [7:0]    io_wdataA,
  input  wire          io_weA,
  output wire [7:0]    io_rdataA,
  input  wire [1:0]    io_bufSelB,
  input  wire [8:0]    io_addrB,
  input  wire [7:0]    io_wdataB,
  input  wire          io_weB,
  output wire [7:0]    io_rdataB,
  input  wire          clk,
  input  wire          resetn
);

  reg        [7:0]    mem_spinal_port0;
  reg        [7:0]    mem_spinal_port1;
  wire                _zz_mem_port;
  wire                _zz_io_rdataA_1;
  wire                _zz_mem_port_1;
  wire                _zz_io_rdataB_1;
  wire       [9:0]    fullAddrA;
  wire       [9:0]    fullAddrB;
  wire       [7:0]    _zz_io_rdataA;
  wire       [7:0]    _zz_io_rdataB;
  reg [7:0] mem [0:1023];

  assign _zz_io_rdataA_1 = 1'b1;
  assign _zz_io_rdataB_1 = 1'b1;
  always @(posedge clk) begin
    if(_zz_io_rdataA_1) begin
      mem_spinal_port0 <= mem[fullAddrA];
    end
  end

  always @(posedge clk) begin
    if(_zz_io_rdataA_1 && io_weA ) begin
      mem[fullAddrA] <= _zz_io_rdataA;
    end
  end

  always @(posedge clk) begin
    if(_zz_io_rdataB_1) begin
      mem_spinal_port1 <= mem[fullAddrB];
    end
  end

  always @(posedge clk) begin
    if(_zz_io_rdataB_1 && io_weB ) begin
      mem[fullAddrB] <= _zz_io_rdataB;
    end
  end

  assign fullAddrA = {io_bufSelA[0],io_addrA};
  assign fullAddrB = {io_bufSelB[0],io_addrB};
  assign _zz_io_rdataA = io_wdataA;
  assign io_rdataA = mem_spinal_port0;
  assign _zz_io_rdataB = io_wdataB;
  assign io_rdataB = mem_spinal_port1;

endmodule

module EmmcInit (
  input  wire          io_initStart,
  output wire          io_initDone,
  output wire          io_initError,
  output wire [3:0]    io_initStateDbg,
  output wire          io_cmdStart,
  output wire [5:0]    io_cmdIndex,
  output wire [31:0]   io_cmdArgument,
  output wire          io_respTypeLong,
  output wire          io_respExpected,
  input  wire          io_cmdDone,
  input  wire          io_cmdTimeout,
  input  wire          io_cmdCrcErr,
  input  wire [31:0]   io_respStatus,
  input  wire [127:0]  io_respData,
  output wire [127:0]  io_cidReg,
  output wire [127:0]  io_csdReg,
  output wire [15:0]   io_rcaReg,
  output wire          io_infoValid,
  output wire          io_useFastClk,
  output wire          io_emmcRstnOut,
  output wire [7:0]    io_dbgRetryCnt,
  input  wire          clk,
  input  wire          resetn
);

  wire       [3:0]    SI_IDLE;
  wire       [3:0]    SI_RESET_LOW;
  wire       [3:0]    SI_RESET_HIGH;
  wire       [3:0]    SI_CMD0;
  wire       [3:0]    SI_CMD1;
  wire       [3:0]    SI_CMD1_WAIT;
  wire       [3:0]    SI_CMD2;
  wire       [3:0]    SI_CMD3;
  wire       [3:0]    SI_CMD9;
  wire       [3:0]    SI_CMD7;
  wire       [3:0]    SI_CMD16;
  wire       [3:0]    SI_DONE;
  wire       [3:0]    SI_ERROR;
  wire       [3:0]    SI_WAIT_CMD;
  wire       [3:0]    SI_CMD7_WAIT;
  reg        [3:0]    state;
  reg        [3:0]    nextState;
  reg        [23:0]   waitCnt;
  reg                 waitCntZero;
  reg        [15:0]   retryCnt;
  wire                waitingCmd;
  reg                 isSectorMode;
  reg                 initDoneR;
  reg                 initErrorR;
  reg                 initStartR;
  reg                 cmdStartR;
  reg        [5:0]    cmdIndexR;
  reg        [31:0]   cmdArgumentR;
  reg                 respTypeLongR;
  reg                 respExpectedR;
  reg        [127:0]  cidRegR;
  reg        [127:0]  csdRegR;
  wire       [15:0]   rcaRegR;
  reg                 infoValidR;
  reg                 useFastClkR;
  reg                 emmcRstnOutR;
  wire                when_EmmcInit_l100;
  wire                when_EmmcInit_l145;
  wire                when_EmmcInit_l150;
  wire                when_EmmcInit_l210;
  wire                when_EmmcInit_l212;
  wire                when_EmmcInit_l220;
  wire                when_EmmcInit_l111;
  wire                when_EmmcInit_l120;
  wire                when_EmmcInit_l126;
  wire                when_EmmcInit_l136;
  wire                when_EmmcInit_l144;
  wire                when_EmmcInit_l157;
  wire                when_EmmcInit_l165;
  wire                when_EmmcInit_l174;
  wire                when_EmmcInit_l182;
  wire                when_EmmcInit_l193;
  wire                when_EmmcInit_l199;
  wire                when_EmmcInit_l207;
  wire                when_EmmcInit_l226;
  wire                when_EmmcInit_l231;

  assign SI_IDLE = 4'b0000;
  assign SI_RESET_LOW = 4'b0001;
  assign SI_RESET_HIGH = 4'b0010;
  assign SI_CMD0 = 4'b0011;
  assign SI_CMD1 = 4'b0100;
  assign SI_CMD1_WAIT = 4'b0101;
  assign SI_CMD2 = 4'b0110;
  assign SI_CMD3 = 4'b0111;
  assign SI_CMD9 = 4'b1000;
  assign SI_CMD7 = 4'b1001;
  assign SI_CMD16 = 4'b1011;
  assign SI_DONE = 4'b1100;
  assign SI_ERROR = 4'b1101;
  assign SI_WAIT_CMD = 4'b1110;
  assign SI_CMD7_WAIT = 4'b1111;
  assign waitingCmd = 1'b0;
  assign rcaRegR = 16'h0001;
  assign io_initDone = initDoneR;
  assign io_initError = initErrorR;
  assign io_initStateDbg = state;
  assign io_cmdStart = cmdStartR;
  assign io_cmdIndex = cmdIndexR;
  assign io_cmdArgument = cmdArgumentR;
  assign io_respTypeLong = respTypeLongR;
  assign io_respExpected = respExpectedR;
  assign io_cidReg = cidRegR;
  assign io_csdReg = csdRegR;
  assign io_rcaReg = rcaRegR;
  assign io_infoValid = infoValidR;
  assign io_useFastClk = useFastClkR;
  assign io_emmcRstnOut = emmcRstnOutR;
  assign io_dbgRetryCnt = ((16'h00ff < retryCnt) ? 8'hff : retryCnt[7 : 0]);
  assign when_EmmcInit_l100 = (state == SI_IDLE);
  assign when_EmmcInit_l145 = io_respStatus[31];
  assign when_EmmcInit_l150 = (16'h0578 <= retryCnt);
  assign when_EmmcInit_l210 = (nextState == SI_CMD1_WAIT);
  assign when_EmmcInit_l212 = (16'h0578 <= retryCnt);
  assign when_EmmcInit_l220 = (io_cmdCrcErr && (nextState != SI_CMD1_WAIT));
  assign when_EmmcInit_l111 = (state == SI_RESET_LOW);
  assign when_EmmcInit_l120 = (state == SI_RESET_HIGH);
  assign when_EmmcInit_l126 = (state == SI_CMD0);
  assign when_EmmcInit_l136 = (state == SI_CMD1);
  assign when_EmmcInit_l144 = (state == SI_CMD1_WAIT);
  assign when_EmmcInit_l157 = (state == SI_CMD2);
  assign when_EmmcInit_l165 = (state == SI_CMD3);
  assign when_EmmcInit_l174 = (state == SI_CMD9);
  assign when_EmmcInit_l182 = (state == SI_CMD7);
  assign when_EmmcInit_l193 = (state == SI_CMD7_WAIT);
  assign when_EmmcInit_l199 = (state == SI_CMD16);
  assign when_EmmcInit_l207 = (state == SI_WAIT_CMD);
  assign when_EmmcInit_l226 = (state == SI_DONE);
  assign when_EmmcInit_l231 = (state == SI_ERROR);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      state <= 4'b0000;
      nextState <= 4'b0000;
      waitCnt <= 24'h0;
      waitCntZero <= 1'b1;
      retryCnt <= 16'h0;
      isSectorMode <= 1'b0;
      initDoneR <= 1'b0;
      initErrorR <= 1'b0;
      initStartR <= 1'b0;
      cmdStartR <= 1'b0;
      cmdIndexR <= 6'h0;
      cmdArgumentR <= 32'h0;
      respTypeLongR <= 1'b0;
      respExpectedR <= 1'b0;
      cidRegR <= 128'h0;
      csdRegR <= 128'h0;
      infoValidR <= 1'b0;
      useFastClkR <= 1'b0;
      emmcRstnOutR <= 1'b0;
    end else begin
      cmdStartR <= 1'b0;
      initStartR <= io_initStart;
      if(when_EmmcInit_l100) begin
        initDoneR <= 1'b0;
        initErrorR <= 1'b0;
        if(initStartR) begin
          infoValidR <= 1'b0;
          useFastClkR <= 1'b0;
          emmcRstnOutR <= 1'b0;
          waitCnt <= 24'h00ea60;
          waitCntZero <= 1'b0;
          state <= SI_RESET_LOW;
        end
      end else begin
        if(when_EmmcInit_l111) begin
          waitCnt <= (waitCnt - 24'h000001);
          waitCntZero <= (waitCnt == 24'h000001);
          if(waitCntZero) begin
            emmcRstnOutR <= 1'b1;
            waitCnt <= 24'h2dc6c0;
            waitCntZero <= 1'b0;
            state <= SI_RESET_HIGH;
          end
        end else begin
          if(when_EmmcInit_l120) begin
            waitCnt <= (waitCnt - 24'h000001);
            waitCntZero <= (waitCnt == 24'h000001);
            if(waitCntZero) begin
              state <= SI_CMD0;
            end
          end else begin
            if(when_EmmcInit_l126) begin
              cmdIndexR <= 6'h0;
              cmdArgumentR <= 32'h0;
              respTypeLongR <= 1'b0;
              respExpectedR <= 1'b0;
              cmdStartR <= 1'b1;
              nextState <= SI_CMD1;
              retryCnt <= 16'h0;
              waitCnt <= 24'h0;
              state <= SI_WAIT_CMD;
            end else begin
              if(when_EmmcInit_l136) begin
                cmdIndexR <= 6'h01;
                cmdArgumentR <= 32'h40ff8080;
                respTypeLongR <= 1'b0;
                respExpectedR <= 1'b1;
                cmdStartR <= 1'b1;
                nextState <= SI_CMD1_WAIT;
                state <= SI_WAIT_CMD;
              end else begin
                if(when_EmmcInit_l144) begin
                  if(when_EmmcInit_l145) begin
                    isSectorMode <= io_respStatus[30];
                    state <= SI_CMD2;
                  end else begin
                    retryCnt <= (retryCnt + 16'h0001);
                    if(when_EmmcInit_l150) begin
                      state <= SI_ERROR;
                    end else begin
                      waitCnt <= 24'h0;
                      state <= SI_CMD1;
                    end
                  end
                end else begin
                  if(when_EmmcInit_l157) begin
                    cmdIndexR <= 6'h02;
                    cmdArgumentR <= 32'h0;
                    respTypeLongR <= 1'b1;
                    respExpectedR <= 1'b1;
                    cmdStartR <= 1'b1;
                    nextState <= SI_CMD3;
                    state <= SI_WAIT_CMD;
                  end else begin
                    if(when_EmmcInit_l165) begin
                      cidRegR <= io_respData;
                      cmdIndexR <= 6'h03;
                      cmdArgumentR <= {rcaRegR,16'h0};
                      respTypeLongR <= 1'b0;
                      respExpectedR <= 1'b1;
                      cmdStartR <= 1'b1;
                      nextState <= SI_CMD9;
                      state <= SI_WAIT_CMD;
                    end else begin
                      if(when_EmmcInit_l174) begin
                        cmdIndexR <= 6'h09;
                        cmdArgumentR <= {rcaRegR,16'h0};
                        respTypeLongR <= 1'b1;
                        respExpectedR <= 1'b1;
                        cmdStartR <= 1'b1;
                        nextState <= SI_CMD7;
                        state <= SI_WAIT_CMD;
                      end else begin
                        if(when_EmmcInit_l182) begin
                          csdRegR <= io_respData;
                          cmdIndexR <= 6'h07;
                          cmdArgumentR <= {rcaRegR,16'h0};
                          respTypeLongR <= 1'b0;
                          respExpectedR <= 1'b1;
                          cmdStartR <= 1'b1;
                          waitCnt <= 24'h00ea60;
                          waitCntZero <= 1'b0;
                          nextState <= SI_CMD7_WAIT;
                          state <= SI_WAIT_CMD;
                        end else begin
                          if(when_EmmcInit_l193) begin
                            waitCnt <= (waitCnt - 24'h000001);
                            waitCntZero <= (waitCnt == 24'h000001);
                            if(waitCntZero) begin
                              state <= (isSectorMode ? SI_DONE : SI_CMD16);
                            end
                          end else begin
                            if(when_EmmcInit_l199) begin
                              cmdIndexR <= 6'h10;
                              cmdArgumentR <= 32'h00000200;
                              respTypeLongR <= 1'b0;
                              respExpectedR <= 1'b1;
                              cmdStartR <= 1'b1;
                              nextState <= SI_DONE;
                              state <= SI_WAIT_CMD;
                            end else begin
                              if(when_EmmcInit_l207) begin
                                if(io_cmdDone) begin
                                  if(io_cmdTimeout) begin
                                    if(when_EmmcInit_l210) begin
                                      retryCnt <= (retryCnt + 16'h0001);
                                      if(when_EmmcInit_l212) begin
                                        state <= SI_ERROR;
                                      end else begin
                                        state <= SI_CMD1;
                                      end
                                    end else begin
                                      state <= SI_ERROR;
                                    end
                                  end else begin
                                    if(when_EmmcInit_l220) begin
                                      state <= SI_ERROR;
                                    end else begin
                                      state <= nextState;
                                    end
                                  end
                                end
                              end else begin
                                if(when_EmmcInit_l226) begin
                                  infoValidR <= 1'b1;
                                  initDoneR <= 1'b1;
                                  useFastClkR <= 1'b1;
                                  state <= SI_IDLE;
                                end else begin
                                  if(when_EmmcInit_l231) begin
                                    initErrorR <= 1'b1;
                                    state <= SI_IDLE;
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


endmodule

module EmmcDat (
  input  wire          io_clkEn,
  input  wire          io_rdStart,
  output wire          io_rdDone,
  output wire          io_rdCrcErr,
  input  wire          io_wrStart,
  output wire          io_wrDone,
  output wire          io_wrCrcErr,
  output wire [7:0]    io_bufWrData,
  output wire [8:0]    io_bufWrAddr,
  output wire          io_bufWrEn,
  output wire [8:0]    io_bufRdAddr,
  input  wire [7:0]    io_bufRdData,
  output wire [3:0]    io_datOut,
  output wire          io_datOe,
  input  wire [3:0]    io_datIn,
  input  wire          io_busWidth4,
  output wire [3:0]    io_dbgState,
  input  wire          clk,
  input  wire          resetn
);

  wire                rdCrcs_0_io_bitIn;
  wire                rdCrcs_1_io_bitIn;
  wire                rdCrcs_2_io_bitIn;
  wire                rdCrcs_3_io_bitIn;
  wire                wrCrcs_0_io_bitIn;
  wire                wrCrcs_1_io_bitIn;
  wire                wrCrcs_2_io_bitIn;
  wire                wrCrcs_3_io_bitIn;
  wire       [15:0]   rdCrcs_0_io_crcOut;
  wire       [15:0]   rdCrcs_1_io_crcOut;
  wire       [15:0]   rdCrcs_2_io_crcOut;
  wire       [15:0]   rdCrcs_3_io_crcOut;
  wire       [15:0]   wrCrcs_0_io_crcOut;
  wire       [15:0]   wrCrcs_1_io_crcOut;
  wire       [15:0]   wrCrcs_2_io_crcOut;
  wire       [15:0]   wrCrcs_3_io_crcOut;
  wire       [3:0]    S_IDLE;
  wire       [3:0]    S_RD_WAIT_START;
  wire       [3:0]    S_RD_DATA;
  wire       [3:0]    S_RD_CRC;
  wire       [3:0]    S_RD_END;
  wire       [3:0]    S_WR_PREFETCH;
  wire       [3:0]    S_WR_START;
  wire       [3:0]    S_WR_DATA;
  wire       [3:0]    S_WR_CRC;
  wire       [3:0]    S_WR_END;
  wire       [3:0]    S_WR_CRC_STAT;
  wire       [3:0]    S_WR_BUSY;
  wire       [3:0]    S_WR_CRC_WAIT;
  wire       [3:0]    S_WR_PREFETCH2;
  reg        [3:0]    state;
  reg        [12:0]   bitCnt;
  reg        [15:0]   timeoutCnt;
  reg                 timeoutFlag;
  reg        [7:0]    byteAcc;
  reg        [2:0]    bitInByte;
  reg                 byteComplete;
  reg        [7:0]    wrByteReg;
  reg        [2:0]    wrBitIdx;
  reg                 rdDoneR;
  reg                 rdCrcErrR;
  reg                 wrDoneR;
  reg                 wrCrcErrR;
  reg        [7:0]    bufWrDataR;
  reg        [8:0]    bufWrAddrR;
  reg                 bufWrEnR;
  reg        [8:0]    bufRdAddrR;
  reg        [3:0]    datOutR;
  reg                 datOeR;
  reg                 nibblePhase;
  reg                 rdCrcClear;
  reg                 rdCrcEn;
  reg        [15:0]   crcRecvArr_0;
  reg        [15:0]   crcRecvArr_1;
  reg        [15:0]   crcRecvArr_2;
  reg        [15:0]   crcRecvArr_3;
  reg        [15:0]   crcRecv;
  reg                 wrCrcClear;
  reg                 wrCrcEn;
  reg        [3:0]    wrCrcBit;
  reg        [15:0]   wrCrcShiftArr_0;
  reg        [15:0]   wrCrcShiftArr_1;
  reg        [15:0]   wrCrcShiftArr_2;
  reg        [15:0]   wrCrcShiftArr_3;
  reg        [15:0]   wrCrcShift;
  reg        [2:0]    crcStatusReg;
  reg        [2:0]    crcStatusCnt;
  wire                when_EmmcDat_l141;
  wire                when_EmmcDat_l159;
  wire                when_EmmcDat_l168;
  wire                when_EmmcDat_l185;
  wire                when_EmmcDat_l206;
  wire                when_EmmcDat_l223;
  wire                when_EmmcDat_l243;
  wire                when_EmmcDat_l253;
  wire                when_EmmcDat_l257;
  wire                when_EmmcDat_l289;
  wire                when_EmmcDat_l306;
  wire                when_EmmcDat_l318;
  wire                when_EmmcDat_l328;
  wire                when_EmmcDat_l336;
  wire                when_EmmcDat_l366;
  wire                when_EmmcDat_l385;
  wire                when_EmmcDat_l391;
  wire                when_EmmcDat_l400;
  wire                when_EmmcDat_l387;
  wire                when_EmmcDat_l390;
  wire                when_EmmcDat_l414;
  wire                when_EmmcDat_l421;
  wire                when_EmmcDat_l416;
  wire                when_EmmcDat_l156;
  wire                when_EmmcDat_l179;
  wire                when_EmmcDat_l231;
  wire                when_EmmcDat_l248;
  wire                when_EmmcDat_l265;
  wire                when_EmmcDat_l268;
  wire                when_EmmcDat_l273;
  wire                when_EmmcDat_l283;
  wire                when_EmmcDat_l335;
  wire                when_EmmcDat_l348;
  wire                when_EmmcDat_l371;
  wire                when_EmmcDat_l382;
  wire                when_EmmcDat_l411;

  Crc16 rdCrcs_0 (
    .io_clear  (rdCrcClear              ), //i
    .io_enable (rdCrcEn                 ), //i
    .io_bitIn  (rdCrcs_0_io_bitIn       ), //i
    .io_crcOut (rdCrcs_0_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 rdCrcs_1 (
    .io_clear  (rdCrcClear              ), //i
    .io_enable (rdCrcEn                 ), //i
    .io_bitIn  (rdCrcs_1_io_bitIn       ), //i
    .io_crcOut (rdCrcs_1_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 rdCrcs_2 (
    .io_clear  (rdCrcClear              ), //i
    .io_enable (rdCrcEn                 ), //i
    .io_bitIn  (rdCrcs_2_io_bitIn       ), //i
    .io_crcOut (rdCrcs_2_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 rdCrcs_3 (
    .io_clear  (rdCrcClear              ), //i
    .io_enable (rdCrcEn                 ), //i
    .io_bitIn  (rdCrcs_3_io_bitIn       ), //i
    .io_crcOut (rdCrcs_3_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 wrCrcs_0 (
    .io_clear  (wrCrcClear              ), //i
    .io_enable (wrCrcEn                 ), //i
    .io_bitIn  (wrCrcs_0_io_bitIn       ), //i
    .io_crcOut (wrCrcs_0_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 wrCrcs_1 (
    .io_clear  (wrCrcClear              ), //i
    .io_enable (wrCrcEn                 ), //i
    .io_bitIn  (wrCrcs_1_io_bitIn       ), //i
    .io_crcOut (wrCrcs_1_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 wrCrcs_2 (
    .io_clear  (wrCrcClear              ), //i
    .io_enable (wrCrcEn                 ), //i
    .io_bitIn  (wrCrcs_2_io_bitIn       ), //i
    .io_crcOut (wrCrcs_2_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 wrCrcs_3 (
    .io_clear  (wrCrcClear              ), //i
    .io_enable (wrCrcEn                 ), //i
    .io_bitIn  (wrCrcs_3_io_bitIn       ), //i
    .io_crcOut (wrCrcs_3_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  assign S_IDLE = 4'b0000;
  assign S_RD_WAIT_START = 4'b0001;
  assign S_RD_DATA = 4'b0010;
  assign S_RD_CRC = 4'b0011;
  assign S_RD_END = 4'b0100;
  assign S_WR_PREFETCH = 4'b0101;
  assign S_WR_START = 4'b0110;
  assign S_WR_DATA = 4'b0111;
  assign S_WR_CRC = 4'b1000;
  assign S_WR_END = 4'b1001;
  assign S_WR_CRC_STAT = 4'b1010;
  assign S_WR_BUSY = 4'b1011;
  assign S_WR_CRC_WAIT = 4'b1100;
  assign S_WR_PREFETCH2 = 4'b1101;
  assign io_dbgState = state;
  assign io_rdDone = rdDoneR;
  assign io_rdCrcErr = rdCrcErrR;
  assign io_wrDone = wrDoneR;
  assign io_wrCrcErr = wrCrcErrR;
  assign io_bufWrData = bufWrDataR;
  assign io_bufWrAddr = bufWrAddrR;
  assign io_bufWrEn = bufWrEnR;
  assign io_bufRdAddr = bufRdAddrR;
  assign io_datOut = datOutR;
  assign io_datOe = datOeR;
  assign rdCrcs_0_io_bitIn = io_datIn[0];
  assign rdCrcs_1_io_bitIn = io_datIn[1];
  assign rdCrcs_2_io_bitIn = io_datIn[2];
  assign rdCrcs_3_io_bitIn = io_datIn[3];
  assign wrCrcs_0_io_bitIn = wrCrcBit[0];
  assign wrCrcs_1_io_bitIn = wrCrcBit[1];
  assign wrCrcs_2_io_bitIn = wrCrcBit[2];
  assign wrCrcs_3_io_bitIn = wrCrcBit[3];
  assign when_EmmcDat_l141 = (state == S_IDLE);
  assign when_EmmcDat_l159 = (! io_datIn[0]);
  assign when_EmmcDat_l168 = (timeoutCnt == 16'hfffe);
  assign when_EmmcDat_l185 = (! nibblePhase);
  assign when_EmmcDat_l206 = (bitCnt == 13'h03ff);
  assign when_EmmcDat_l223 = (bitCnt == 13'h0fff);
  assign when_EmmcDat_l243 = (bitCnt == 13'h000f);
  assign when_EmmcDat_l253 = ((((crcRecvArr_0 != rdCrcs_0_io_crcOut) || (crcRecvArr_1 != rdCrcs_1_io_crcOut)) || (crcRecvArr_2 != rdCrcs_2_io_crcOut)) || (crcRecvArr_3 != rdCrcs_3_io_crcOut));
  assign when_EmmcDat_l257 = (crcRecv != rdCrcs_0_io_crcOut);
  assign when_EmmcDat_l289 = (! nibblePhase);
  assign when_EmmcDat_l306 = (bitCnt == 13'h03ff);
  assign when_EmmcDat_l318 = (wrBitIdx == 3'b000);
  assign when_EmmcDat_l328 = (bitCnt == 13'h0fff);
  assign when_EmmcDat_l336 = bitCnt[0];
  assign when_EmmcDat_l366 = (bitCnt == 13'h000f);
  assign when_EmmcDat_l385 = ((! io_datIn[0]) && (crcStatusCnt == 3'b000));
  assign when_EmmcDat_l391 = (crcStatusReg == 3'b010);
  assign when_EmmcDat_l400 = (timeoutCnt == 16'hfffe);
  assign when_EmmcDat_l387 = ((3'b001 <= crcStatusCnt) && (crcStatusCnt <= 3'b011));
  assign when_EmmcDat_l390 = (3'b011 < crcStatusCnt);
  assign when_EmmcDat_l414 = (crcStatusCnt < 3'b111);
  assign when_EmmcDat_l421 = (timeoutCnt == 16'hfffe);
  assign when_EmmcDat_l416 = io_datIn[0];
  assign when_EmmcDat_l156 = (state == S_RD_WAIT_START);
  assign when_EmmcDat_l179 = (state == S_RD_DATA);
  assign when_EmmcDat_l231 = (state == S_RD_CRC);
  assign when_EmmcDat_l248 = (state == S_RD_END);
  assign when_EmmcDat_l265 = (state == S_WR_PREFETCH);
  assign when_EmmcDat_l268 = (state == S_WR_PREFETCH2);
  assign when_EmmcDat_l273 = (state == S_WR_START);
  assign when_EmmcDat_l283 = (state == S_WR_DATA);
  assign when_EmmcDat_l335 = (state == S_WR_CRC_WAIT);
  assign when_EmmcDat_l348 = (state == S_WR_CRC);
  assign when_EmmcDat_l371 = (state == S_WR_END);
  assign when_EmmcDat_l382 = (state == S_WR_CRC_STAT);
  assign when_EmmcDat_l411 = (state == S_WR_BUSY);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      state <= 4'b0000;
      bitCnt <= 13'h0;
      timeoutCnt <= 16'h0;
      timeoutFlag <= 1'b0;
      byteAcc <= 8'h0;
      bitInByte <= 3'b000;
      byteComplete <= 1'b0;
      wrByteReg <= 8'h0;
      wrBitIdx <= 3'b000;
      rdDoneR <= 1'b0;
      rdCrcErrR <= 1'b0;
      wrDoneR <= 1'b0;
      wrCrcErrR <= 1'b0;
      bufWrDataR <= 8'h0;
      bufWrAddrR <= 9'h0;
      bufWrEnR <= 1'b0;
      bufRdAddrR <= 9'h0;
      datOutR <= 4'b1111;
      datOeR <= 1'b0;
      nibblePhase <= 1'b0;
      rdCrcClear <= 1'b1;
      rdCrcEn <= 1'b0;
      crcRecvArr_0 <= 16'h0;
      crcRecvArr_1 <= 16'h0;
      crcRecvArr_2 <= 16'h0;
      crcRecvArr_3 <= 16'h0;
      crcRecv <= 16'h0;
      wrCrcClear <= 1'b1;
      wrCrcEn <= 1'b0;
      wrCrcBit <= 4'b1111;
      wrCrcShiftArr_0 <= 16'h0;
      wrCrcShiftArr_1 <= 16'h0;
      wrCrcShiftArr_2 <= 16'h0;
      wrCrcShiftArr_3 <= 16'h0;
      wrCrcShift <= 16'h0;
      crcStatusReg <= 3'b000;
      crcStatusCnt <= 3'b000;
    end else begin
      rdDoneR <= 1'b0;
      rdCrcErrR <= 1'b0;
      wrDoneR <= 1'b0;
      wrCrcErrR <= 1'b0;
      bufWrEnR <= 1'b0;
      rdCrcClear <= 1'b0;
      rdCrcEn <= 1'b0;
      wrCrcClear <= 1'b0;
      wrCrcEn <= 1'b0;
      if(when_EmmcDat_l141) begin
        datOeR <= 1'b0;
        datOutR <= 4'b1111;
        if(io_rdStart) begin
          rdCrcClear <= 1'b1;
          timeoutCnt <= 16'h0;
          timeoutFlag <= 1'b0;
          state <= S_RD_WAIT_START;
        end else begin
          if(io_wrStart) begin
            wrCrcClear <= 1'b1;
            bufRdAddrR <= 9'h0;
            bitCnt <= 13'h0;
            state <= S_WR_PREFETCH;
          end
        end
      end else begin
        if(when_EmmcDat_l156) begin
          if(io_clkEn) begin
            if(when_EmmcDat_l159) begin
              bitCnt <= 13'h0;
              bitInByte <= 3'b000;
              byteComplete <= 1'b0;
              bufWrAddrR <= 9'h1ff;
              nibblePhase <= 1'b0;
              state <= S_RD_DATA;
            end else begin
              timeoutCnt <= (timeoutCnt + 16'h0001);
              if(when_EmmcDat_l168) begin
                timeoutFlag <= 1'b1;
              end
              if(timeoutFlag) begin
                rdCrcErrR <= 1'b1;
                rdDoneR <= 1'b1;
                state <= S_IDLE;
              end
            end
          end
        end else begin
          if(when_EmmcDat_l179) begin
            if(io_clkEn) begin
              rdCrcEn <= 1'b1;
              if(io_busWidth4) begin
                if(when_EmmcDat_l185) begin
                  byteAcc[7] <= io_datIn[3];
                  byteAcc[6] <= io_datIn[2];
                  byteAcc[5] <= io_datIn[1];
                  byteAcc[4] <= io_datIn[0];
                  nibblePhase <= 1'b1;
                end else begin
                  byteAcc[3] <= io_datIn[3];
                  byteAcc[2] <= io_datIn[2];
                  byteAcc[1] <= io_datIn[1];
                  byteAcc[0] <= io_datIn[0];
                  nibblePhase <= 1'b0;
                  byteComplete <= 1'b1;
                  bufWrDataR <= {byteAcc[7 : 4],io_datIn};
                  bufWrEnR <= 1'b1;
                  bufWrAddrR <= (bufWrAddrR + 9'h001);
                end
                bitCnt <= (bitCnt + 13'h0001);
                if(when_EmmcDat_l206) begin
                  bitCnt <= 13'h0;
                  crcRecvArr_0 <= 16'h0;
                  crcRecvArr_1 <= 16'h0;
                  crcRecvArr_2 <= 16'h0;
                  crcRecvArr_3 <= 16'h0;
                  state <= S_RD_CRC;
                end
              end else begin
                byteAcc <= {byteAcc[6 : 0],io_datIn[0]};
                bitInByte <= (bitInByte + 3'b001);
                byteComplete <= (bitInByte == 3'b110);
                bufWrDataR <= {byteAcc[6 : 0],io_datIn[0]};
                bufWrEnR <= byteComplete;
                if(byteComplete) begin
                  bufWrAddrR <= (bufWrAddrR + 9'h001);
                end
                bitCnt <= (bitCnt + 13'h0001);
                if(when_EmmcDat_l223) begin
                  bitCnt <= 13'h0;
                  crcRecv <= 16'h0;
                  state <= S_RD_CRC;
                end
              end
            end
          end else begin
            if(when_EmmcDat_l231) begin
              if(io_clkEn) begin
                if(io_busWidth4) begin
                  crcRecvArr_0 <= {crcRecvArr_0[14 : 0],io_datIn[0]};
                  crcRecvArr_1 <= {crcRecvArr_1[14 : 0],io_datIn[1]};
                  crcRecvArr_2 <= {crcRecvArr_2[14 : 0],io_datIn[2]};
                  crcRecvArr_3 <= {crcRecvArr_3[14 : 0],io_datIn[3]};
                end else begin
                  crcRecv <= {crcRecv[14 : 0],io_datIn[0]};
                end
                bitCnt <= (bitCnt + 13'h0001);
                if(when_EmmcDat_l243) begin
                  state <= S_RD_END;
                end
              end
            end else begin
              if(when_EmmcDat_l248) begin
                if(io_clkEn) begin
                  if(io_busWidth4) begin
                    if(when_EmmcDat_l253) begin
                      rdCrcErrR <= 1'b1;
                    end
                  end else begin
                    if(when_EmmcDat_l257) begin
                      rdCrcErrR <= 1'b1;
                    end
                  end
                  rdDoneR <= 1'b1;
                  state <= S_IDLE;
                end
              end else begin
                if(when_EmmcDat_l265) begin
                  state <= S_WR_PREFETCH2;
                end else begin
                  if(when_EmmcDat_l268) begin
                    wrByteReg <= io_bufRdData;
                    bufRdAddrR <= 9'h001;
                    state <= S_WR_START;
                  end else begin
                    if(when_EmmcDat_l273) begin
                      if(io_clkEn) begin
                        wrBitIdx <= 3'b111;
                        datOeR <= 1'b1;
                        datOutR <= 4'b0000;
                        bitCnt <= 13'h0;
                        nibblePhase <= 1'b0;
                        state <= S_WR_DATA;
                      end
                    end else begin
                      if(when_EmmcDat_l283) begin
                        if(io_clkEn) begin
                          datOeR <= 1'b1;
                          if(io_busWidth4) begin
                            if(when_EmmcDat_l289) begin
                              datOutR <= {{{wrByteReg[7],wrByteReg[6]},wrByteReg[5]},wrByteReg[4]};
                              wrCrcBit <= {{{wrByteReg[7],wrByteReg[6]},wrByteReg[5]},wrByteReg[4]};
                              wrCrcEn <= 1'b1;
                              nibblePhase <= 1'b1;
                            end else begin
                              datOutR <= {{{wrByteReg[3],wrByteReg[2]},wrByteReg[1]},wrByteReg[0]};
                              wrCrcBit <= {{{wrByteReg[3],wrByteReg[2]},wrByteReg[1]},wrByteReg[0]};
                              wrCrcEn <= 1'b1;
                              nibblePhase <= 1'b0;
                              wrByteReg <= io_bufRdData;
                              bufRdAddrR <= (bufRdAddrR + 9'h001);
                            end
                            bitCnt <= (bitCnt + 13'h0001);
                            if(when_EmmcDat_l306) begin
                              bitCnt <= 13'h0;
                              state <= S_WR_CRC_WAIT;
                            end
                          end else begin
                            datOutR[0] <= wrByteReg[7];
                            datOutR[3 : 1] <= 3'b111;
                            wrCrcBit[0] <= wrByteReg[7];
                            wrCrcBit[3 : 1] <= 3'b111;
                            wrCrcEn <= 1'b1;
                            if(when_EmmcDat_l318) begin
                              wrByteReg <= io_bufRdData;
                              bufRdAddrR <= (bufRdAddrR + 9'h001);
                              wrBitIdx <= 3'b111;
                            end else begin
                              wrByteReg <= {wrByteReg[6 : 0],1'b0};
                              wrBitIdx <= (wrBitIdx - 3'b001);
                            end
                            bitCnt <= (bitCnt + 13'h0001);
                            if(when_EmmcDat_l328) begin
                              bitCnt <= 13'h0;
                              state <= S_WR_CRC_WAIT;
                            end
                          end
                        end
                      end else begin
                        if(when_EmmcDat_l335) begin
                          if(when_EmmcDat_l336) begin
                            if(io_busWidth4) begin
                              wrCrcShiftArr_0 <= wrCrcs_0_io_crcOut;
                              wrCrcShiftArr_1 <= wrCrcs_1_io_crcOut;
                              wrCrcShiftArr_2 <= wrCrcs_2_io_crcOut;
                              wrCrcShiftArr_3 <= wrCrcs_3_io_crcOut;
                            end else begin
                              wrCrcShift <= wrCrcs_0_io_crcOut;
                            end
                            bitCnt <= 13'h0;
                            state <= S_WR_CRC;
                          end else begin
                            bitCnt <= (bitCnt + 13'h0001);
                          end
                        end else begin
                          if(when_EmmcDat_l348) begin
                            if(io_clkEn) begin
                              datOeR <= 1'b1;
                              if(io_busWidth4) begin
                                datOutR[0] <= wrCrcShiftArr_0[15];
                                wrCrcShiftArr_0 <= {wrCrcShiftArr_0[14 : 0],1'b0};
                                datOutR[1] <= wrCrcShiftArr_1[15];
                                wrCrcShiftArr_1 <= {wrCrcShiftArr_1[14 : 0],1'b0};
                                datOutR[2] <= wrCrcShiftArr_2[15];
                                wrCrcShiftArr_2 <= {wrCrcShiftArr_2[14 : 0],1'b0};
                                datOutR[3] <= wrCrcShiftArr_3[15];
                                wrCrcShiftArr_3 <= {wrCrcShiftArr_3[14 : 0],1'b0};
                              end else begin
                                datOutR[0] <= wrCrcShift[15];
                                datOutR[3 : 1] <= 3'b111;
                                wrCrcShift <= {wrCrcShift[14 : 0],1'b0};
                              end
                              bitCnt <= (bitCnt + 13'h0001);
                              if(when_EmmcDat_l366) begin
                                state <= S_WR_END;
                              end
                            end
                          end else begin
                            if(when_EmmcDat_l371) begin
                              if(io_clkEn) begin
                                datOutR <= 4'b1111;
                                datOeR <= 1'b0;
                                crcStatusCnt <= 3'b000;
                                crcStatusReg <= 3'b000;
                                timeoutCnt <= 16'h0;
                                timeoutFlag <= 1'b0;
                                state <= S_WR_CRC_STAT;
                              end
                            end else begin
                              if(when_EmmcDat_l382) begin
                                if(io_clkEn) begin
                                  if(when_EmmcDat_l385) begin
                                    crcStatusCnt <= 3'b001;
                                  end else begin
                                    if(when_EmmcDat_l387) begin
                                      crcStatusReg <= {crcStatusReg[1 : 0],io_datIn[0]};
                                      crcStatusCnt <= (crcStatusCnt + 3'b001);
                                    end else begin
                                      if(when_EmmcDat_l390) begin
                                        if(when_EmmcDat_l391) begin
                                          state <= S_WR_BUSY;
                                        end else begin
                                          wrCrcErrR <= 1'b1;
                                          wrDoneR <= 1'b1;
                                          state <= S_IDLE;
                                        end
                                      end else begin
                                        timeoutCnt <= (timeoutCnt + 16'h0001);
                                        if(when_EmmcDat_l400) begin
                                          timeoutFlag <= 1'b1;
                                        end
                                        if(timeoutFlag) begin
                                          wrCrcErrR <= 1'b1;
                                          wrDoneR <= 1'b1;
                                          state <= S_IDLE;
                                        end
                                      end
                                    end
                                  end
                                end
                              end else begin
                                if(when_EmmcDat_l411) begin
                                  if(io_clkEn) begin
                                    if(when_EmmcDat_l414) begin
                                      crcStatusCnt <= (crcStatusCnt + 3'b001);
                                    end else begin
                                      if(when_EmmcDat_l416) begin
                                        wrDoneR <= 1'b1;
                                        state <= S_IDLE;
                                      end else begin
                                        timeoutCnt <= (timeoutCnt + 16'h0001);
                                        if(when_EmmcDat_l421) begin
                                          timeoutFlag <= 1'b1;
                                        end
                                        if(timeoutFlag) begin
                                          wrCrcErrR <= 1'b1;
                                          wrDoneR <= 1'b1;
                                          state <= S_IDLE;
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
      end
    end
  end


endmodule

module EmmcCmd (
  input  wire          io_clkEn,
  input  wire          io_cmdStart,
  input  wire [5:0]    io_cmdIndex,
  input  wire [31:0]   io_cmdArgument,
  input  wire          io_respTypeLong,
  input  wire          io_respExpected,
  output wire          io_cmdDone,
  output wire          io_cmdTimeout,
  output wire          io_cmdCrcErr,
  output wire [31:0]   io_respStatus,
  output wire [127:0]  io_respData,
  output wire          io_cmdOut,
  output wire          io_cmdOe,
  input  wire          io_cmdIn,
  output wire [2:0]    io_dbgState,
  input  wire          clk,
  input  wire          resetn
);

  wire       [6:0]    uCrc7_io_crcOut;
  wire       [2:0]    S_IDLE;
  wire       [2:0]    S_SEND;
  wire       [2:0]    S_WAIT;
  wire       [2:0]    S_RECV;
  wire       [2:0]    S_DONE;
  reg        [2:0]    state;
  reg        [7:0]    bitCnt;
  reg        [47:0]   txShift;
  reg        [135:0]  rxShift;
  reg        [15:0]   timeoutCnt;
  reg                 cmdTimeoutFlag;
  reg                 respLong;
  reg                 respExp;
  reg        [6:0]    crcShift;
  reg                 sendIsDataPhase;
  reg                 sendLatchCrc;
  reg                 sendIsDone;
  reg                 cmdDoneR;
  reg                 cmdTimeoutR;
  reg                 cmdCrcErrR;
  reg        [31:0]   respStatusR;
  reg        [127:0]  respDataR;
  reg                 cmdOutR;
  reg                 cmdOeR;
  reg                 crcClear;
  reg                 crcEn;
  reg                 crcBit;
  wire                when_EmmcCmd_l84;
  wire                when_EmmcCmd_l87;
  wire                when_EmmcCmd_l115;
  wire                when_EmmcCmd_l144;
  wire                when_EmmcCmd_l151;
  wire                when_EmmcCmd_l166;
  wire                when_EmmcCmd_l167;
  wire                when_EmmcCmd_l173;
  wire                when_EmmcCmd_l175;
  wire                when_EmmcCmd_l180;
  wire                when_EmmcCmd_l182;
  wire                when_EmmcCmd_l103;
  wire                when_EmmcCmd_l142;
  wire                when_EmmcCmd_l161;
  wire                when_EmmcCmd_l179;

  Crc7 uCrc7 (
    .io_clear  (crcClear            ), //i
    .io_enable (crcEn               ), //i
    .io_bitIn  (crcBit              ), //i
    .io_crcOut (uCrc7_io_crcOut[6:0]), //o
    .clk       (clk                 ), //i
    .resetn    (resetn              )  //i
  );
  assign S_IDLE = 3'b000;
  assign S_SEND = 3'b001;
  assign S_WAIT = 3'b010;
  assign S_RECV = 3'b011;
  assign S_DONE = 3'b100;
  assign io_dbgState = state;
  assign io_cmdDone = cmdDoneR;
  assign io_cmdTimeout = cmdTimeoutR;
  assign io_cmdCrcErr = cmdCrcErrR;
  assign io_respStatus = respStatusR;
  assign io_respData = respDataR;
  assign io_cmdOut = cmdOutR;
  assign io_cmdOe = cmdOeR;
  assign when_EmmcCmd_l84 = (state == S_IDLE);
  assign when_EmmcCmd_l87 = (io_cmdStart && (! cmdDoneR));
  assign when_EmmcCmd_l115 = (! sendIsDone);
  assign when_EmmcCmd_l144 = (! io_cmdIn);
  assign when_EmmcCmd_l151 = (timeoutCnt == 16'h03ff);
  assign when_EmmcCmd_l166 = (! respLong);
  assign when_EmmcCmd_l167 = ((8'h01 <= bitCnt) && (bitCnt <= 8'h27));
  assign when_EmmcCmd_l173 = ((! respLong) && (bitCnt == 8'h2f));
  assign when_EmmcCmd_l175 = (respLong && (bitCnt == 8'h87));
  assign when_EmmcCmd_l180 = ((! respLong) && respExp);
  assign when_EmmcCmd_l182 = (uCrc7_io_crcOut != rxShift[7 : 1]);
  assign when_EmmcCmd_l103 = (state == S_SEND);
  assign when_EmmcCmd_l142 = (state == S_WAIT);
  assign when_EmmcCmd_l161 = (state == S_RECV);
  assign when_EmmcCmd_l179 = (state == S_DONE);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      state <= 3'b000;
      bitCnt <= 8'h0;
      txShift <= 48'h0;
      rxShift <= 136'h0;
      timeoutCnt <= 16'h0;
      cmdTimeoutFlag <= 1'b0;
      respLong <= 1'b0;
      respExp <= 1'b0;
      crcShift <= 7'h0;
      sendIsDataPhase <= 1'b0;
      sendLatchCrc <= 1'b0;
      sendIsDone <= 1'b0;
      cmdDoneR <= 1'b0;
      cmdTimeoutR <= 1'b0;
      cmdCrcErrR <= 1'b0;
      respStatusR <= 32'h0;
      respDataR <= 128'h0;
      cmdOutR <= 1'b1;
      cmdOeR <= 1'b0;
      crcClear <= 1'b1;
      crcEn <= 1'b0;
      crcBit <= 1'b0;
    end else begin
      cmdDoneR <= 1'b0;
      cmdTimeoutR <= 1'b0;
      cmdCrcErrR <= 1'b0;
      crcClear <= 1'b0;
      crcEn <= 1'b0;
      if(when_EmmcCmd_l84) begin
        cmdOeR <= 1'b0;
        cmdOutR <= 1'b1;
        if(when_EmmcCmd_l87) begin
          txShift[47] <= 1'b0;
          txShift[46] <= 1'b1;
          txShift[45 : 40] <= io_cmdIndex;
          txShift[39 : 8] <= io_cmdArgument;
          txShift[7 : 1] <= 7'h0;
          txShift[0] <= 1'b1;
          respLong <= io_respTypeLong;
          respExp <= io_respExpected;
          bitCnt <= 8'h0;
          crcClear <= 1'b1;
          sendIsDataPhase <= 1'b1;
          sendLatchCrc <= 1'b0;
          sendIsDone <= 1'b0;
          state <= S_SEND;
        end
      end else begin
        if(when_EmmcCmd_l103) begin
          if(io_clkEn) begin
            cmdOeR <= 1'b1;
            if(sendIsDataPhase) begin
              cmdOutR <= txShift[47];
              txShift <= {txShift[46 : 0],1'b0};
              crcEn <= 1'b1;
              crcBit <= txShift[47];
            end else begin
              if(sendLatchCrc) begin
                cmdOutR <= uCrc7_io_crcOut[6];
                crcShift <= {uCrc7_io_crcOut[5 : 0],1'b0};
              end else begin
                if(when_EmmcCmd_l115) begin
                  cmdOutR <= crcShift[6];
                  crcShift <= {crcShift[5 : 0],1'b0};
                end else begin
                  cmdOutR <= 1'b1;
                end
              end
            end
            bitCnt <= (bitCnt + 8'h01);
            sendIsDataPhase <= (bitCnt < 8'h27);
            sendLatchCrc <= (bitCnt == 8'h27);
            sendIsDone <= (8'h2e <= bitCnt);
            if(sendIsDone) begin
              cmdOeR <= 1'b0;
              cmdOutR <= 1'b1;
              if(respExp) begin
                bitCnt <= 8'h0;
                timeoutCnt <= 16'h0;
                cmdTimeoutFlag <= 1'b0;
                crcClear <= 1'b1;
                state <= S_WAIT;
              end else begin
                state <= S_DONE;
              end
            end
          end
        end else begin
          if(when_EmmcCmd_l142) begin
            if(io_clkEn) begin
              if(when_EmmcCmd_l144) begin
                rxShift <= 136'h0;
                rxShift[135] <= 1'b0;
                bitCnt <= 8'h01;
                state <= S_RECV;
              end else begin
                timeoutCnt <= (timeoutCnt + 16'h0001);
                if(when_EmmcCmd_l151) begin
                  cmdTimeoutFlag <= 1'b1;
                end
                if(cmdTimeoutFlag) begin
                  cmdTimeoutR <= 1'b1;
                  cmdDoneR <= 1'b1;
                  state <= S_IDLE;
                end
              end
            end
          end else begin
            if(when_EmmcCmd_l161) begin
              if(io_clkEn) begin
                rxShift <= {rxShift[134 : 0],io_cmdIn};
                bitCnt <= (bitCnt + 8'h01);
                if(when_EmmcCmd_l166) begin
                  if(when_EmmcCmd_l167) begin
                    crcEn <= 1'b1;
                    crcBit <= io_cmdIn;
                  end
                end
                if(when_EmmcCmd_l173) begin
                  state <= S_DONE;
                end else begin
                  if(when_EmmcCmd_l175) begin
                    state <= S_DONE;
                  end
                end
              end
            end else begin
              if(when_EmmcCmd_l179) begin
                if(when_EmmcCmd_l180) begin
                  respStatusR <= rxShift[39 : 8];
                  if(when_EmmcCmd_l182) begin
                    cmdCrcErrR <= 1'b1;
                  end
                end else begin
                  if(respLong) begin
                    respDataR <= rxShift[127 : 0];
                  end
                end
                cmdDoneR <= 1'b1;
                state <= S_IDLE;
              end
            end
          end
        end
      end
    end
  end


endmodule

//Crc16_7 replaced by Crc16

//Crc16_6 replaced by Crc16

//Crc16_5 replaced by Crc16

//Crc16_4 replaced by Crc16

//Crc16_3 replaced by Crc16

//Crc16_2 replaced by Crc16

//Crc16_1 replaced by Crc16

module Crc16 (
  input  wire          io_clear,
  input  wire          io_enable,
  input  wire          io_bitIn,
  output wire [15:0]   io_crcOut,
  input  wire          clk,
  input  wire          resetn
);

  reg        [15:0]   crc;
  wire                feedback;

  assign feedback = (crc[15] ^ io_bitIn);
  assign io_crcOut = crc;
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      crc <= 16'h0;
    end else begin
      if(io_clear) begin
        crc <= 16'h0;
      end else begin
        if(io_enable) begin
          crc[15] <= crc[14];
          crc[14] <= crc[13];
          crc[13] <= crc[12];
          crc[12] <= (crc[11] ^ feedback);
          crc[11] <= crc[10];
          crc[10] <= crc[9];
          crc[9] <= crc[8];
          crc[8] <= crc[7];
          crc[7] <= crc[6];
          crc[6] <= crc[5];
          crc[5] <= (crc[4] ^ feedback);
          crc[4] <= crc[3];
          crc[3] <= crc[2];
          crc[2] <= crc[1];
          crc[1] <= crc[0];
          crc[0] <= feedback;
        end
      end
    end
  end


endmodule

module Crc7 (
  input  wire          io_clear,
  input  wire          io_enable,
  input  wire          io_bitIn,
  output wire [6:0]    io_crcOut,
  input  wire          clk,
  input  wire          resetn
);

  reg        [6:0]    crc;
  wire                feedback;

  assign feedback = (crc[6] ^ io_bitIn);
  assign io_crcOut = crc;
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      crc <= 7'h0;
    end else begin
      if(io_clear) begin
        crc <= 7'h0;
      end else begin
        if(io_enable) begin
          crc[6] <= crc[5];
          crc[5] <= crc[4];
          crc[4] <= crc[3];
          crc[3] <= (crc[2] ^ feedback);
          crc[2] <= crc[1];
          crc[1] <= crc[0];
          crc[0] <= feedback;
        end
      end
    end
  end


endmodule
