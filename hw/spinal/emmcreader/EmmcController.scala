package emmcreader

import spinal.core._

case class EmmcControllerConfig(clkFreq: Int = 60000000)

// eMMC Host Controller
// Combines CMD, DAT, init FSM, clock generator, and sector buffers.
// Tristate I/O handled in top — this module uses separate in/out/oe ports.
class EmmcController(config: EmmcControllerConfig = EmmcControllerConfig()) extends Component {
  noIoPrefix()
  setDefinitionName("emmc_controller")

  val io = new Bundle {
    // Physical eMMC pins (tristate in top)
    val emmcClk     = out Bool()
    val emmcRstn    = out Bool()
    val cmdOut      = out Bool()
    val cmdOe       = out Bool()
    val cmdIn       = in  Bool()
    val datOut      = out Bits(4 bits)
    val datOe       = out Bool()
    val datIn       = in  Bits(4 bits)

    // Command interface from uart_bridge
    val cmdValid          = in  Bool()
    val cmdId             = in  Bits(8 bits)
    val cmdLba            = in  UInt(32 bits)
    val cmdCount          = in  UInt(16 bits)
    val cmdReady          = out Bool()
    val respStatus        = out Bits(8 bits)
    val respValid         = out Bool()

    // Read buffer (UART reads sectors)
    val uartRdAddr        = in  UInt(9 bits)
    val uartRdData        = out Bits(8 bits)
    val rdSectorReady     = out Bool()
    val rdSectorAck       = in  Bool()

    // Write FIFO (UART writes sectors)
    val uartWrData        = in  Bits(8 bits)
    val uartWrAddr        = in  UInt(9 bits)
    val uartWrEn          = in  Bool()
    val uartWrSectorValid = in  Bool()
    val uartWrBank        = in  UInt(4 bits)
    val wrSectorAck       = out Bool()

    // Info outputs
    val cid               = out Bits(128 bits)
    val csd               = out Bits(128 bits)
    val infoValid         = out Bool()

    // Card status
    val cardStatus        = out Bits(32 bits)
    val rawRespData       = out Bits(128 bits)

    // Status
    val active            = out Bool()
    val ready             = out Bool()
    val error             = out Bool()

    // Debug (original 4-byte)
    val dbgInitState      = out Bits(4 bits)
    val dbgMcState        = out Bits(5 bits)
    val dbgCmdPin         = out Bool()
    val dbgDat0Pin        = out Bool()

    // Debug (extended 8-byte)
    val dbgCmdFsm         = out Bits(3 bits)
    val dbgDatFsm         = out Bits(4 bits)
    val dbgPartition      = out Bits(2 bits)
    val dbgUseFastClk     = out Bool()
    val dbgReinitPending  = out Bool()
    val dbgErrCmdTimeout  = out Bits(8 bits)
    val dbgErrCmdCrc      = out Bits(8 bits)
    val dbgErrDatRd       = out Bits(8 bits)
    val dbgErrDatWr       = out Bits(8 bits)
    val dbgInitRetryCnt   = out Bits(8 bits)
    val dbgClkPreset      = out Bits(3 bits)
  }

  // ============================================================
  // Constants
  // ============================================================
  val CLK_DIV_SLOW = 225 // ~133 kHz init clock (60MHz / 225*2)
  val CLK_DIV_FAST = 15  // 2 MHz default (60MHz / 15*2)

  // FSM states (26 states, 5-bit encoding)
  val MC_IDLE           = B(0, 5 bits)
  val MC_INIT           = B(1, 5 bits)
  val MC_READY          = B(2, 5 bits)
  val MC_READ_CMD       = B(3, 5 bits)
  val MC_READ_DAT       = B(4, 5 bits)
  val MC_READ_DONE      = B(5, 5 bits)
  val MC_WRITE_CMD      = B(6, 5 bits)
  val MC_WRITE_DAT      = B(7, 5 bits)
  val MC_WRITE_DONE     = B(8, 5 bits)
  val MC_STOP_CMD       = B(9, 5 bits)
  val MC_ERROR          = B(10, 5 bits)
  val MC_STOP_WAIT      = B(11, 5 bits)
  val MC_EXT_CSD_CMD    = B(12, 5 bits)
  val MC_EXT_CSD_DAT    = B(13, 5 bits)
  val MC_SWITCH_CMD     = B(14, 5 bits)
  val MC_SWITCH_WAIT    = B(15, 5 bits)
  val MC_ERASE_START    = B(16, 5 bits)
  val MC_ERASE_END      = B(17, 5 bits)
  val MC_ERASE_CMD      = B(18, 5 bits)
  val MC_STATUS_CMD     = B(19, 5 bits)
  val MC_ERROR_STOP     = B(20, 5 bits)
  val MC_RAW_CMD        = B(21, 5 bits)
  val MC_RAW_WAIT       = B(22, 5 bits)
  val MC_RPMB_CMD23     = B(23, 5 bits)
  val MC_RPMB_FIFO_WAIT = B(24, 5 bits)
  val MC_SWITCH_STATUS  = B(25, 5 bits)

