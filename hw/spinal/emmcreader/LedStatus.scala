package emmcreader

import spinal.core._

// LED Status Controller for Tang Nano 9K
// LED[0] = eMMC Activity (pulse stretched)
// LED[1] = UART Activity (pulse stretched)
// LED[2] = eMMC Ready (direct)
// LED[3] = Error (direct)
// LED[4] = Free (always off)
// LED[5] = Heartbeat (~1 Hz blink)
// All LEDs are active LOW

class LedStatus extends Component {
  noIoPrefix()
  setDefinitionName("led_status")

  val io = new Bundle {
    val emmcActive = in  Bool()
    val uartActive = in  Bool()
    val emmcReady  = in  Bool()
    val error      = in  Bool()
    val ledN       = out Bits(6 bits)
  }

  // Heartbeat counter: 60 MHz / 2^27 ~ 0.45 Hz toggle -> ~2.2s blink period
  val hbCnt = Reg(UInt(27 bits)) init 0
  hbCnt := hbCnt + 1

  // UART activity pulse stretcher (~70ms at 60 MHz)
  val uartStretch       = Reg(UInt(22 bits)) init 0
  val uartStretchActive = Reg(Bool()) init False
  when(io.uartActive) {
    uartStretch       := U((1 << 22) - 1, 22 bits)   // all 1s
    uartStretchActive := True
  }.elsewhen(uartStretchActive) {
    uartStretch := uartStretch - 1
    when(uartStretch === 1) {
      uartStretchActive := False
    }
  }

  // eMMC activity pulse stretcher
  val emmcStretch       = Reg(UInt(22 bits)) init 0
  val emmcStretchActive = Reg(Bool()) init False
  when(io.emmcActive) {
    emmcStretch       := U((1 << 22) - 1, 22 bits)
    emmcStretchActive := True
  }.elsewhen(emmcStretchActive) {
    emmcStretch := emmcStretch - 1
    when(emmcStretch === 1) {
      emmcStretchActive := False
    }
  }

  // Active low: 0 = LED on, 1 = LED off
  io.ledN(0) := ~emmcStretchActive
  io.ledN(1) := ~uartStretchActive
  io.ledN(2) := ~io.emmcReady
  io.ledN(3) := ~io.error
  io.ledN(4) := True                    // off (free)
  io.ledN(5) := ~hbCnt(26)              // heartbeat
}
