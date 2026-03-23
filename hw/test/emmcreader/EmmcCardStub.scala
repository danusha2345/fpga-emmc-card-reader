package emmcreader

import spinal.core._
import spinal.core.sim._

// Software model of eMMC card for simulation
// Drives CMD and DAT0 lines in response to host commands
class EmmcCardStub(
  cmdLine: Bool,   // CMD bidirectional (use cmdOe/cmdOut/cmdIn)
  datLine: Bool,   // DAT0 line
  clkEn: Bool      // eMMC clock enable strobe
) {
  var rca: Int = 0x0001
  var ocr: Int = 0xC0FF8080  // ready + sector mode + voltage

  // Compute CRC-7 for a sequence of bits
  def crc7(bits: Seq[Boolean]): Int = {
    var crc = 0
    for (b <- bits) {
      val fb = ((crc >> 6) & 1) ^ (if (b) 1 else 0)
      crc = ((crc << 1) & 0x7F)
      if (fb != 0) crc ^= 0x09
    }
    crc
  }

  // Convert bytes to bit sequence (MSB first)
  def bytesToBits(bytes: Seq[Int]): Seq[Boolean] = {
    bytes.flatMap { b =>
      (7 to 0 by -1).map(i => ((b >> i) & 1) == 1)
    }
  }

  // Build R1 response (48 bits): start(0) + tx(0) + cmdIndex(6) + status(32) + crc(7) + end(1)
  def buildR1(cmdIdx: Int, status: Int = 0x00000900): Seq[Boolean] = {
    val dataBits = Seq(false, false) ++  // start + transmit
      (5 to 0 by -1).map(i => ((cmdIdx >> i) & 1) == 1) ++  // cmd index
      (31 to 0 by -1).map(i => ((status >> i) & 1) == 1)    // status
    val crc = crc7(dataBits)
    dataBits ++ (6 to 0 by -1).map(i => ((crc >> i) & 1) == 1) ++ Seq(true)  // crc + end
  }

  // Build R3 response (48 bits): like R1 but cmdIndex=0x3F, no valid CRC
  def buildR3(ocrVal: Int): Seq[Boolean] = {
    val dataBits = Seq(false, false) ++
      Seq(true, true, true, true, true, true) ++   // 0x3F
      (31 to 0 by -1).map(i => ((ocrVal >> i) & 1) == 1)
    val crc = 0x7F   // R3 has all-1 CRC (no valid CRC)
    dataBits ++ (6 to 0 by -1).map(i => ((crc >> i) & 1) == 1) ++ Seq(true)
  }

  // Build R2 response (136 bits): start(0) + tx(0) + 111111 + 128-bit CID/CSD + end(1)
  def buildR2(data128: BigInt): Seq[Boolean] = {
    Seq(false, false) ++
      Seq(true, true, true, true, true, true) ++
      (127 to 0 by -1).map(i => data128.testBit(i)) ++
      Seq(true)
  }
}

// Helper to compute CRC-16 CCITT for DAT0 data
object Crc16Helper {
  def compute(bits: Seq[Boolean]): Int = {
    var crc = 0
    for (b <- bits) {
      val fb = ((crc >> 15) & 1) ^ (if (b) 1 else 0)
      crc = ((crc << 1) & 0xFFFF)
      if (fb != 0) crc ^= 0x1021
    }
    crc
  }

  def bytesToBitsMsb(bytes: Seq[Int]): Seq[Boolean] = {
    bytes.flatMap(b => (7 to 0 by -1).map(i => ((b >> i) & 1) == 1))
  }
}
