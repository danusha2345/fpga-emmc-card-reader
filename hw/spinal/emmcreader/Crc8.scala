package emmcreader

import spinal.core._

// CRC-8 for UART protocol
// Polynomial: x^8 + x^2 + x + 1 (0x07)
// Processes 1 byte per clock cycle (parallel XOR matrix)
class Crc8 extends Component {
  val io = new Bundle {
    val clear   = in  Bool()
    val enable  = in  Bool()
    val dataIn  = in  Bits(8 bits)
    val crcOut  = out Bits(8 bits)
  }

  val crc = Reg(Bits(8 bits)) init 0

  // Parallel CRC-8: XOR matrix derived from polynomial 0x07
  val d = io.dataIn
  val c = crc
  val nextCrc = Bits(8 bits)

  nextCrc(0) := c(0) ^ c(6) ^ c(7) ^ d(0) ^ d(6) ^ d(7)
  nextCrc(1) := c(0) ^ c(1) ^ c(6) ^ d(0) ^ d(1) ^ d(6)
  nextCrc(2) := c(0) ^ c(1) ^ c(2) ^ c(6) ^ d(0) ^ d(1) ^ d(2) ^ d(6)
  nextCrc(3) := c(1) ^ c(2) ^ c(3) ^ c(7) ^ d(1) ^ d(2) ^ d(3) ^ d(7)
  nextCrc(4) := c(2) ^ c(3) ^ c(4) ^ d(2) ^ d(3) ^ d(4)
  nextCrc(5) := c(3) ^ c(4) ^ c(5) ^ d(3) ^ d(4) ^ d(5)
  nextCrc(6) := c(4) ^ c(5) ^ c(6) ^ d(4) ^ d(5) ^ d(6)
  nextCrc(7) := c(5) ^ c(6) ^ c(7) ^ d(5) ^ d(6) ^ d(7)

  when(io.clear) {
    crc := 0
  }.elsewhen(io.enable) {
    crc := nextCrc
  }

  io.crcOut := crc
}

object Crc8Verilog extends App {
  SpinalConfig(
    targetDirectory = "generated",
    defaultConfigForClockDomains = ClockDomainConfig(
      resetKind = ASYNC,
      resetActiveLevel = LOW
    )
  ).generateVerilog(new Crc8).printPruned()
}
