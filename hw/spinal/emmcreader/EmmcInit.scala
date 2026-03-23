package emmcreader

import spinal.core._

// eMMC Initialization Sequence FSM
// Implements: RST low 1ms → RST high 50ms → CMD0 → CMD1 (poll) → CMD2 → CMD3 → CMD9 → CMD7 → CMD16
case class EmmcInitConfig(clkFreq: Int = 60000000)

class EmmcInit(config: EmmcInitConfig = EmmcInitConfig()) extends Component {
  val io = new Bundle {
    val initStart    = in  Bool()
    val initDone     = out Bool()
    val initError    = out Bool()
    val initStateDbg = out Bits(4 bits)
    // CMD interface
    val cmdStart      = out Bool()
    val cmdIndex      = out UInt(6 bits)
    val cmdArgument   = out Bits(32 bits)
    val respTypeLong  = out Bool()
    val respExpected  = out Bool()
    val cmdDone       = in  Bool()
    val cmdTimeout    = in  Bool()
    val cmdCrcErr     = in  Bool()
    val respStatus    = in  Bits(32 bits)
    val respData      = in  Bits(128 bits)
    // Outputs
    val cidReg        = out Bits(128 bits)
    val csdReg        = out Bits(128 bits)
    val rcaReg        = out Bits(16 bits)
    val infoValid     = out Bool()
    val useFastClk    = out Bool()
    val emmcRstnOut   = out Bool()
    val dbgRetryCnt   = out Bits(8 bits)
  }

  val TICKS_1MS   = config.clkFreq / 1000
  val TICKS_50MS  = config.clkFreq / 20
  val MAX_CMD1_RETRIES = 1400

  // FSM states
  val SI_IDLE       = B(0, 4 bits)
  val SI_RESET_LOW  = B(1, 4 bits)
  val SI_RESET_HIGH = B(2, 4 bits)
  val SI_CMD0       = B(3, 4 bits)
  val SI_CMD1       = B(4, 4 bits)
  val SI_CMD1_WAIT  = B(5, 4 bits)
  val SI_CMD2       = B(6, 4 bits)
  val SI_CMD3       = B(7, 4 bits)
  val SI_CMD9       = B(8, 4 bits)
  val SI_CMD7       = B(9, 4 bits)
  val SI_CMD16      = B(11, 4 bits)
  val SI_DONE       = B(12, 4 bits)
  val SI_ERROR      = B(13, 4 bits)
  val SI_WAIT_CMD   = B(14, 4 bits)
  val SI_CMD7_WAIT  = B(15, 4 bits)

  val state       = Reg(Bits(4 bits)) init 0
  val nextState   = Reg(Bits(4 bits)) init 0
  val waitCnt     = Reg(UInt(24 bits)) init 0
  val waitCntZero = Reg(Bool()) init True
  val retryCnt    = Reg(UInt(16 bits)) init 0
  val waitingCmd  = Reg(Bool()) init False
  val isSectorMode = Reg(Bool()) init False

  val initDoneR     = Reg(Bool()) init False
  val initErrorR    = Reg(Bool()) init False
  val initStartR    = Reg(Bool()) init False
  val cmdStartR     = Reg(Bool()) init False
  val cmdIndexR     = Reg(UInt(6 bits)) init 0
  val cmdArgumentR  = Reg(Bits(32 bits)) init 0
  val respTypeLongR = Reg(Bool()) init False
  val respExpectedR = Reg(Bool()) init False
  val cidRegR       = Reg(Bits(128 bits)) init 0
  val csdRegR       = Reg(Bits(128 bits)) init 0
  val rcaRegR       = Reg(Bits(16 bits)) init B"16'h0001" allowUnsetRegToAvoidLatch
  val infoValidR    = Reg(Bool()) init False
  val useFastClkR   = Reg(Bool()) init False
  val emmcRstnOutR  = Reg(Bool()) init False

  io.initDone     := initDoneR
  io.initError    := initErrorR
  io.initStateDbg := state
  io.cmdStart     := cmdStartR
  io.cmdIndex     := cmdIndexR
  io.cmdArgument  := cmdArgumentR
  io.respTypeLong := respTypeLongR
  io.respExpected := respExpectedR
  io.cidReg       := cidRegR
  io.csdReg       := csdRegR
  io.rcaReg       := rcaRegR
  io.infoValid    := infoValidR
  io.useFastClk   := useFastClkR
  io.emmcRstnOut  := emmcRstnOutR
  io.dbgRetryCnt  := Mux(retryCnt > 255, B"8'hFF", retryCnt(7 downto 0).asBits)

  // Default pulse clears
  cmdStartR := False
  initStartR := io.initStart

