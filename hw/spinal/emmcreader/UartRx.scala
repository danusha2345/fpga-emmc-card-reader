package emmcreader

import spinal.core._

// UART Receiver - 8N1 format
// Runtime-switchable clks_per_bit for baud rate changes without re-synthesis
// Double-FF synchronizer for metastability protection

class UartRx(config: UartTxConfig = UartTxConfig()) extends Component {
  val io = new Bundle {
    val rx         = in  Bool()
    val clksPerBit = in  Bits(8 bits)   // Runtime override; 0 = use compile-time default
    val dataOut    = out Bits(8 bits)
    val dataValid  = out Bool()
    val frameErr   = out Bool()
  }

  val defaultCpb = config.clkFreq / config.baudRate
  val activeCpb = UInt(8 bits)
  activeCpb := Mux(io.clksPerBit =/= 0, io.clksPerBit.asUInt, U(defaultCpb, 8 bits))
  val halfCpb = activeCpb |>> 1   // activeCpb >> 1

  // FSM states
  val sIdle  = B"00"
  val sStart = B"01"
  val sData  = B"10"
  val sStop  = B"11"

  // Double-flop synchronizer for RX
  val rxSync1 = Reg(Bool()) init True
  val rxSync2 = Reg(Bool()) init True
  rxSync1 := io.rx
  rxSync2 := rxSync1
  val rxS = rxSync2

  val state    = Reg(Bits(2 bits)) init 0
  val clkCnt   = Reg(UInt(8 bits)) init 0
  val bitIdx   = Reg(UInt(3 bits)) init 0
  val shiftReg = Reg(Bits(8 bits)) init 0
  val dataOut  = Reg(Bits(8 bits)) init 0
  val dataValid = Reg(Bool()) init False
  val frameErr  = Reg(Bool()) init False

  io.dataOut   := dataOut
  io.dataValid := dataValid
  io.frameErr  := frameErr

  // Default: clear pulses
  dataValid := False
  frameErr  := False

  when(state === sIdle) {
    clkCnt := 0
    bitIdx := 0
    when(!rxS) {   // start bit detected
      state := sStart
    }
  }.elsewhen(state === sStart) {
    when(clkCnt === (halfCpb - 1)) {
      clkCnt := 0
      when(!rxS) {   // still low at midpoint
        state := sData
      }.otherwise {
        state := sIdle   // false start
      }
    }.otherwise {
      clkCnt := clkCnt + 1
    }
  }.elsewhen(state === sData) {
    when(clkCnt === (activeCpb - 1)) {
      clkCnt   := 0
      shiftReg := rxS ## shiftReg(7 downto 1)   // LSB first
      when(bitIdx === 7) {
        state := sStop
      }.otherwise {
        bitIdx := bitIdx + 1
      }
    }.otherwise {
      clkCnt := clkCnt + 1
    }
  }.elsewhen(state === sStop) {
    when(clkCnt === (activeCpb - 1)) {
      clkCnt := 0
      when(rxS) {   // valid stop bit
        dataOut   := shiftReg
        dataValid := True
      }.otherwise {
        frameErr := True
      }
      state := sIdle
    }.otherwise {
      clkCnt := clkCnt + 1
    }
  }
}
