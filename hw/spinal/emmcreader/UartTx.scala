package emmcreader

import spinal.core._

// UART Transmitter - 8N1 format
// Runtime-switchable clks_per_bit for baud rate changes without re-synthesis
case class UartTxConfig(clkFreq: Int = 60000000, baudRate: Int = 3000000)

class UartTx(config: UartTxConfig = UartTxConfig()) extends Component {
  val io = new Bundle {
    val dataIn      = in  Bits(8 bits)
    val dataValid   = in  Bool()
    val clksPerBit  = in  Bits(8 bits)   // Runtime override; 0 = use compile-time default
    val tx          = out Bool()
    val busy        = out Bool()
  }

  val defaultCpb = config.clkFreq / config.baudRate
  val activeCpb = UInt(8 bits)
  activeCpb := Mux(io.clksPerBit =/= 0, io.clksPerBit.asUInt, U(defaultCpb, 8 bits))

  // FSM states
  val sIdle  = B"00"
  val sStart = B"01"
  val sData  = B"10"
  val sStop  = B"11"

  val state    = Reg(Bits(2 bits)) init 0
  val clkCnt   = Reg(UInt(8 bits)) init 0
  val bitIdx   = Reg(UInt(3 bits)) init 0
  val shiftReg = Reg(Bits(8 bits)) init 0
  val txReg    = Reg(Bool()) init True

  io.busy := (state =/= sIdle)
  io.tx   := txReg

  when(state === sIdle) {
    txReg   := True
    clkCnt  := 0
    bitIdx  := 0
    when(io.dataValid) {
      shiftReg := io.dataIn
      state    := sStart
    }
  }.elsewhen(state === sStart) {
    txReg := False   // start bit
    when(clkCnt === (activeCpb - 1)) {
      clkCnt := 0
      state  := sData
    }.otherwise {
      clkCnt := clkCnt + 1
    }
  }.elsewhen(state === sData) {
    txReg := shiftReg(0)   // LSB first
    when(clkCnt === (activeCpb - 1)) {
      clkCnt   := 0
      shiftReg := B"0" ## shiftReg(7 downto 1)
      when(bitIdx === 7) {
        state := sStop
      }.otherwise {
        bitIdx := bitIdx + 1
      }
    }.otherwise {
      clkCnt := clkCnt + 1
    }
  }.elsewhen(state === sStop) {
    txReg := True   // stop bit
    when(clkCnt === (activeCpb - 1)) {
      clkCnt := 0
      state  := sIdle
    }.otherwise {
      clkCnt := clkCnt + 1
    }
  }
}
