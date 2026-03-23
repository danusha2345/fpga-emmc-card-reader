package emmcreader

import spinal.core._

// BlackBox wrapper for Gowin rPLL primitive (src/pll.v)
// 27 MHz → 60 MHz, module name "pll" matches the Verilog module
class GowinPll extends BlackBox {
  val io = new Bundle {
    val clkin  = in  Bool()
    val clkout = out Bool()
    val lock   = out Bool()
  }
  noIoPrefix()
  setDefinitionName("pll")
}