  // Response status codes
  val STATUS_OK       = B"8'h00"
  val STATUS_CRC_ERR  = B"8'h01"
  val STATUS_CMD_ERR  = B"8'h02"
  val STATUS_EMMC_ERR = B"8'h03"
  val STATUS_BUSY     = B"8'h04"

  // RAW_CMD flag bit positions in cmdCount
  val RAW_FLAG_RESP_EXP  = 8
  val RAW_FLAG_RESP_LONG = 9
  val RAW_FLAG_BUSY_WAIT = 10

  // ============================================================
  // eMMC Clock Generator
  // ============================================================
  val useFastClk       = Reg(Bool()) init False
  val fastClkDivReload = Reg(UInt(9 bits)) init (CLK_DIV_FAST - 1)
  val currentClkPreset = Reg(UInt(3 bits)) init 0
  val clkDivCnt        = Reg(UInt(9 bits)) init (CLK_DIV_SLOW - 1)
  val clkDivReload     = Reg(UInt(9 bits)) init (CLK_DIV_SLOW - 1)
  val emmcClkReg       = Reg(Bool()) init False
  val clkEn            = Reg(Bool()) init False
  val clkPause         = Reg(Bool()) init False

  clkEn := False
  when(clkDivCnt === 0) {
    clkDivCnt  := clkDivReload
    emmcClkReg := ~emmcClkReg
    when(!emmcClkReg) {
      clkEn := True
    }
  }.elsewhen(!clkPause) {
    clkDivCnt := clkDivCnt - 1
  }
  when(useFastClk) {
    clkDivReload := fastClkDivReload
  }.otherwise {
    clkDivReload := U(CLK_DIV_SLOW - 1, 9 bits)
  }

  io.emmcClk := emmcClkReg

  // ============================================================
  // Metastability synchronizers (2-stage FF)
  // ============================================================
  val cmdInMeta = Reg(Bool()) init True
  val cmdInSync = Reg(Bool()) init True
  val datInMeta = Reg(Bits(4 bits)) init B"1111"
  val datInSync = Reg(Bits(4 bits)) init B"1111"

  cmdInMeta := io.cmdIn
  cmdInSync := cmdInMeta
  datInMeta := io.datIn
  datInSync := datInMeta

  // ============================================================
  // CMD Module
  // ============================================================
  val uCmd = new EmmcCmd
  uCmd.io.clkEn := clkEn
  uCmd.io.cmdIn := cmdInSync

  val cmdDone       = uCmd.io.cmdDone
  val cmdTimeout    = uCmd.io.cmdTimeout
  val cmdCrcErr     = uCmd.io.cmdCrcErr
  val cmdErrorW     = cmdTimeout || cmdCrcErr
  val cmdRespStatus = uCmd.io.respStatus

  // Device status error bits (JESD84-B51 §6.13, Table 68)
  // Bits: 31=ADDRESS_OUT_OF_RANGE, 23=COM_CRC_ERROR, 22=ILLEGAL_COMMAND,
  //       21=DEVICE_ECC_FAILED, 20=CC_ERROR, 19=ERROR, 7=SWITCH_ERROR
  val deviceStatusErr = (cmdRespStatus & B"32'h80F80080").orR
  val cmdRespData   = uCmd.io.respData

  io.cmdOut := uCmd.io.cmdOut
  io.cmdOe  := uCmd.io.cmdOe

  // ============================================================
  // DAT Module
  // ============================================================
  val datRdStart = Reg(Bool()) init False
  val datWrStart = Reg(Bool()) init False
  val busWidth4              = Reg(Bool()) init False
  val busWidthSwitchPending  = Reg(Bool()) init False
  val busWidthTarget         = Reg(Bool()) init False

  val uDat = new EmmcDat
  uDat.io.clkEn     := clkEn
  uDat.io.rdStart   := datRdStart
  uDat.io.wrStart   := datWrStart
  uDat.io.datIn     := datInSync
  uDat.io.busWidth4 := busWidth4

  val datRdDone   = uDat.io.rdDone
  val datRdCrcErr = uDat.io.rdCrcErr
  val datWrDone   = uDat.io.wrDone
  val datWrCrcErr = uDat.io.wrCrcErr

  io.datOut := uDat.io.datOut
  io.datOe  := uDat.io.datOe

  // ============================================================
  // Init Module
  // ============================================================
  val initStart = Reg(Bool()) init False

  val uInit = new EmmcInit(EmmcInitConfig(clkFreq = config.clkFreq))
  uInit.io.initStart := initStart
  uInit.io.cmdDone    := cmdDone
  uInit.io.cmdTimeout := cmdTimeout
  uInit.io.cmdCrcErr  := cmdCrcErr
  uInit.io.respStatus := cmdRespStatus
  uInit.io.respData   := cmdRespData

  io.emmcRstn  := uInit.io.emmcRstnOut
  io.cid       := uInit.io.cidReg
  io.csd       := uInit.io.csdReg
  io.infoValid := uInit.io.infoValid

  // ============================================================
  // Sector Buffers
  // ============================================================
  val emmcBank       = Reg(UInt(4 bits)) init 0
  val uartRdBank     = Reg(UInt(2 bits)) init 0
  val uartRdBankNext = Reg(UInt(2 bits)) init 0

