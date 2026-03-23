package emmcreader

import spinal.core._

// eMMC CMD Line Protocol Handler
// Sends 48-bit commands and receives 48-bit or 136-bit responses
// Works on eMMC clock domain (driven by clk_en strobe from controller)
class EmmcCmd extends Component {
  val io = new Bundle {
    val clkEn         = in  Bool()
    // Command interface
    val cmdStart      = in  Bool()
    val cmdIndex      = in  UInt(6 bits)
    val cmdArgument   = in  Bits(32 bits)
    val respTypeLong  = in  Bool()       // 0=R1(48-bit), 1=R2(136-bit)
    val respExpected  = in  Bool()       // 0=no response (CMD0), 1=expect response
    val cmdDone       = out Bool()
    val cmdTimeout    = out Bool()
    val cmdCrcErr     = out Bool()
    val respStatus    = out Bits(32 bits)
    val respData      = out Bits(128 bits)
    // Physical CMD line
    val cmdOut        = out Bool()
    val cmdOe         = out Bool()
    val cmdIn         = in  Bool()
    // Debug
    val dbgState      = out Bits(3 bits)
  }

  val S_IDLE = B"000"
  val S_SEND = B"001"
  val S_WAIT = B"010"
  val S_RECV = B"011"
  val S_DONE = B"100"

  val state      = Reg(Bits(3 bits)) init 0
  val bitCnt     = Reg(UInt(8 bits)) init 0
  val txShift    = Reg(Bits(48 bits)) init 0
  val rxShift    = Reg(Bits(136 bits)) init 0
  val timeoutCnt = Reg(UInt(16 bits)) init 0
  val cmdTimeoutFlag = Reg(Bool()) init False
  val respLong   = Reg(Bool()) init False
  val respExp    = Reg(Bool()) init False
  val crcShift   = Reg(Bits(7 bits)) init 0
  val sendIsDataPhase = Reg(Bool()) init False
  val sendLatchCrc    = Reg(Bool()) init False
  val sendIsDone      = Reg(Bool()) init False

  val cmdDoneR    = Reg(Bool()) init False
  val cmdTimeoutR = Reg(Bool()) init False
  val cmdCrcErrR  = Reg(Bool()) init False
  val respStatusR = Reg(Bits(32 bits)) init 0
  val respDataR   = Reg(Bits(128 bits)) init 0
  val cmdOutR     = Reg(Bool()) init True
  val cmdOeR      = Reg(Bool()) init False

  io.dbgState    := state
  io.cmdDone     := cmdDoneR
  io.cmdTimeout  := cmdTimeoutR
  io.cmdCrcErr   := cmdCrcErrR
  io.respStatus  := respStatusR
  io.respData    := respDataR
  io.cmdOut      := cmdOutR
  io.cmdOe       := cmdOeR

  // CRC-7 instance
  val crcClear = Reg(Bool()) init True
  val crcEn    = Reg(Bool()) init False
  val crcBit   = Reg(Bool()) init False

  val uCrc7 = new Crc7
  uCrc7.io.clear  := crcClear
  uCrc7.io.enable := crcEn
  uCrc7.io.bitIn  := crcBit
  val crcOut = uCrc7.io.crcOut

  // Default pulse clears
  cmdDoneR    := False
  cmdTimeoutR := False
  cmdCrcErrR  := False
  crcClear    := False
  crcEn       := False

  when(state === S_IDLE) {
    cmdOeR  := False
    cmdOutR := True
    when(io.cmdStart && !cmdDoneR) {
      txShift(47)            := False              // start bit
      txShift(46)            := True               // transmit bit
      txShift(45 downto 40)  := io.cmdIndex.asBits
      txShift(39 downto 8)   := io.cmdArgument
      txShift(7 downto 1)    := B(0, 7 bits)       // placeholder for CRC
      txShift(0)             := True               // end bit
      respLong := io.respTypeLong
      respExp  := io.respExpected
      bitCnt   := 0
      crcClear := True
      sendIsDataPhase := True
      sendLatchCrc    := False
      sendIsDone      := False
      state := S_SEND
    }
  }.elsewhen(state === S_SEND) {
    when(io.clkEn) {
      cmdOeR := True

      when(sendIsDataPhase) {
        cmdOutR  := txShift(47)
        txShift  := txShift(46 downto 0) ## B"0"
        crcEn    := True
        crcBit   := txShift(47)
      }.elsewhen(sendLatchCrc) {
        cmdOutR   := crcOut(6)
        crcShift  := crcOut(5 downto 0) ## B"0"
      }.elsewhen(!sendIsDone) {
        cmdOutR   := crcShift(6)
        crcShift  := crcShift(5 downto 0) ## B"0"
      }.otherwise {
        cmdOutR := True
      }

      bitCnt := bitCnt + 1

      sendIsDataPhase := (bitCnt < 39)
      sendLatchCrc    := (bitCnt === 39)
      sendIsDone      := (bitCnt >= 46)

      when(sendIsDone) {
        cmdOeR  := False
        cmdOutR := True
        when(respExp) {
          bitCnt     := 0
          timeoutCnt := 0
          cmdTimeoutFlag := False
          crcClear   := True
          state      := S_WAIT
        }.otherwise {
          state := S_DONE
        }
      }
    }
  }.elsewhen(state === S_WAIT) {
    when(io.clkEn) {
      when(!io.cmdIn) {
        rxShift := B(0, 136 bits)
        rxShift(135) := False
        bitCnt  := 1
        state   := S_RECV
      }.otherwise {
        timeoutCnt := timeoutCnt + 1
        when(timeoutCnt === 1023) {
          cmdTimeoutFlag := True
        }
        when(cmdTimeoutFlag) {
          cmdTimeoutR := True
          cmdDoneR    := True
          state       := S_IDLE
        }
      }
    }
  }.elsewhen(state === S_RECV) {
    when(io.clkEn) {
      rxShift := rxShift(134 downto 0) ## io.cmdIn
      bitCnt  := bitCnt + 1

      when(!respLong) {
        when(bitCnt >= 1 && bitCnt <= 39) {
          crcEn  := True
          crcBit := io.cmdIn
        }
      }

      when(!respLong && bitCnt === 47) {
        state := S_DONE
      }.elsewhen(respLong && bitCnt === 135) {
        state := S_DONE
      }
    }
  }.elsewhen(state === S_DONE) {
    when(!respLong && respExp) {
      respStatusR := rxShift(39 downto 8)
      when(crcOut =/= rxShift(7 downto 1)) {
        cmdCrcErrR := True
      }
    }.elsewhen(respLong) {
      respDataR := rxShift(127 downto 0)
    }
    cmdDoneR := True
    state    := S_IDLE
  }
}
