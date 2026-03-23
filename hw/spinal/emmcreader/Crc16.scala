package emmcreader

import spinal.core._

// CRC-16 CCITT for eMMC DAT lines
// Polynomial: x^16 + x^12 + x^5 + 1 (0x1021)
// Processes 1 bit per clock cycle (serial LFSR)
class Crc16 extends Component {
  val io = new Bundle {
    val clear   = in  Bool()
    val enable  = in  Bool()
    val bitIn   = in  Bool()
    val crcOut  = out Bits(16 bits)
  }

  val crc = Reg(Bits(16 bits)) init 0

  val feedback = crc(15) ^ io.bitIn

  when(io.clear) {
    crc := 0
  }.elsewhen(io.enable) {
    crc(15) := crc(14)
    crc(14) := crc(13)
    crc(13) := crc(12)
    crc(12) := crc(11) ^ feedback
    crc(11) := crc(10)
    crc(10) := crc(9)
    crc(9)  := crc(8)
    crc(8)  := crc(7)
    crc(7)  := crc(6)
    crc(6)  := crc(5)
    crc(5)  := crc(4) ^ feedback
    crc(4)  := crc(3)
    crc(3)  := crc(2)
    crc(2)  := crc(1)
    crc(1)  := crc(0)
    crc(0)  := feedback
  }

  io.crcOut := crc
}

object Crc16Verilog extends App {
  SpinalConfig(
    targetDirectory = "generated",
    defaultConfigForClockDomains = ClockDomainConfig(
      resetKind = ASYNC,
      resetActiveLevel = LOW
    )
  ).generateVerilog(new Crc16).printPruned()
}