  // Read buffer (2 banks x 512B, for eMMC→PC reads)
  val uSectorBuf = new SectorBuf
  uSectorBuf.io.bufSelA := emmcBank(1 downto 0).asBits
  uSectorBuf.io.addrA   := uDat.io.bufWrAddr
  uSectorBuf.io.wdataA  := uDat.io.bufWrData
  uSectorBuf.io.weA     := uDat.io.bufWrEn
  uSectorBuf.io.bufSelB := uartRdBank.asBits
  uSectorBuf.io.addrB   := io.uartRdAddr
  uSectorBuf.io.wdataB  := B(0, 8 bits)
  uSectorBuf.io.weB     := False

  io.uartRdData := uSectorBuf.io.rdataB

  // Write FIFO (16 banks x 512B, for PC→eMMC writes)
  val uWriteBuf = new SectorBufWr
  uWriteBuf.io.rdBank := emmcBank
  uWriteBuf.io.rdAddr := uDat.io.bufRdAddr
  uWriteBuf.io.wrBank := io.uartWrBank
  uWriteBuf.io.wrAddr := io.uartWrAddr
  uWriteBuf.io.wrData := io.uartWrData
  uWriteBuf.io.wrEn   := io.uartWrEn

  // DAT write path reads from write FIFO
  uDat.io.bufRdData := uWriteBuf.io.rdData

  // ============================================================
  // CMD Mux: init mode vs controller
  // ============================================================
  val isInitMode    = Reg(Bool()) init True
  val mcCmdStartR   = Reg(Bool()) init False
  val mcCmdIndexR   = Reg(UInt(6 bits)) init 0
  val mcCmdArgR     = Reg(Bits(32 bits)) init 0
  val mcCmdRespExpR = Reg(Bool()) init False
  val rawRespLongR  = Reg(Bool()) init False

  uCmd.io.cmdStart     := Mux(isInitMode, uInit.io.cmdStart, mcCmdStartR)
  uCmd.io.cmdIndex     := Mux(isInitMode, uInit.io.cmdIndex, mcCmdIndexR)
  uCmd.io.cmdArgument  := Mux(isInitMode, uInit.io.cmdArgument, mcCmdArgR)
  uCmd.io.respTypeLong := Mux(isInitMode, uInit.io.respTypeLong, rawRespLongR)
  uCmd.io.respExpected := Mux(isInitMode, uInit.io.respExpected, mcCmdRespExpR)

  // Pre-computed CMD13 SEND_STATUS argument: {RCA, 16'h0000}
  val statusArg = uInit.io.rcaReg ## B(0, 16 bits)

  // ============================================================
  // Main FSM registers
  // ============================================================
  val mcState          = Reg(Bits(5 bits)) init MC_IDLE
  val currentLba       = Reg(UInt(32 bits)) init 0
  val nextLba          = Reg(UInt(32 bits)) init 1
  val sectorsLeft      = Reg(UInt(16 bits)) init 0
  val eraseEndLba      = Reg(UInt(32 bits)) init 0
  val useMultiBlock    = Reg(Bool()) init False
  val isReadOp         = Reg(Bool()) init False
  val currentPartition = Reg(UInt(2 bits)) init 0
  val reinitPending    = Reg(Bool()) init False
  val eraseSecure      = Reg(Bool()) init False
  val bootRetryCnt     = Reg(UInt(2 bits)) init 0
  val rawCheckBusy     = Reg(Bool()) init False
  val forceMultiBlock   = Reg(Bool()) init False
  val switchNeedsVerify = Reg(Bool()) init False

  val cmdReadyR        = Reg(Bool()) init False
  val respStatusR      = Reg(Bits(8 bits)) init 0
  val respValidR       = Reg(Bool()) init False
  val rdSectorReadyR   = Reg(Bool()) init False
  val wrSectorAckR     = Reg(Bool()) init False
  val cardStatusR      = Reg(Bits(32 bits)) init 0
  val rawRespDataR     = Reg(Bits(128 bits)) init 0

  val switchWaitCnt    = Reg(UInt(20 bits)) init 0
  val wrDoneWatchdog   = Reg(UInt(24 bits)) init 0
  val wrDoneTimeout    = Reg(Bool()) init False

  io.cmdReady      := cmdReadyR
  io.respStatus    := respStatusR
  io.respValid     := respValidR
  io.rdSectorReady := rdSectorReadyR
  io.wrSectorAck   := wrSectorAckR
  io.cardStatus    := cardStatusR
  io.rawRespData   := rawRespDataR

  // ============================================================
  // Status and Debug outputs
  // ============================================================
  val activeReg = RegNext(mcState =/= MC_IDLE && mcState =/= MC_READY) init False
  io.active := activeReg
  io.ready  := (mcState === MC_READY)
  io.error  := (mcState === MC_ERROR)

  io.dbgInitState     := uInit.io.initStateDbg
  io.dbgMcState       := mcState
  io.dbgCmdPin        := cmdInSync
  io.dbgDat0Pin       := datInSync(0)
  io.dbgCmdFsm        := uCmd.io.dbgState
  io.dbgDatFsm        := uDat.io.dbgState
  io.dbgPartition     := currentPartition.asBits
  io.dbgUseFastClk    := useFastClk
  io.dbgReinitPending := reinitPending
  io.dbgInitRetryCnt  := uInit.io.dbgRetryCnt
  io.dbgClkPreset     := currentClkPreset.asBits

