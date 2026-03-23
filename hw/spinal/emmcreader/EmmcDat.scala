package emmcreader

import spinal.core._

// eMMC DAT Read/Write Handler (1-bit and 4-bit SDR mode)
// 1-bit: start bit → 4096 data bits → 16 CRC bits → end bit (on DAT0 only)
// 4-bit: start bit → 1024 clocks (nibbles) → 4×16 CRC bits → end bit (on DAT[3:0])
// Mode selected at runtime via busWidth4 input.
class EmmcDat extends Component {
  val io = new Bundle {
    val clkEn      = in  Bool()
    // Read control
    val rdStart    = in  Bool()
    val rdDone     = out Bool()
    val rdCrcErr   = out Bool()
    // Write control
    val wrStart    = in  Bool()
    val wrDone     = out Bool()
    val wrCrcErr   = out Bool()
    // Buffer interface - read path (write to buffer)
    val bufWrData  = out Bits(8 bits)
    val bufWrAddr  = out UInt(9 bits)
    val bufWrEn    = out Bool()
    // Buffer interface - write path (read from buffer)
    val bufRdAddr  = out UInt(9 bits)
    val bufRdData  = in  Bits(8 bits)
    // Physical DAT lines (active width depends on busWidth4)
    val datOut     = out Bits(4 bits)
    val datOe      = out Bool()
    val datIn      = in  Bits(4 bits)
    // Runtime bus width select
    val busWidth4  = in  Bool()
    // Debug
    val dbgState   = out Bits(4 bits)
  }

  // FSM states
  val S_IDLE          = B(0, 4 bits)
  val S_RD_WAIT_START = B(1, 4 bits)
  val S_RD_DATA       = B(2, 4 bits)
  val S_RD_CRC        = B(3, 4 bits)
  val S_RD_END        = B(4, 4 bits)
  val S_WR_PREFETCH   = B(5, 4 bits)
  val S_WR_START      = B(6, 4 bits)
  val S_WR_DATA       = B(7, 4 bits)
  val S_WR_CRC        = B(8, 4 bits)
  val S_WR_END        = B(9, 4 bits)
  val S_WR_CRC_STAT   = B(10, 4 bits)
  val S_WR_BUSY       = B(11, 4 bits)
  val S_WR_CRC_WAIT   = B(12, 4 bits)
  val S_WR_PREFETCH2  = B(13, 4 bits)

  val state        = Reg(Bits(4 bits)) init 0
  val bitCnt       = Reg(UInt(13 bits)) init 0
  val timeoutCnt   = Reg(UInt(16 bits)) init 0
  val timeoutFlag  = Reg(Bool()) init False
  val byteAcc      = Reg(Bits(8 bits)) init 0
  val bitInByte    = Reg(UInt(3 bits)) init 0
  val byteComplete = Reg(Bool()) init False

  val wrByteReg    = Reg(Bits(8 bits)) init 0
  val wrBitIdx     = Reg(UInt(3 bits)) init 0

  val rdDoneR      = Reg(Bool()) init False
  val rdCrcErrR    = Reg(Bool()) init False
  val wrDoneR      = Reg(Bool()) init False
  val wrCrcErrR    = Reg(Bool()) init False
  val bufWrDataR   = Reg(Bits(8 bits)) init 0
  val bufWrAddrR   = Reg(UInt(9 bits)) init 0
  val bufWrEnR     = Reg(Bool()) init False
  val bufRdAddrR   = Reg(UInt(9 bits)) init 0
  val datOutR      = Reg(Bits(4 bits)) init B"1111"
  val datOeR       = Reg(Bool()) init False

  // 4-bit mode: nibble phase (0=high nibble, 1=low nibble)
  val nibblePhase  = Reg(Bool()) init False

  io.dbgState  := state
  io.rdDone    := rdDoneR
  io.rdCrcErr  := rdCrcErrR
  io.wrDone    := wrDoneR
  io.wrCrcErr  := wrCrcErrR
  io.bufWrData := bufWrDataR
  io.bufWrAddr := bufWrAddrR
  io.bufWrEn   := bufWrEnR
  io.bufRdAddr := bufRdAddrR
  io.datOut    := datOutR
  io.datOe     := datOeR

