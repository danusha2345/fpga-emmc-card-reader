package emmcreader

import spinal.core._

// Write FIFO buffer (8192 bytes = 16 banks x 512)
// Split into 2 halves (2x 4096 bytes = 2x 2DPB) to avoid Gowin PnR
// routing degradation that causes bit errors at specific BRAM addresses.
// Previous: single mem[0:8191] (4 DPB) had marginal routing — bit 4 flips.
//
// Port A: eMMC read-only (reads data to write to card)
// Port B: UART write-only (receives data from PC)
class SectorBufWr extends Component {
  val io = new Bundle {
    // Port A (eMMC read side)
    val rdBank = in  UInt(4 bits)
    val rdAddr = in  UInt(9 bits)
    val rdData = out Bits(8 bits)

    // Port B (UART write side)
    val wrBank = in  UInt(4 bits)
    val wrAddr = in  UInt(9 bits)
    val wrData = in  Bits(8 bits)
    val wrEn   = in  Bool()
  }

  // Split: bank[3] selects half, bank[2:0]+addr[8:0] = 12-bit address within half
  val halfSelRd = io.rdBank(3)
  val halfSelWr = io.wrBank(3)

  val halfRdAddr = (io.rdBank(2 downto 0) ## io.rdAddr.asBits).asUInt
  val halfWrAddr = (io.wrBank(2 downto 0) ## io.wrAddr.asBits).asUInt

  // Half 0: banks 0-7 (4096 bytes, 2 DPB)
  val memLo = Mem(Bits(8 bits), 4096)
  val rdDataLo = memLo.readSync(halfRdAddr)
  memLo.write(
    address = halfWrAddr,
    data    = io.wrData,
    enable  = io.wrEn && !halfSelWr
  )

  // Half 1: banks 8-15 (4096 bytes, 2 DPB)
  val memHi = Mem(Bits(8 bits), 4096)
  val rdDataHi = memHi.readSync(halfRdAddr)
  memHi.write(
    address = halfWrAddr,
    data    = io.wrData,
    enable  = io.wrEn && halfSelWr
  )

  // Output mux (registered half_sel for timing)
  val halfSelRdR = RegNext(halfSelRd)
  io.rdData := Mux(halfSelRdR, rdDataHi, rdDataLo)
}