  // ============================================================
  // Saturating 8-bit error counters (separate logic, off critical path)
  // ============================================================
  val errCmdTimeoutCnt = Reg(UInt(8 bits)) init 0
  val errCmdCrcCnt     = Reg(UInt(8 bits)) init 0
  val errDatRdCnt      = Reg(UInt(8 bits)) init 0
  val errDatWrCnt      = Reg(UInt(8 bits)) init 0

  io.dbgErrCmdTimeout := errCmdTimeoutCnt.asBits
  io.dbgErrCmdCrc     := errCmdCrcCnt.asBits
  io.dbgErrDatRd      := errDatRdCnt.asBits
  io.dbgErrDatWr      := errDatWrCnt.asBits

  when(reinitPending && mcState === MC_IDLE) {
    errCmdTimeoutCnt := 0
    errCmdCrcCnt     := 0
    errDatRdCnt      := 0
    errDatWrCnt      := 0
  }.otherwise {
    when(cmdTimeout && !errCmdTimeoutCnt.andR) {
      errCmdTimeoutCnt := errCmdTimeoutCnt + 1
    }
    when(cmdCrcErr && !errCmdCrcCnt.andR) {
      errCmdCrcCnt := errCmdCrcCnt + 1
    }
    when(datRdCrcErr && !errDatRdCnt.andR) {
      errDatRdCnt := errDatRdCnt + 1
    }
    when((datWrCrcErr || wrDoneTimeout) && !errDatWrCnt.andR) {
      errDatWrCnt := errDatWrCnt + 1
    }
  }

  // ============================================================
  // Pre-decoded cmd_id flags (registered, removes comparisons from critical path)
  // ============================================================
  val cmdIsRead         = RegNext(io.cmdId === B"8'h03") init False
  val cmdIsWrite        = RegNext(io.cmdId === B"8'h04") init False
  val cmdIsErase        = RegNext(io.cmdId === B"8'h05") init False
  val cmdIsExtCsd       = RegNext(io.cmdId === B"8'h07") init False
  val cmdIsPartition    = RegNext(io.cmdId === B"8'h08") init False
  val cmdIsWriteExtCsd  = RegNext(io.cmdId === B"8'h09") init False
  val cmdIsStatus       = RegNext(io.cmdId === B"8'h0A") init False
  val cmdIsReinit       = RegNext(io.cmdId === B"8'h0B") init False
  val cmdIsSecureErase  = RegNext(io.cmdId === B"8'h0C") init False
  val cmdIsSetClk       = RegNext(io.cmdId === B"8'h0D") init False
  val cmdIsRaw          = RegNext(io.cmdId === B"8'h0E") init False
  val cmdIsSetRpmbMode  = RegNext(io.cmdId === B"8'h10") init False
  val cmdIsSetBusWidth  = RegNext(io.cmdId === B"8'h11") init False
  val cmdCountIsZero    = RegNext(io.cmdCount === 0) init True
  val cmdCountGtOne     = RegNext(io.cmdCount > 1) init False
  val cmdCountGtSixteen = RegNext(io.cmdCount > 16) init False

  // ============================================================
  // Delayed signals (1-cycle pipeline for flag settling)
  // ============================================================
  val cmdValidD      = RegNext(io.cmdValid) init False
  val wrSectorValidD = RegNext(io.uartWrSectorValid) init False

  // ============================================================
  // Pre-computed eMMC command parameters (registered pipeline)
  // Runs every cycle; coherent with cmdValidD (same 1-cycle latency).
  // Uses io.cmdId directly (not cmd_is_* flags) for correct alignment.
  // ============================================================
  val preCmdArgument = Reg(Bits(32 bits)) init 0
  val preCmdIndex    = Reg(UInt(6 bits)) init 0
  val preCmdRespExp  = Reg(Bool()) init False
  val preEraseEndLba = Reg(UInt(32 bits)) init 0