  // ============================================================
  // Read CRC-16: 4 instances (only [0] used in 1-bit mode)
  // ============================================================
  val rdCrcClear = Reg(Bool()) init True
  val rdCrcEn    = Reg(Bool()) init False

  val rdCrcs = Seq.fill(4)(new Crc16)
  for (i <- 0 until 4) {
    rdCrcs(i).io.clear  := rdCrcClear
    rdCrcs(i).io.enable := rdCrcEn
    rdCrcs(i).io.bitIn  := io.datIn(i)
  }

  // Per-line received CRC (for 4-bit CRC verification)
  val crcRecvArr = Vec(Reg(Bits(16 bits)) init 0, 4)
  // Legacy single crcRecv for 1-bit mode
  val crcRecv    = Reg(Bits(16 bits)) init 0

  // ============================================================
  // Write CRC-16: 4 instances (only [0] used in 1-bit mode)
  // ============================================================
  val wrCrcClear = Reg(Bool()) init True
  val wrCrcEn    = Reg(Bool()) init False
  val wrCrcBit   = Reg(Bits(4 bits)) init B"1111"

  val wrCrcs = Seq.fill(4)(new Crc16)
  for (i <- 0 until 4) {
    wrCrcs(i).io.clear  := wrCrcClear
    wrCrcs(i).io.enable := wrCrcEn
    wrCrcs(i).io.bitIn  := wrCrcBit(i)
  }

  // Per-line write CRC shift registers (for 4-bit CRC transmission)
  val wrCrcShiftArr = Vec(Reg(Bits(16 bits)) init 0, 4)
  // Legacy single shift reg for 1-bit mode
  val wrCrcShift   = Reg(Bits(16 bits)) init 0

  val crcStatusReg = Reg(Bits(3 bits)) init 0
  val crcStatusCnt = Reg(UInt(3 bits)) init 0

  // Default pulse clears
  rdDoneR    := False
  rdCrcErrR  := False
  wrDoneR    := False
  wrCrcErrR  := False
  bufWrEnR   := False
  rdCrcClear := False
  rdCrcEn    := False
  wrCrcClear := False
  wrCrcEn    := False