  when(state === SI_IDLE) {
    initDoneR  := False
    initErrorR := False
    when(initStartR) {
      infoValidR    := False
      useFastClkR   := False
      emmcRstnOutR  := False
      waitCnt       := U(TICKS_1MS, 24 bits)
      waitCntZero   := False
      state         := SI_RESET_LOW
    }
  }.elsewhen(state === SI_RESET_LOW) {
    waitCnt     := waitCnt - 1
    waitCntZero := (waitCnt === 1)
    when(waitCntZero) {
      emmcRstnOutR := True
      waitCnt      := U(TICKS_50MS, 24 bits)
      waitCntZero  := False
      state        := SI_RESET_HIGH
    }
  }.elsewhen(state === SI_RESET_HIGH) {
    waitCnt     := waitCnt - 1
    waitCntZero := (waitCnt === 1)
    when(waitCntZero) {
      state := SI_CMD0
    }
  }.elsewhen(state === SI_CMD0) {
    cmdIndexR     := 0
    cmdArgumentR  := B(0, 32 bits)
    respTypeLongR := False
    respExpectedR := False
    cmdStartR     := True
    nextState     := SI_CMD1
    retryCnt      := 0
    waitCnt       := 0
    state         := SI_WAIT_CMD
  }.elsewhen(state === SI_CMD1) {
    cmdIndexR     := 1
    cmdArgumentR  := B"32'h40FF8080"
    respTypeLongR := False
    respExpectedR := True
    cmdStartR     := True
    nextState     := SI_CMD1_WAIT
    state         := SI_WAIT_CMD
  }.elsewhen(state === SI_CMD1_WAIT) {
    when(io.respStatus(31)) {
      isSectorMode := io.respStatus(30)
      state        := SI_CMD2
    }.otherwise {
      retryCnt := retryCnt + 1
      when(retryCnt >= MAX_CMD1_RETRIES) {
        state := SI_ERROR
      }.otherwise {
        waitCnt := 0
        state   := SI_CMD1
      }
    }
  }.elsewhen(state === SI_CMD2) {
    cmdIndexR     := 2
    cmdArgumentR  := B(0, 32 bits)
    respTypeLongR := True
    respExpectedR := True
    cmdStartR     := True
    nextState     := SI_CMD3
    state         := SI_WAIT_CMD
  }.elsewhen(state === SI_CMD3) {
    cidRegR := io.respData
    cmdIndexR     := 3
    cmdArgumentR  := rcaRegR ## B(0, 16 bits)
    respTypeLongR := False
    respExpectedR := True
    cmdStartR     := True
    nextState     := SI_CMD9
    state         := SI_WAIT_CMD
  }.elsewhen(state === SI_CMD9) {
    cmdIndexR     := 9
    cmdArgumentR  := rcaRegR ## B(0, 16 bits)
    respTypeLongR := True
    respExpectedR := True
    cmdStartR     := True
    nextState     := SI_CMD7
    state         := SI_WAIT_CMD
  }.elsewhen(state === SI_CMD7) {
    csdRegR := io.respData
    cmdIndexR     := 7
    cmdArgumentR  := rcaRegR ## B(0, 16 bits)
    respTypeLongR := False
    respExpectedR := True
    cmdStartR     := True
    waitCnt       := U(TICKS_1MS, 24 bits)
    waitCntZero   := False
    nextState     := SI_CMD7_WAIT
    state         := SI_WAIT_CMD
  }.elsewhen(state === SI_CMD7_WAIT) {
    waitCnt     := waitCnt - 1
    waitCntZero := (waitCnt === 1)
    when(waitCntZero) {
      state := Mux(isSectorMode, SI_DONE, SI_CMD16)
    }
  }.elsewhen(state === SI_CMD16) {
    cmdIndexR     := 16
    cmdArgumentR  := B(512, 32 bits)
    respTypeLongR := False
    respExpectedR := True
    cmdStartR     := True
    nextState     := SI_DONE
    state         := SI_WAIT_CMD
  }.elsewhen(state === SI_WAIT_CMD) {
    when(io.cmdDone) {
      when(io.cmdTimeout) {
        when(nextState === SI_CMD1_WAIT) {
          retryCnt := retryCnt + 1
          when(retryCnt >= MAX_CMD1_RETRIES) {
            state := SI_ERROR
          }.otherwise {
            state := SI_CMD1
          }
        }.otherwise {
          state := SI_ERROR
        }
      }.elsewhen(io.cmdCrcErr && nextState =/= SI_CMD1_WAIT) {
        state := SI_ERROR
      }.otherwise {
        state := nextState
      }
    }
  }.elsewhen(state === SI_DONE) {
    infoValidR  := True
    initDoneR   := True
    useFastClkR := True
    state       := SI_IDLE
  }.elsewhen(state === SI_ERROR) {
    initErrorR := True
    state      := SI_IDLE
  }
}