  preCmdRespExp := True // default: expect response
  switch(io.cmdId) {
    is(B"8'h03") { // READ_SECTOR
      preCmdArgument := io.cmdLba.asBits
      preCmdIndex    := Mux(io.cmdCount > 1 || forceMultiBlock, U(18, 6 bits), U(17, 6 bits))
    }
    is(B"8'h04") { // WRITE_SECTOR
      preCmdArgument := io.cmdLba.asBits
      preCmdIndex    := Mux(io.cmdCount > 1 || forceMultiBlock, U(25, 6 bits), U(24, 6 bits))
    }
    is(B"8'h05", B"8'h0C") { // ERASE, SECURE_ERASE
      preCmdArgument := io.cmdLba.asBits
      preCmdIndex    := U(35, 6 bits)
      preEraseEndLba := io.cmdLba + io.cmdCount.resize(32) - 1
    }
    is(B"8'h07") { // GET_EXT_CSD (CMD8)
      preCmdArgument := B(0, 32 bits)
      preCmdIndex    := U(8, 6 bits)
    }
    is(B"8'h08") { // SET_PARTITION (CMD6 index=179)
      preCmdArgument := B(0, 6 bits) ## B"2'b11" ## B(179, 8 bits) ## io.cmdLba(7 downto 0).asBits ## B(0, 8 bits)
      preCmdIndex    := U(6, 6 bits)
    }
    is(B"8'h09") { // WRITE_EXT_CSD (CMD6 generic)
      preCmdArgument := B(0, 6 bits) ## B"2'b11" ## io.cmdLba(15 downto 8).asBits ## io.cmdLba(7 downto 0).asBits ## B(0, 8 bits)
      preCmdIndex    := U(6, 6 bits)
    }
    is(B"8'h0A") { // GET_CARD_STATUS (CMD13)
      preCmdArgument := statusArg
      preCmdIndex    := U(13, 6 bits)
    }
    is(B"8'h11") { // SET_BUS_WIDTH → CMD6 SWITCH ExtCSD[183] (BUS_WIDTH)
      // value=0x01 (4-bit) if cmdLba(0)=1, value=0x00 (1-bit) if cmdLba(0)=0
      preCmdArgument := B(0, 6 bits) ## B"2'b11" ## B(183, 8 bits) ##
                         Mux(io.cmdLba(0), B"8'h01", B"8'h00") ## B(0, 8 bits)
      preCmdIndex    := U(6, 6 bits)
    }
    is(B"8'h0E") { // SEND_RAW_CMD
      preCmdArgument := io.cmdLba.asBits
      preCmdIndex    := io.cmdCount(5 downto 0)
      preCmdRespExp  := io.cmdCount(RAW_FLAG_RESP_EXP)
    }
    default {
      preCmdArgument := B(0, 32 bits)
      preCmdIndex    := U(0, 6 bits)
      preCmdRespExp  := False
    }
  }

  // ============================================================
  // Preset → divider-1 lookup (combinational, used by SET_CLK)
  // ============================================================
  val presetVal   = io.cmdLba(2 downto 0)
  val presetDivM1 = UInt(9 bits)
  presetDivM1 := U(14, 9 bits) // default: preset 0 → div=15, div-1=14
  when(presetVal === 1) { presetDivM1 := U(7, 9 bits) }
  when(presetVal === 2) { presetDivM1 := U(4, 9 bits) }
  when(presetVal === 3) { presetDivM1 := U(2, 9 bits) }
  when(presetVal === 4) { presetDivM1 := U(1, 9 bits) }
  when(presetVal === 5) { presetDivM1 := U(1, 9 bits) }
  when(presetVal === 6) { presetDivM1 := U(0, 9 bits) }

  // ============================================================
  // Main FSM
  // ============================================================
  // Default pulse clears
  initStart     := False
  datRdStart    := False
  datWrStart    := False
  mcCmdStartR   := False
  respValidR    := False
  wrSectorAckR  := False
  wrDoneTimeout := False

  // rd_sector_ready: sticky level, cleared by ack from uart_bridge
  when(io.rdSectorAck) {
    rdSectorReadyR := False
    uartRdBank     := uartRdBankNext // promote staged bank on ACK
  }

  // Pre-compute next LBA every cycle
  nextLba := currentLba + 1