  when(state === S_IDLE) {
    datOeR  := False
    datOutR := B"1111"
    when(io.rdStart) {
      rdCrcClear  := True
      timeoutCnt  := 0
      timeoutFlag := False
      state       := S_RD_WAIT_START
    }.elsewhen(io.wrStart) {
      wrCrcClear := True
      bufRdAddrR := 0
      bitCnt     := 0
      state      := S_WR_PREFETCH
    }

  }.elsewhen(state === S_RD_WAIT_START) {
    // Wait for start bit on DAT0
    when(io.clkEn) {
      when(!io.datIn(0)) {
        bitCnt       := 0
        bitInByte    := 0
        byteComplete := False
        bufWrAddrR   := U"9'h1FF"
        nibblePhase  := False
        state        := S_RD_DATA
      }.otherwise {
        timeoutCnt := timeoutCnt + 1
        when(timeoutCnt === U"16'hFFFE") {
          timeoutFlag := True
        }
        when(timeoutFlag) {
          rdCrcErrR := True
          rdDoneR   := True
          state     := S_IDLE
        }
      }
    }

  }.elsewhen(state === S_RD_DATA) {
    when(io.clkEn) {
      rdCrcEn := True

      when(io.busWidth4) {
        // 4-bit mode: 2 clocks per byte (high nibble, low nibble)
        when(!nibblePhase) {
          // Phase 0: capture high nibble
          byteAcc(7) := io.datIn(3)
          byteAcc(6) := io.datIn(2)
          byteAcc(5) := io.datIn(1)
          byteAcc(4) := io.datIn(0)
          nibblePhase := True
        }.otherwise {
          // Phase 1: capture low nibble → byte complete
          byteAcc(3) := io.datIn(3)
          byteAcc(2) := io.datIn(2)
          byteAcc(1) := io.datIn(1)
          byteAcc(0) := io.datIn(0)
          nibblePhase  := False
          byteComplete := True
          bufWrDataR   := byteAcc(7 downto 4) ## io.datIn
          bufWrEnR     := True
          bufWrAddrR   := bufWrAddrR + 1
        }

        bitCnt := bitCnt + 1
        when(bitCnt === 1023) {
          bitCnt  := 0
          for (i <- 0 until 4) crcRecvArr(i) := B(0, 16 bits)
          state   := S_RD_CRC
        }
      }.otherwise {
        // 1-bit mode: original logic on datIn(0)
        byteAcc      := byteAcc(6 downto 0) ## io.datIn(0)
        bitInByte    := bitInByte + 1
        byteComplete := (bitInByte === 6)
        bufWrDataR   := byteAcc(6 downto 0) ## io.datIn(0)
        bufWrEnR     := byteComplete
        when(byteComplete) {
          bufWrAddrR := bufWrAddrR + 1
        }

        bitCnt := bitCnt + 1
        when(bitCnt === 4095) {
          bitCnt  := 0
          crcRecv := B(0, 16 bits)
          state   := S_RD_CRC
        }
      }
    }

  }.elsewhen(state === S_RD_CRC) {
    when(io.clkEn) {
      when(io.busWidth4) {
        // 4-bit mode: receive CRC on each line independently
        for (i <- 0 until 4) {
          crcRecvArr(i) := crcRecvArr(i)(14 downto 0) ## io.datIn(i)
        }
      }.otherwise {
        // 1-bit mode: receive CRC on DAT0 only
        crcRecv := crcRecv(14 downto 0) ## io.datIn(0)
      }
      bitCnt := bitCnt + 1
      when(bitCnt === 15) {
        state := S_RD_END
      }
    }

  }.elsewhen(state === S_RD_END) {
    when(io.clkEn) {
      when(io.busWidth4) {
        // Check all 4 CRC lanes
        val anyMismatch = (0 until 4).map(i => crcRecvArr(i) =/= rdCrcs(i).io.crcOut).reduce(_ || _)
        when(anyMismatch) {
          rdCrcErrR := True
        }
      }.otherwise {
        when(crcRecv =/= rdCrcs(0).io.crcOut) {
          rdCrcErrR := True
        }
      }
      rdDoneR := True
      state   := S_IDLE
    }

  }.elsewhen(state === S_WR_PREFETCH) {
    state := S_WR_PREFETCH2

  }.elsewhen(state === S_WR_PREFETCH2) {
    wrByteReg  := io.bufRdData
    bufRdAddrR := 1
    state      := S_WR_START

  }.elsewhen(state === S_WR_START) {
    when(io.clkEn) {
      wrBitIdx    := 7
      datOeR      := True
      datOutR     := B"0000"   // start bit on all lines
      bitCnt      := 0
      nibblePhase := False
      state       := S_WR_DATA
    }

  }.elsewhen(state === S_WR_DATA) {
    when(io.clkEn) {
      datOeR := True

      when(io.busWidth4) {
        // 4-bit mode: 2 clocks per byte
        when(!nibblePhase) {
          // Phase 0: output high nibble
          datOutR := wrByteReg(7) ## wrByteReg(6) ## wrByteReg(5) ## wrByteReg(4)
          wrCrcBit := wrByteReg(7) ## wrByteReg(6) ## wrByteReg(5) ## wrByteReg(4)
          wrCrcEn  := True
          nibblePhase := True
        }.otherwise {
          // Phase 1: output low nibble, load next byte
          datOutR := wrByteReg(3) ## wrByteReg(2) ## wrByteReg(1) ## wrByteReg(0)
          wrCrcBit := wrByteReg(3) ## wrByteReg(2) ## wrByteReg(1) ## wrByteReg(0)
          wrCrcEn  := True
          nibblePhase := False
          wrByteReg  := io.bufRdData
          bufRdAddrR := bufRdAddrR + 1
        }

        bitCnt := bitCnt + 1
        when(bitCnt === 1023) {
          bitCnt := 0
          state  := S_WR_CRC_WAIT
        }
      }.otherwise {
        // 1-bit mode: original logic
        datOutR(0) := wrByteReg(7)
        datOutR(3 downto 1) := B"111"
        wrCrcBit(0) := wrByteReg(7)
        wrCrcBit(3 downto 1) := B"111"
        wrCrcEn := True

        when(wrBitIdx === 0) {
          wrByteReg  := io.bufRdData
          bufRdAddrR := bufRdAddrR + 1
          wrBitIdx   := 7
        }.otherwise {
          wrByteReg := wrByteReg(6 downto 0) ## B"0"
          wrBitIdx  := wrBitIdx - 1
        }

        bitCnt := bitCnt + 1
        when(bitCnt === 4095) {
          bitCnt := 0
          state  := S_WR_CRC_WAIT
        }
      }
    }

  }.elsewhen(state === S_WR_CRC_WAIT) {
    when(bitCnt(0)) {
      when(io.busWidth4) {
        for (i <- 0 until 4) wrCrcShiftArr(i) := wrCrcs(i).io.crcOut
      }.otherwise {
        wrCrcShift := wrCrcs(0).io.crcOut
      }
      bitCnt := 0
      state  := S_WR_CRC
    }.otherwise {
      bitCnt := bitCnt + 1
    }

  }.elsewhen(state === S_WR_CRC) {
    when(io.clkEn) {
      datOeR := True

      when(io.busWidth4) {
        // 4-bit mode: each line sends its own CRC
        for (i <- 0 until 4) {
          datOutR(i) := wrCrcShiftArr(i)(15)
          wrCrcShiftArr(i) := wrCrcShiftArr(i)(14 downto 0) ## B"0"
        }
      }.otherwise {
        // 1-bit mode: CRC on DAT0 only
        datOutR(0) := wrCrcShift(15)
        datOutR(3 downto 1) := B"111"
        wrCrcShift := wrCrcShift(14 downto 0) ## B"0"
      }

      bitCnt := bitCnt + 1
      when(bitCnt === 15) {
        state := S_WR_END
      }
    }

  }.elsewhen(state === S_WR_END) {
    when(io.clkEn) {
      datOutR      := B"1111"
      datOeR       := False
      crcStatusCnt := 0
      crcStatusReg := B(0, 3 bits)
      timeoutCnt   := 0
      timeoutFlag  := False
      state        := S_WR_CRC_STAT
    }

  }.elsewhen(state === S_WR_CRC_STAT) {
    // CRC status token is always on DAT0 only
    when(io.clkEn) {
      when(!io.datIn(0) && crcStatusCnt === 0) {
        crcStatusCnt := 1
      }.elsewhen(crcStatusCnt >= 1 && crcStatusCnt <= 3) {
        crcStatusReg := crcStatusReg(1 downto 0) ## io.datIn(0)
        crcStatusCnt := crcStatusCnt + 1
      }.elsewhen(crcStatusCnt > 3) {
        when(crcStatusReg === B"010") {
          state := S_WR_BUSY
        }.otherwise {
          wrCrcErrR := True
          wrDoneR   := True
          state     := S_IDLE
        }
      }.otherwise {
        timeoutCnt := timeoutCnt + 1
        when(timeoutCnt === U"16'hFFFE") {
          timeoutFlag := True
        }
        when(timeoutFlag) {
          wrCrcErrR := True
          wrDoneR   := True
          state     := S_IDLE
        }
      }
    }

  }.elsewhen(state === S_WR_BUSY) {
    // Busy poll on DAT0 only
    when(io.clkEn) {
      when(crcStatusCnt < 7) {
        crcStatusCnt := crcStatusCnt + 1
      }.elsewhen(io.datIn(0)) {
        wrDoneR := True
        state   := S_IDLE
      }.otherwise {
        timeoutCnt := timeoutCnt + 1
        when(timeoutCnt === U"16'hFFFE") {
          timeoutFlag := True
        }
        when(timeoutFlag) {
          wrCrcErrR := True
          wrDoneR   := True
          state     := S_IDLE
        }
      }
    }
  }
}
