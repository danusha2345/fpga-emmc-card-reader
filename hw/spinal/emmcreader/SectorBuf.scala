package emmcreader

import spinal.core._

// Dual-port sector buffer (1024 bytes = 2x512 for ping-pong)
// Port A: eMMC side (read/write)
// Port B: UART side (read/write)
// Write-through mode: on write, rdata = wdata (same cycle via NBA)
// Note: 1024 bytes fits 1 DPB at half-capacity — safe for Gowin PnR.
class SectorBuf extends Component {
  val io = new Bundle {
    // Port A (eMMC side)
    val bufSelA = in  Bits(2 bits)
    val addrA   = in  UInt(9 bits)
    val wdataA  = in  Bits(8 bits)
    val weA     = in  Bool()
    val rdataA  = out Bits(8 bits)

    // Port B (UART side)
    val bufSelB = in  Bits(2 bits)
    val addrB   = in  UInt(9 bits)
    val wdataB  = in  Bits(8 bits)
    val weB     = in  Bool()
    val rdataB  = out Bits(8 bits)
  }

  // 1024 bytes BRAM (2 banks x 512)
  val mem = Mem(Bits(8 bits), 1024)

  // Full addresses: {buf_sel[0], addr[8:0]} = 10-bit address
  val fullAddrA = (io.bufSelA(0) ## io.addrA.asBits).asUInt
  val fullAddrB = (io.bufSelB(0) ## io.addrB.asBits).asUInt

  // Port A - write-through: on write output new data; on read output mem
  io.rdataA := mem.readWriteSync(
    address = fullAddrA,
    data    = io.wdataA,
    enable  = True,
    write   = io.weA
  )

  // Port B - write-through
  io.rdataB := mem.readWriteSync(
    address = fullAddrB,
    data    = io.wdataB,
    enable  = True,
    write   = io.weB
  )
}