  // FSM body
  when(mcState === MC_IDLE) {
    isInitMode := True
    initStart  := True
    mcState    := MC_INIT

  }.elsewhen(mcState === MC_INIT) {
    useFastClk := uInit.io.useFastClk
    when(uInit.io.initDone) {
      isInitMode := False
      cmdReadyR  := True
      mcState    := MC_READY
      when(reinitPending) {
        respStatusR   := STATUS_OK
        respValidR    := True
        reinitPending := False
      }
    }.elsewhen(uInit.io.initError) {
      when(reinitPending) {
        respStatusR   := STATUS_EMMC_ERR
        respValidR    := True
        cmdReadyR     := True
        reinitPending := False
        mcState       := MC_READY
      }.elsewhen(bootRetryCnt < 3) {
        bootRetryCnt := bootRetryCnt + 1
        mcState      := MC_IDLE
      }.otherwise {
        mcState := MC_ERROR
      }
    }

  }.elsewhen(mcState === MC_READY) {
    when(cmdValidD) {
      cmdReadyR := False

      // Load pre-computed parameters (simple register load, off critical path)
      mcCmdArgR     := preCmdArgument
      mcCmdIndexR   := preCmdIndex
      mcCmdRespExpR := preCmdRespExp

      // Count=0 validation (read/write/erase)
      when((cmdIsRead || cmdIsWrite || cmdIsErase || cmdIsSecureErase) && cmdCountIsZero) {
        respStatusR := STATUS_CMD_ERR
        respValidR  := True
        cmdReadyR   := True
      }
      .elsewhen(cmdIsRead) {
        currentLba    := io.cmdLba
        sectorsLeft   := io.cmdCount
        isReadOp      := True
        useMultiBlock := cmdCountGtOne || forceMultiBlock
        mcState       := Mux(forceMultiBlock, MC_RPMB_CMD23, MC_READ_CMD)
      }
      .elsewhen(cmdIsWrite && cmdCountGtSixteen) {
        respStatusR := STATUS_CMD_ERR
        respValidR  := True
        cmdReadyR   := True
      }
      .elsewhen(cmdIsWrite) {
        currentLba    := io.cmdLba
        sectorsLeft   := io.cmdCount
        isReadOp      := False
        useMultiBlock := cmdCountGtOne || forceMultiBlock
        emmcBank      := 0
        when(forceMultiBlock) {
          mcState := MC_RPMB_CMD23
        }.elsewhen(wrSectorValidD) {
          wrSectorAckR := True  // consume initial sector-valid to prevent MC_WRITE_DONE reuse
          mcState := MC_WRITE_CMD
        }
      }
      .elsewhen(cmdIsExtCsd) {
        mcState := MC_EXT_CSD_CMD
      }
      .elsewhen(cmdIsErase || cmdIsSecureErase) {
        currentLba  := io.cmdLba
        sectorsLeft := io.cmdCount
        eraseSecure := cmdIsSecureErase
        eraseEndLba := preEraseEndLba
        mcState     := MC_ERASE_START
      }
      .elsewhen(cmdIsPartition) {
        currentPartition := io.cmdLba(1 downto 0)
        mcState := MC_SWITCH_CMD
      }
      .elsewhen(cmdIsWriteExtCsd) {
        mcState := MC_SWITCH_CMD
      }
      .elsewhen(cmdIsStatus) {
        mcState := MC_STATUS_CMD
      }
      .elsewhen(cmdIsReinit) {
        reinitPending := True
        useFastClk    := False
        busWidth4     := False
        busWidthSwitchPending := False
        mcState       := MC_IDLE
      }
      .elsewhen(cmdIsSetClk) {
        when(presetVal <= 6) {
          fastClkDivReload := presetDivM1
          currentClkPreset := presetVal
          respStatusR      := STATUS_OK
        }.otherwise {
          respStatusR := STATUS_CMD_ERR
        }
        respValidR := True
        cmdReadyR  := True
      }
      .elsewhen(cmdIsSetRpmbMode) {
        forceMultiBlock := io.cmdLba(0)
        respStatusR     := STATUS_OK
        respValidR      := True
        cmdReadyR       := True
      }
      .elsewhen(cmdIsSetBusWidth) {
        busWidthSwitchPending := True
        busWidthTarget := io.cmdLba(0)
        mcState := MC_SWITCH_CMD  // reuse existing CMD6 path
      }
      .elsewhen(cmdIsRaw) {
        rawCheckBusy := io.cmdCount(RAW_FLAG_BUSY_WAIT)
        rawRespLongR := io.cmdCount(RAW_FLAG_RESP_LONG)
        mcState      := MC_RAW_CMD
      }
      .otherwise {
        respStatusR := STATUS_CMD_ERR
        respValidR  := True
        cmdReadyR   := True
      }
    }

  }.elsewhen(mcState === MC_READ_CMD) {
    isInitMode := False
    when(cmdDone) {
      when(cmdErrorW || deviceStatusErr) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        datRdStart := True
        mcState    := MC_READ_DAT
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_READ_DAT) {
    when(datRdDone) {
      when(datRdCrcErr) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        rdSectorReadyR := True
        uartRdBankNext := emmcBank(1 downto 0)
        emmcBank       := emmcBank + 1
        sectorsLeft    := sectorsLeft - 1
        currentLba     := nextLba
        mcCmdArgR      := nextLba.asBits
        mcState        := MC_READ_DONE
      }
    }

  }.elsewhen(mcState === MC_READ_DONE) {
    when(sectorsLeft === 0) {
      clkPause := False
      when(useMultiBlock && !forceMultiBlock) {
        // CMD12 STOP required for open-ended CMD18
        mcCmdIndexR   := U(12, 6 bits)
        mcCmdArgR     := B(0, 32 bits)
        mcCmdRespExpR := True
        mcState       := MC_STOP_CMD
      }.otherwise {
        respStatusR := STATUS_OK
        respValidR  := True
        cmdReadyR   := True
        mcState     := MC_READY
      }
    }.otherwise {
      when(useMultiBlock) {
        // Multi-block: backpressure — pause eMMC CLK while UART drains
        when(!rdSectorReadyR || io.rdSectorAck) {
          clkPause   := False
          datRdStart := True
          mcState    := MC_READ_DAT
        }.otherwise {
          clkPause := True
        }
      }.otherwise {
        // Single-block: issue new CMD17
        mcState := MC_READ_CMD
      }
    }

  }.elsewhen(mcState === MC_WRITE_CMD) {
    when(cmdDone) {
      when(cmdErrorW || deviceStatusErr) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        datWrStart := True
        mcState    := MC_WRITE_DAT
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_WRITE_DAT) {
    when(datWrDone) {
      when(datWrCrcErr) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        sectorsLeft    := sectorsLeft - 1
        currentLba     := nextLba
        mcCmdArgR      := nextLba.asBits
        wrDoneWatchdog := 0
        mcState        := MC_WRITE_DONE
      }
    }

  }.elsewhen(mcState === MC_WRITE_DONE) {
    when(sectorsLeft === 0) {
      wrDoneWatchdog := 0
      when(useMultiBlock && !forceMultiBlock) {
        // CMD12 STOP required for open-ended CMD25
        mcCmdIndexR   := U(12, 6 bits)
        mcCmdArgR     := B(0, 32 bits)
        mcCmdRespExpR := True
        mcState       := MC_STOP_CMD
      }.otherwise {
        respStatusR := STATUS_OK
        respValidR  := True
        cmdReadyR   := True
        mcState     := MC_READY
      }
    }.otherwise {
      // Watchdog: abort if UART doesn't provide data within ~280ms
      wrDoneWatchdog := wrDoneWatchdog + 1
      when(wrDoneWatchdog.andR) {
        when(useMultiBlock) {
          mcCmdIndexR   := U(12, 6 bits)
          mcCmdArgR     := B(0, 32 bits)
          mcCmdRespExpR := True
          mcState       := MC_ERROR_STOP
        }.otherwise {
          respStatusR := STATUS_EMMC_ERR
          respValidR  := True
          cmdReadyR   := True
          mcState     := MC_READY
        }
        wrDoneTimeout := True
      }.elsewhen(useMultiBlock) {
        // Multi-block: continue DAT with next sector
        when(io.uartWrSectorValid) {
          wrDoneWatchdog := 0
          wrSectorAckR   := True
          emmcBank       := emmcBank + 1
          datWrStart     := True
          mcState        := MC_WRITE_DAT
        }
      }.otherwise {
        // Single-block: issue new CMD24
        when(io.uartWrSectorValid) {
          wrDoneWatchdog := 0
          wrSectorAckR   := True
          emmcBank       := emmcBank + 1
          mcState        := MC_WRITE_CMD
        }
      }
    }

  }.elsewhen(mcState === MC_STOP_CMD) {
    when(cmdDone) {
      when(cmdErrorW) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        switchWaitCnt := 0
        mcState       := MC_STOP_WAIT
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_STOP_WAIT) {
    // Poll DAT0: card holds low while busy (R1b)
    when(clkEn) {
      when(datInSync(0)) {
        respStatusR := STATUS_OK
        respValidR  := True
        cmdReadyR   := True
        mcState     := MC_READY
      }.otherwise {
        switchWaitCnt := switchWaitCnt + 1
        when(switchWaitCnt === U"20'hFFFFF") {
          respStatusR := STATUS_EMMC_ERR
          mcState     := MC_ERROR
        }
      }
    }

  }.elsewhen(mcState === MC_EXT_CSD_CMD) {
    isInitMode := False
    when(cmdDone) {
      when(cmdErrorW || deviceStatusErr) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        datRdStart := True
        mcState    := MC_EXT_CSD_DAT
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_EXT_CSD_DAT) {
    when(datRdDone) {
      when(datRdCrcErr) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        rdSectorReadyR := True
        uartRdBankNext := emmcBank(1 downto 0)
        emmcBank       := emmcBank + 1
        respStatusR    := STATUS_OK
        respValidR     := True
        cmdReadyR      := True
        mcState        := MC_READY
      }
    }

  }.elsewhen(mcState === MC_SWITCH_CMD) {
    isInitMode := False
    when(cmdDone) {
      when(cmdErrorW) {
        busWidthSwitchPending := False
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        switchNeedsVerify := True
        switchWaitCnt     := 0
        mcState           := MC_SWITCH_WAIT
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_SWITCH_WAIT) {
    // Poll DAT0: card holds low while busy
    when(clkEn) {
      when(datInSync(0)) {
        when(switchNeedsVerify) {
          // JESD84-B51 §6.6.1: verify SWITCH result via CMD13
          mcCmdIndexR   := U(13, 6 bits)
          mcCmdArgR     := statusArg
          mcCmdRespExpR := True
          rawRespLongR  := False
          mcState       := MC_SWITCH_STATUS
        }.otherwise {
          // Erase busy wait — return directly
          respStatusR := STATUS_OK
          respValidR  := True
          cmdReadyR   := True
          mcState     := MC_READY
        }
      }.otherwise {
        switchWaitCnt := switchWaitCnt + 1
        when(switchWaitCnt === U"20'hFFFFF") {
          busWidthSwitchPending := False
          respStatusR := STATUS_EMMC_ERR
          mcState     := MC_ERROR
        }
      }
    }

  }.elsewhen(mcState === MC_SWITCH_STATUS) {
    // CMD13 SEND_STATUS to verify CMD6 SWITCH result (JESD84-B51 §6.6.1)
    isInitMode := False
    when(cmdDone) {
      when(cmdErrorW || deviceStatusErr) {
        // SWITCH_ERROR (bit 7) or CMD13 failure
        busWidthSwitchPending := False
        respStatusR := STATUS_EMMC_ERR
        respValidR  := True
        cmdReadyR   := True
        mcState     := MC_READY
      }.otherwise {
        when(busWidthSwitchPending) {
          busWidth4 := busWidthTarget
          busWidthSwitchPending := False
        }
        respStatusR := STATUS_OK
        respValidR  := True
        cmdReadyR   := True
        mcState     := MC_READY
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_ERASE_START) {
    // CMD35 ERASE_GROUP_START
    when(cmdDone) {
      when(cmdErrorW || deviceStatusErr) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        mcCmdIndexR := U(36, 6 bits)
        mcCmdArgR   := eraseEndLba.asBits
        mcState     := MC_ERASE_END
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_ERASE_END) {
    // CMD36 ERASE_GROUP_END
    when(cmdDone) {
      when(cmdErrorW || deviceStatusErr) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        mcCmdIndexR := U(38, 6 bits)
        mcCmdArgR   := Mux(eraseSecure, B"32'h80000000", B(0, 32 bits))
        mcState     := MC_ERASE_CMD
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_ERASE_CMD) {
    // CMD38 ERASE, then wait for DAT0 busy
    when(cmdDone) {
      when(cmdErrorW || deviceStatusErr) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        switchNeedsVerify := False
        switchWaitCnt     := 0
        mcState           := MC_SWITCH_WAIT // reuse for DAT0 busy wait
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_STATUS_CMD) {
    // CMD13 SEND_STATUS
    isInitMode := False
    when(cmdDone) {
      when(cmdErrorW) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.otherwise {
        cardStatusR := cmdRespStatus
        respStatusR := STATUS_OK
        respValidR  := True
        cmdReadyR   := True
        mcState     := MC_READY
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_RPMB_CMD23) {
    // CMD23 SET_BLOCK_COUNT before RPMB read/write
    when(cmdDone) {
      when(cmdErrorW) {
        respStatusR := STATUS_EMMC_ERR
        mcState     := MC_ERROR
      }.elsewhen(isReadOp) {
        mcCmdIndexR   := preCmdIndex    // CMD18
        mcCmdArgR     := preCmdArgument // LBA
        mcCmdRespExpR := True
        mcState       := MC_READ_CMD
      }.elsewhen(wrSectorValidD) {
        mcCmdIndexR   := preCmdIndex    // CMD25
        mcCmdArgR     := preCmdArgument // LBA
        mcCmdRespExpR := True
        mcState       := MC_WRITE_CMD
      }.otherwise {
        // CMD23 done, but FIFO not ready yet — wait
        wrDoneWatchdog := 0
        mcState        := MC_RPMB_FIFO_WAIT
      }
    }.otherwise {
      // Send CMD23: arg = block_count (reliable write bit for writes)
      mcCmdIndexR   := U(23, 6 bits)
      mcCmdArgR     := Mux(isReadOp, B"32'h00000001", B"32'h80000001")
      mcCmdRespExpR := True
      mcCmdStartR   := True
    }

  }.elsewhen(mcState === MC_RPMB_FIFO_WAIT) {
    // Wait for write FIFO data after CMD23 completed
    when(wrSectorValidD) {
      wrDoneWatchdog := 0
      mcCmdIndexR    := preCmdIndex    // CMD25
      mcCmdArgR      := preCmdArgument // LBA
      mcCmdRespExpR  := True
      mcState        := MC_WRITE_CMD
    }.otherwise {
      wrDoneWatchdog := wrDoneWatchdog + 1
      when(wrDoneWatchdog.andR) {
        respStatusR   := STATUS_EMMC_ERR
        wrDoneTimeout := True
        respValidR    := True
        cmdReadyR     := True
        mcState       := MC_READY
      }
    }

  }.elsewhen(mcState === MC_RAW_CMD) {
    when(cmdDone) {
      rawRespLongR := False // clear for CMD mux safety
      when(cmdErrorW) {
        respStatusR := STATUS_EMMC_ERR
        respValidR  := True
        cmdReadyR   := True
        mcState     := MC_READY
      }.otherwise {
        cardStatusR  := cmdRespStatus  // R1 short response
        rawRespDataR := cmdRespData    // R2 long response
        when(rawCheckBusy) {
          switchWaitCnt := 0
          mcState       := MC_RAW_WAIT
        }.otherwise {
          respStatusR := STATUS_OK
          respValidR  := True
          cmdReadyR   := True
          mcState     := MC_READY
        }
      }
    }.otherwise {
      mcCmdStartR := True
    }

  }.elsewhen(mcState === MC_RAW_WAIT) {
    // Poll DAT0: busy wait after raw CMD
    when(clkEn) {
      when(datInSync(0)) {
        respStatusR := STATUS_OK
        respValidR  := True
        cmdReadyR   := True
        mcState     := MC_READY
      }.otherwise {
        switchWaitCnt := switchWaitCnt + 1
        when(switchWaitCnt === U"20'hFFFFF") {
          respStatusR := STATUS_EMMC_ERR
          mcState     := MC_ERROR
        }
      }
    }

  }.elsewhen(mcState === MC_ERROR) {
    when(useMultiBlock) {
      // Send CMD12 STOP_TRANSMISSION before returning
      mcCmdIndexR   := U(12, 6 bits)
      mcCmdArgR     := B(0, 32 bits)
      mcCmdRespExpR := True
      mcState       := MC_ERROR_STOP
    }.otherwise {
      respValidR := True
      cmdReadyR  := True
      mcState    := MC_READY
    }

  }.elsewhen(mcState === MC_ERROR_STOP) {
    // CMD12 after multi-block error, preserve respStatusR
    when(cmdDone) {
      respValidR := True
      cmdReadyR  := True
      mcState    := MC_READY
    }.otherwise {
      mcCmdStartR := True
    }
  }
}
