package emmcreader

import spinal.core._

// FT232H Async 245 FIFO PHY
// Provides byte-level interface identical to UartRx/UartTx for drop-in replacement.
//
// Timing at 60 MHz (16.67ns period):
//   Read cycle:  8 clocks — RD# low for 3 clocks (50ns), sample at 3rd, +4 recovery
//   Write cycle: 5 clocks — WR# low for 3 clocks (50ns), +1 data setup
//   Raw throughput: ~7.5 MB/s read, ~12 MB/s write (limited by USB 2.0 HS to ~8 MB/s)
//
// Recovery timing (read): after RD# de-asserted, RXF# needs 25ns (t4) to update,
//   then 2 clocks for metastability sync. Total: ~4 clocks before rxfSync2 is valid.
//   Without this, a phantom read occurs when the FT232H buffer empties between
//   USB transfers (e.g., packets > 512 bytes split across two USB bulk transfers).
//
// FT245 protocol:
//   READ:  RXF# low -> assert RD# low -> hold 3 clk -> sample D[7:0] -> deassert RD# -> 4 clk recovery
//   WRITE: TXE# low -> drive D[7:0] -> assert WR# low -> hold 3 clk -> deassert WR#

class Ft245Fifo extends Component {
  noIoPrefix()
  setDefinitionName("ft245_fifo")

  val io = new Bundle {
    // FT232H physical pins (active-low control)
    val fifoDataRead  = in  Bits(8 bits)   // D[7:0] input (active during read)
    val fifoDataWrite = out Bits(8 bits)   // D[7:0] output (active during write)
    val fifoDataOe    = out Bool()         // D[7:0] output enable (high = FPGA drives bus)
    val fifoRxfN      = in  Bool()         // RXF# : FT has data to read (active low)
    val fifoTxeN      = in  Bool()         // TXE# : FT has room for write (active low)
    val fifoRdN       = out Bool()         // RD#  : read strobe (active low)
    val fifoWrN       = out Bool()         // WR#  : write strobe (active low)

    // Byte interface (matches UartRx/UartTx contract)
    val rxDataOut   = out Bits(8 bits)     // received byte from FT
    val rxDataValid = out Bool()           // pulse: rxDataOut is valid
    val txDataIn    = in  Bits(8 bits)     // byte to send to FT
    val txDataValid = in  Bool()           // pulse: latch txDataIn
    val txBusy      = out Bool()           // high while write cycle in progress
    val rxSuppress  = in  Bool()           // suppress RX reads (during TX response)
  }

  // 2-stage metastability sync on async inputs from FT232H
  val rxfSync1 = Reg(Bool()) init True
  val rxfSync2 = Reg(Bool()) init True
  rxfSync1 := io.fifoRxfN
  rxfSync2 := rxfSync1

  val txeSync1 = Reg(Bool()) init True
  val txeSync2 = Reg(Bool()) init True
  txeSync1 := io.fifoTxeN
  txeSync2 := txeSync1

  val rxfActive = !rxfSync2   // data available from FT
  val txeActive = !txeSync2   // room in FT TX buffer

  // FSM
  val S_IDLE    = B"00"
  val S_READ    = B"01"
  val S_WRITE   = B"10"

  val state    = Reg(Bits(2 bits)) init 0
  val cycleCnt = Reg(UInt(3 bits)) init 0

  // TX hold register
  val txPending = Reg(Bool()) init False
  val txHold    = Reg(Bits(8 bits)) init 0

  // Latch TX data on txDataValid pulse
  when(io.txDataValid && !txPending) {
    txPending := True
    txHold    := io.txDataIn
  }

  // Output defaults
  val rdNR       = Reg(Bool()) init True
  val wrNR       = Reg(Bool()) init True
  val dataOeR    = Reg(Bool()) init False
  val dataWriteR = Reg(Bits(8 bits)) init 0
  val rxDataR    = Reg(Bits(8 bits)) init 0
  val rxValidR   = Reg(Bool()) init False

  io.fifoRdN       := rdNR
  io.fifoWrN       := wrNR
  io.fifoDataOe    := dataOeR
  io.fifoDataWrite := dataWriteR
  io.rxDataOut     := rxDataR
  io.rxDataValid   := rxValidR
  io.txBusy        := txPending

  // Default: clear pulse
  rxValidR := False

  when(state === S_IDLE) {
    rdNR    := True
    wrNR    := True
    dataOeR := False

    // Priority: TX first (to drain write buffer), then RX
    // rxSuppress: don't read while UartBridge is transmitting a response
    when(txPending && txeActive) {
      state      := S_WRITE
      cycleCnt   := 0
      dataOeR    := True
      dataWriteR := txHold
    }.elsewhen(rxfActive && !io.rxSuppress) {
      state    := S_READ
      cycleCnt := 0
      rdNR     := False   // assert RD# immediately
    }

  }.elsewhen(state === S_READ) {
    // Read cycle: RD# low for 3 clocks (50ns @ 60MHz), sample on 3rd, then 4 clk recovery
    // Recovery budget: 25ns for RXF# update (t4) + 2 clocks sync chain = 4 clocks total.
    // This prevents phantom reads when FT232H buffer empties between USB transfers.
    when(cycleCnt === 0) {
      // RD# already low from IDLE transition, 1st clock of RD# active
      cycleCnt := 1
    }.elsewhen(cycleCnt === 1) {
      // 2nd clock of RD# active, data propagating
      cycleCnt := 2
    }.elsewhen(cycleCnt === 2) {
      // 3rd clock of RD# active (50ns met), sample data, deassert RD#
      rxDataR  := io.fifoDataRead
      rxValidR := True
      rdNR     := True
      cycleCnt := 3
    }.elsewhen(cycleCnt <= 5) {
      // Recovery clocks 1-3: wait for RXF# sync chain to settle
      cycleCnt := cycleCnt + 1
    }.otherwise {
      // Recovery complete (4 clocks elapsed), return to idle
      state := S_IDLE
    }

  }.elsewhen(state === S_WRITE) {
    // Write cycle: WR# low for 3 clocks (50ns @ 60MHz), data driven from IDLE
    when(cycleCnt === 0) {
      wrNR     := False    // assert WR# (data already driven from IDLE)
      cycleCnt := 1
    }.elsewhen(cycleCnt === 1) {
      // WR# low, 2nd clock
      cycleCnt := 2
    }.elsewhen(cycleCnt === 2) {
      // WR# low, 3rd clock (50ns met)
      cycleCnt := 3
    }.otherwise {
      wrNR      := True    // deassert WR# -> FT latches data on this rising edge
      dataOeR   := False
      txPending := False
      state     := S_IDLE
    }
  }
}
