package emmcreader

import spinal.core._

// CRC-7 for eMMC CMD line
// Polynomial: x^7 + x^3 + 1 (0x09)
// Processes 1 bit per clock cycle (serial LFSR)
class Crc7 extends Component {
  val io = new Bundle {
    val clear   = in  Bool()
    val enable  = in  Bool()
    val bitIn   = in  Bool()
    val crcOut  = out Bits(7 bits)
  }

  val crc = Reg(Bits(7 bits)) init 0

  val feedback = crc(6) ^ io.bitIn

  when(io.clear) {
    crc := 0
  }.elsewhen(io.enable) {
    crc(6) := crc(5)
    crc(5) := crc(4)
    crc(4) := crc(3)
    crc(3) := crc(2) ^ feedback
    crc(2) := crc(1)
    crc(1) := crc(0)
    crc(0) := feedback
  }

  io.crcOut := crc
}

object Crc7Verilog extends App {
  SpinalConfig(
    targetDirectory = "generated",
    defaultConfigForClockDomains = ClockDomainConfig(
      resetKind = ASYNC,
      resetActiveLevel = LOW
    )
  ).generateVerilog(new Crc7).printPruned()
}
