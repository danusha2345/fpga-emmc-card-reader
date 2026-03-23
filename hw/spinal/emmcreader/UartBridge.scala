package emmcreader

import spinal.core._

// UART Bridge - Command protocol handler
// Parses incoming commands from PC and sends responses
//
// PC -> FPGA: [0xAA] [CMD_ID] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]
// FPGA -> PC: [0x55] [CMD_ID] [STATUS] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]
//
// Timing-optimized: info shift register instead of indexed array,
// RX_EXEC split into RX_EXEC1/RX_EXEC2, payload down-counter.

case class UartBridgeConfig(clkFreq: Int = 60000000, baudRate: Int = 3000000, useFifo: Boolean = false)

class UartBridge(config: UartBridgeConfig = UartBridgeConfig()) extends Component {
  noIoPrefix()
  setDefinitionName(if (config.useFifo) "fifo_bridge" else "uart_bridge")

  val io = new Bundle {
    // UART pins (active when useFifo=false)
    val uartRxPin   = if (!config.useFifo) in  Bool() else null
    val uartTxPin   = if (!config.useFifo) out Bool() else null

    // FT245 FIFO pins (active when useFifo=true)
    val fifoDataRead  = if (config.useFifo) in  Bits(8 bits) else null
    val fifoDataWrite = if (config.useFifo) out Bits(8 bits) else null
    val fifoDataOe    = if (config.useFifo) out Bool()       else null
    val fifoRxfN      = if (config.useFifo) in  Bool()       else null
    val fifoTxeN      = if (config.useFifo) in  Bool()       else null
    val fifoRdN       = if (config.useFifo) out Bool()       else null
    val fifoWrN       = if (config.useFifo) out Bool()       else null

    // eMMC controller interface
    val emmcCmdValid     = out Bool()
    val emmcCmdId        = out Bits(8 bits)
    val emmcCmdLba       = out Bits(32 bits)
    val emmcCmdCount     = out Bits(16 bits)
    val emmcCmdReady     = in  Bool()
    val emmcRespStatus   = in  Bits(8 bits)
    val emmcRespValid    = in  Bool()

    // eMMC data read path (sector buffer -> UART)
    val emmcRdData        = in  Bits(8 bits)
    val emmcRdAddr        = out UInt(9 bits)
    val emmcRdSectorReady = in  Bool()
    val emmcRdSectorAck   = out Bool()

    // eMMC data write path (UART -> sector buffer)
    val emmcWrData        = out Bits(8 bits)
    val emmcWrAddr        = out UInt(9 bits)
    val emmcWrEn          = out Bool()
    val emmcWrSectorValid = out Bool()
    val emmcWrSectorAck   = in  Bool()
    val emmcWrBank        = out UInt(4 bits)

    // eMMC info data (CID/CSD)
    val emmcCid       = in  Bits(128 bits)
    val emmcCsd       = in  Bits(128 bits)
    val emmcInfoValid = in  Bool()

    // Card status (CMD13 result)
    val emmcCardStatus = in  Bits(32 bits)

    // Raw command response (R2 128-bit data)
    val emmcRawResp    = in  Bits(128 bits)

    // Debug (original 4-byte)
    val emmcDbgInitState = in  Bits(4 bits)
    val emmcDbgMcState   = in  Bits(5 bits)
    val emmcDbgCmdPin    = in  Bool()
    val emmcDbgDat0Pin   = in  Bool()

    // Debug (extended 8-byte)
    val emmcDbgCmdFsm        = in  Bits(3 bits)
    val emmcDbgDatFsm        = in  Bits(4 bits)
    val emmcDbgPartition     = in  Bits(2 bits)
    val emmcDbgUseFastClk    = in  Bool()
    val emmcDbgReinitPending = in  Bool()
    val emmcDbgErrCmdTimeout = in  Bits(8 bits)
    val emmcDbgErrCmdCrc     = in  Bits(8 bits)
    val emmcDbgErrDatRd      = in  Bits(8 bits)
    val emmcDbgErrDatWr      = in  Bits(8 bits)
    val emmcDbgInitRetryCnt  = in  Bits(8 bits)
    val emmcDbgClkPreset     = in  Bits(3 bits)

    // Status
    val uartActivity   = out Bool()
    val protocolError  = out Bool()
  }

  // ============================================================
  // Command IDs
  // ============================================================
  val CMD_PING          = B"8'h01"
  val CMD_GET_INFO      = B"8'h02"
  val CMD_READ_SECTOR   = B"8'h03"
  val CMD_WRITE_SECTOR  = B"8'h04"
  val CMD_ERASE         = B"8'h05"
  val CMD_GET_STATUS    = B"8'h06"
  val CMD_GET_EXT_CSD   = B"8'h07"
  val CMD_SET_PARTITION  = B"8'h08"
  val CMD_WRITE_EXT_CSD = B"8'h09"
  val CMD_GET_CARD_STATUS = B"8'h0A"
  val CMD_REINIT         = B"8'h0B"
  val CMD_SECURE_ERASE   = B"8'h0C"
  val CMD_SET_CLK_DIV    = B"8'h0D"
  val CMD_SEND_RAW       = B"8'h0E"
  val CMD_SET_BAUD       = B"8'h0F"
  val CMD_SET_RPMB_MODE  = B"8'h10"
  val CMD_SET_BUS_WIDTH  = B"8'h11"

  // Response status codes
  val STATUS_OK       = B"8'h00"
  val STATUS_ERR_CRC  = B"8'h01"
  val STATUS_ERR_CMD  = B"8'h02"
  val STATUS_ERR_EMMC = B"8'h03"
  val STATUS_BUSY     = B"8'h04"

  // RX FSM states
  val RX_IDLE    = B(0, 4 bits)
  val RX_CMD     = B(1, 4 bits)
  val RX_LEN_H   = B(2, 4 bits)
  val RX_LEN_L   = B(3, 4 bits)
  val RX_PAYLOAD = B(4, 4 bits)
  val RX_CRC     = B(5, 4 bits)
  val RX_EXEC1   = B(6, 4 bits)
  val RX_EXEC2   = B(7, 4 bits)

  // TX FSM states
  val TX_IDLE      = B(0, 4 bits)
  val TX_HEADER    = B(1, 4 bits)
  val TX_CMD       = B(2, 4 bits)
  val TX_STATUS    = B(3, 4 bits)
  val TX_LEN_H     = B(4, 4 bits)
  val TX_LEN_L     = B(5, 4 bits)
  val TX_PAYLOAD   = B(6, 4 bits)
  val TX_CRC       = B(7, 4 bits)
  val TX_PREFETCH  = B(8, 4 bits)
  val TX_BAUD_WAIT = B(9, 4 bits)

  // ============================================================
  // Baud rate preset lookup
  // ============================================================
  def baudPresetToCpb(preset: Bits): Bits = {
    val result = Bits(8 bits)
    result := B(20, 8 bits)  // default: 60M/20 = 3M
    when(preset(1 downto 0) === B"01") { result := B(10, 8 bits) }  // 60M/10 = 6M
    when(preset(1 downto 0) === B"10") { result := B(8, 8 bits) }   // 60M/8 = 7.5M
    when(preset(1 downto 0) === B"11") { result := B(5, 8 bits) }   // 60M/5 = 12M
    result
  }

  // ============================================================
  // Runtime UART baud rate
  // ============================================================
  val uartClksPerBit    = Reg(Bits(8 bits)) init 0
  val baudSwitchCpb     = Reg(Bits(8 bits)) init 0
  val baudSwitchPreset  = Reg(Bits(2 bits)) init 0
  val baudSwitchPending = Reg(Bool()) init False
  val currentBaudPreset = Reg(Bits(2 bits)) init 0

  // Baud watchdog: auto-reset to default if no valid packets for ~18s (2^30 @ 60MHz)
  val baudWatchdogCnt = Reg(UInt(30 bits)) init 0

  // ============================================================
  // Transport layer: UART or FT245 FIFO (compile-time selection)
  // ============================================================
  val txDataR  = Reg(Bits(8 bits)) init 0
  val txValidR = Reg(Bool()) init False

  // Wire to suppress FIFO reads during response TX (assigned after txState is defined)
  val fifoRxSuppress = if (config.useFifo) Bool() else null

  val (rxData, rxValid, rxFrameErr, txBusy) = if (!config.useFifo) {
    // UART mode: traditional UartRx/UartTx
    val uUartRx = new UartRx(UartTxConfig(clkFreq = config.clkFreq, baudRate = config.baudRate))
    uUartRx.io.rx         := io.uartRxPin
    uUartRx.io.clksPerBit := uartClksPerBit

    val uUartTx = new UartTx(UartTxConfig(clkFreq = config.clkFreq, baudRate = config.baudRate))
    uUartTx.io.dataIn      := txDataR
    uUartTx.io.dataValid   := txValidR
    uUartTx.io.clksPerBit  := uartClksPerBit

    io.uartTxPin := uUartTx.io.tx

    (uUartRx.io.dataOut, uUartRx.io.dataValid, uUartRx.io.frameErr, uUartTx.io.busy)
  } else {
    // FT245 FIFO mode: parallel byte interface via Ft245Fifo
    val fifo = new Ft245Fifo()
    fifo.io.fifoDataRead := io.fifoDataRead
    io.fifoDataWrite     := fifo.io.fifoDataWrite
    io.fifoDataOe        := fifo.io.fifoDataOe
    fifo.io.fifoRxfN     := io.fifoRxfN
    fifo.io.fifoTxeN     := io.fifoTxeN
    io.fifoRdN           := fifo.io.fifoRdN
    io.fifoWrN           := fifo.io.fifoWrN

    fifo.io.txDataIn    := txDataR
    fifo.io.txDataValid := txValidR
    fifo.io.rxSuppress  := fifoRxSuppress

    (fifo.io.rxDataOut, fifo.io.rxDataValid, False, fifo.io.txBusy)
  }

  // ============================================================
  // CRC-8 for RX (command validation)
  // ============================================================
  val rxCrcClearR = Reg(Bool()) init True
  val rxCrcEnR    = Reg(Bool()) init False

  val uRxCrc = new Crc8
  uRxCrc.io.clear  := rxCrcClearR
  uRxCrc.io.enable := rxCrcEnR
  uRxCrc.io.dataIn := rxData

  val rxCrcOut = uRxCrc.io.crcOut

  // ============================================================
  // CRC-8 for TX (response generation)
  // ============================================================
  val txCrcClearR = Reg(Bool()) init True
  val txCrcEnR    = Reg(Bool()) init False
  val txCrcDataR  = Reg(Bits(8 bits)) init 0

  val uTxCrc = new Crc8
  uTxCrc.io.clear  := txCrcClearR
  uTxCrc.io.enable := txCrcEnR
  uTxCrc.io.dataIn := txCrcDataR

  val txCrcOut = uTxCrc.io.crcOut

  // ============================================================
  // RX state
  // ============================================================
  val rxState      = Reg(Bits(4 bits)) init 0
  val rxCmdId      = Reg(Bits(8 bits)) init 0
  val rxPayloadLen = Reg(UInt(16 bits)) init 0
  val rxPayloadCnt = Reg(UInt(16 bits)) init 0

  // Payload buffer for short commands (max 8 bytes for LBA+count)
  val rxPayloadBuf = Vec(Reg(Bits(8 bits)) init 0, 8)

  // ============================================================
  // TX state
  // ============================================================
  val txState      = Reg(Bits(4 bits)) init 0
  val txCmdId      = Reg(Bits(8 bits)) init 0
  val txStatus     = Reg(Bits(8 bits)) init 0
  val txPayloadLen = Reg(UInt(16 bits)) init 0
  val txPayloadCnt = Reg(UInt(16 bits)) init 0
  val txStart      = Reg(Bool()) init False
  val txStartD     = Reg(Bool()) init False

  // Suppress FIFO RX reads: covers TX active, RX_EXEC processing, and
  // the 1-cycle pipeline gap between txStart and txStartD
  if (config.useFifo) {
    fifoRxSuppress := (txState =/= TX_IDLE) || (rxState === RX_EXEC1) || (rxState === RX_EXEC2) || txStart || txStartD
  }

  // Response payload source: 0=none, 1=info_shift, 2=emmc_rd_data
  val txPayloadSrc = Reg(Bits(2 bits)) init 0

  // Info shift register: replaces info_buf[32] array with indexed access.
  val infoShift = Reg(Bits(256 bits)) init 0

  // Registered BRAM output: breaks BRAM read -> MUX -> tx_crc_data critical path
  val emmcRdDataReg = Reg(Bits(8 bits)) init 0

  // Registered tx_busy: breaks uart_tx.state -> tx_busy -> info_shift critical path
  val txBusyR = Reg(Bool()) init False

  // Pre-computed flags for timing optimization
  val rxCrcMatch    = Reg(Bool()) init False
  val isWriteCmd    = Reg(Bool()) init False
  val txPayloadLast = Reg(Bool()) init False
  val rxPayloadLast = Reg(Bool()) init False
  val rxByteNum     = Reg(UInt(4 bits)) init 0

  // Pre-registered card status pending flag
  val cardStatusPending = Reg(Bool()) init False

  // Raw command pending flags
  val rawCmdPending   = Reg(Bool()) init False
  val rawRespIsLong   = Reg(Bool()) init False
  val rawRespExpected = Reg(Bool()) init False

  // Early write dispatch: CMD25 dispatched in RX_PAYLOAD after first sector
  val earlyWriteDispatched = Reg(Bool()) init False

  // Cross-module pipeline registers
  val respValidR      = Reg(Bool()) init False
  val respStatusR     = Reg(Bits(8 bits)) init 0
  val respCmdIdR      = Reg(Bits(8 bits)) init 0
  val respCardStatusR = Reg(Bits(32 bits)) init 0
  val respStatusIsOk  = Reg(Bool()) init False

  // RX timeout: ~140 ms at 60 MHz (2^23 cycles)
  val rxTimeoutCnt = Reg(UInt(23 bits)) init 0
  val rxTimeout    = Reg(Bool()) init False

  // Sector transfer tracking (read)
  val sectorsRemaining     = Reg(UInt(16 bits)) init 0
  val sectorsRemainingNext = Reg(UInt(16 bits)) init 0
  val sectorsPending       = Reg(Bool()) init False

  // Multi-write tracking
  val wrSectorsLeft    = Reg(UInt(16 bits)) init 0
  val wrSectorsReady   = Reg(UInt(5 bits)) init 0
  val wrByteInSector   = Reg(UInt(9 bits)) init 0
  val wrByteIsLast     = Reg(Bool()) init False
  val wrHasSectorsLeft = Reg(Bool()) init False
  val wrBankIncPending = Reg(Bool()) init False

  // ============================================================
  // Output registers
  // ============================================================
  val emmcCmdValidR     = Reg(Bool()) init False
  val emmcCmdIdR        = Reg(Bits(8 bits)) init 0
  val emmcCmdLbaR       = Reg(Bits(32 bits)) init 0
  val emmcCmdCountR     = Reg(Bits(16 bits)) init 0
  val emmcWrEnR         = Reg(Bool()) init False
  val emmcWrAddrR       = Reg(UInt(9 bits)) init 0
  val emmcWrDataR       = Reg(Bits(8 bits)) init 0
  val emmcWrSectorValidR = Reg(Bool()) init False
  val emmcWrBankR       = Reg(UInt(4 bits)) init 0
  val emmcRdAddrR       = Reg(UInt(9 bits)) init 0
  val emmcRdSectorAckR  = Reg(Bool()) init False
  val protocolErrorR    = Reg(Bool()) init False

  io.emmcCmdValid     := emmcCmdValidR
  io.emmcCmdId        := emmcCmdIdR
  io.emmcCmdLba       := emmcCmdLbaR
  io.emmcCmdCount     := emmcCmdCountR
  io.emmcRdAddr       := emmcRdAddrR
  io.emmcRdSectorAck  := emmcRdSectorAckR
  io.emmcWrData       := emmcWrDataR
  io.emmcWrAddr       := emmcWrAddrR
  io.emmcWrEn         := emmcWrEnR
  io.emmcWrSectorValid := emmcWrSectorValidR
  io.emmcWrBank       := emmcWrBankR
  io.protocolError    := protocolErrorR

  io.uartActivity := rxValid | txBusy

  // ============================================================
  // Default pulse clears
  // ============================================================
  rxCrcClearR      := False
  rxCrcEnR         := False
  emmcCmdValidR    := False
  emmcWrEnR        := False
  emmcRdSectorAckR := False
  txStart          := False
  txValidR         := False
  txCrcClearR      := False
  txCrcEnR         := False

  // ============================================================
  // wr_sectors_ready counter: tracks sectors buffered by UART beyond the first.
  // ============================================================
  when(io.emmcWrSectorAck) {
    emmcWrSectorValidR := False
  }
  when(wrSectorsReady =/= 0 && !emmcWrSectorValidR) {
    emmcWrSectorValidR := True
    wrSectorsReady := wrSectorsReady - 1  // may be overridden by boundary
  }

  // Delayed bank increment: apply 1 cycle after sector boundary detection
  when(wrBankIncPending) {
    emmcWrBankR     := emmcWrBankR + 1
    wrBankIncPending := False
  }

  // ============================================================
  // Pipeline registers (break timing-critical paths)
  // ============================================================
  emmcRdDataReg := io.emmcRdData
  txBusyR       := txBusy
  txStartD      := txStart

  // Cross-module pipeline: resp_status/valid from emmc_controller
  // resp_valid_r is sticky (latched): set on emmc_resp_valid pulse,
  // cleared in TX_IDLE when processed.
  when(io.emmcRespValid) {
    respValidR      := True
    respStatusR     := io.emmcRespStatus
    respCmdIdR      := emmcCmdIdR
    respCardStatusR := io.emmcCardStatus
    respStatusIsOk  := (io.emmcRespStatus === STATUS_OK)
  }

  // ============================================================
  // RX timeout: reset on rx_valid, overflow returns to RX_IDLE
  // ============================================================
  when(rxValid || rxState === RX_IDLE) {
    rxTimeoutCnt := 0
    rxTimeout    := False
  }.otherwise {
    rxTimeoutCnt := rxTimeoutCnt + 1
    when(rxTimeoutCnt.andR) {
      rxTimeout := True
    }
  }

  // ============================================================
  // Baud watchdog: revert to default baud if no valid packets
  // ============================================================
  when(uartClksPerBit === 0) {
    baudWatchdogCnt := 0
  }.elsewhen(rxState === RX_EXEC1 && rxCrcMatch) {
    baudWatchdogCnt := 0
  }.elsewhen(baudWatchdogCnt.andR) {
    uartClksPerBit    := B(0, 8 bits)
    currentBaudPreset := B(0, 2 bits)
    baudSwitchPending := False
    baudWatchdogCnt   := 0
  }.otherwise {
    baudWatchdogCnt := baudWatchdogCnt + 1
  }

  // ============================================================
  // RX FSM - Parse incoming commands
  // ============================================================
  when(rxTimeout && rxState =/= RX_IDLE && rxState =/= RX_EXEC1 && rxState =/= RX_EXEC2) {
    rxState        := RX_IDLE
    protocolErrorR := True
    wrSectorsReady := 0
  }.elsewhen(rxState === RX_IDLE) {
    protocolErrorR       := False
    earlyWriteDispatched := False
    when(rxValid) {
      when(rxData === B"8'hAA") {
        rxState     := RX_CMD
        rxCrcClearR := True
      }
    }

  }.elsewhen(rxState === RX_CMD) {
    when(rxValid) {
      rxCmdId    := rxData
      isWriteCmd := (rxData === CMD_WRITE_SECTOR)
      rxCrcEnR   := True
      rxState    := RX_LEN_H
    }

  }.elsewhen(rxState === RX_LEN_H) {
    when(rxValid) {
      rxPayloadLen(15 downto 8) := rxData.asUInt
      rxCrcEnR := True
      rxState  := RX_LEN_L
    }

  }.elsewhen(rxState === RX_LEN_L) {
    when(rxValid) {
      rxPayloadLen(7 downto 0) := rxData.asUInt
      rxCrcEnR := True
      val fullLen = rxPayloadLen(15 downto 8) @@ rxData.asUInt
      rxPayloadCnt  := fullLen - 1
      rxPayloadLast := (fullLen === 1)
      rxByteNum     := 0
      emmcWrAddrR   := U"9'h1FF"
      when(fullLen === 0) {
        rxState := RX_CRC
      }.otherwise {
        rxState := RX_PAYLOAD
      }
    }

  }.elsewhen(rxState === RX_PAYLOAD) {
    when(rxValid) {
      rxCrcEnR := True

      // rx_byte_num: saturating 0->8, tracks first payload bytes
      when(!rxByteNum(3)) {  // rxByteNum < 8
        rxPayloadBuf(rxByteNum(2 downto 0)) := rxData
      }

      // Multi-write: init sector tracking when count byte arrives
      when(isWriteCmd && rxByteNum === 5) {
        val wrCount = rxPayloadBuf(4) ## rxData
        wrSectorsLeft    := (wrCount.asUInt - 1).resized
        wrHasSectorsLeft := (wrCount.asUInt > 1)
        wrByteInSector   := 0
        wrByteIsLast     := False
        emmcWrBankR      := 0
        wrSectorsReady   := 0
      }

      when(isWriteCmd && (rxByteNum(3) || rxByteNum >= 6)) {
        emmcWrDataR    := rxData
        emmcWrEnR      := True
        emmcWrAddrR    := emmcWrAddrR + 1
        wrByteInSector := wrByteInSector + 1
        wrByteIsLast   := (wrByteInSector === 510)

        // Sector boundary: after 512 bytes, signal next sector ready
        when(wrByteIsLast && wrHasSectorsLeft) {
          when(!earlyWriteDispatched) {
            // First sector boundary: early dispatch CMD25
            emmcCmdLbaR   := rxPayloadBuf(0) ## rxPayloadBuf(1) ## rxPayloadBuf(2) ## rxPayloadBuf(3)
            emmcCmdCountR := rxPayloadBuf(4) ## rxPayloadBuf(5)
            emmcCmdIdR    := CMD_WRITE_SECTOR
            emmcCmdValidR := True
            emmcWrSectorValidR  := True
            earlyWriteDispatched := True
          }.otherwise {
            // Subsequent boundaries: increment ready counter
            when(wrSectorsReady =/= 0 && !emmcWrSectorValidR) {
              wrSectorsReady := wrSectorsReady  // +1 -1 = net 0
            }.otherwise {
              wrSectorsReady := wrSectorsReady + 1
            }
          }
          wrSectorsLeft    := wrSectorsLeft - 1
          wrHasSectorsLeft := (wrSectorsLeft =/= 1)
          wrByteInSector   := 0
          wrByteIsLast     := False
          wrBankIncPending := True
        }.elsewhen(wrByteIsLast && !wrHasSectorsLeft && earlyWriteDispatched) {
          // Last sector of multi-write completed
          when(wrSectorsReady =/= 0 && !emmcWrSectorValidR) {
            wrSectorsReady := wrSectorsReady  // +1 -1 = net 0
          }.otherwise {
            wrSectorsReady := wrSectorsReady + 1
          }
        }
      }

      // Update rx_byte_num (saturating at 8)
      when(!rxByteNum(3)) {
        rxByteNum := rxByteNum + 1
      }

      // Down-counter
      rxPayloadCnt  := rxPayloadCnt - 1
      rxPayloadLast := (rxPayloadCnt === 1)
      when(rxPayloadLast) {
        rxState := RX_CRC
      }
    }

  }.elsewhen(rxState === RX_CRC) {
    when(rxValid) {
      rxCrcMatch := (rxData === rxCrcOut)
      rxState    := RX_EXEC1
    }

  }.elsewhen(rxState === RX_EXEC1) {
    // Stage 1: Check CRC match (registered), load info shift register.
    when(rxCrcMatch) {
      // CRC OK - pre-load info shift register with CID+CSD
      infoShift := io.emmcCid ## io.emmcCsd

      // Pre-extract LBA and count from payload buffer
      emmcCmdLbaR   := rxPayloadBuf(0) ## rxPayloadBuf(1) ## rxPayloadBuf(2) ## rxPayloadBuf(3)
      emmcCmdCountR := rxPayloadBuf(4) ## rxPayloadBuf(5)

      rxState := RX_EXEC2
    }.otherwise {
      // CRC error - send error response
      protocolErrorR := True
      txStart        := True
      txCmdId        := rxCmdId
      txStatus       := STATUS_ERR_CRC
      txPayloadLen   := 0
      txPayloadSrc   := B"00"
      rxState        := RX_IDLE
    }

  }.elsewhen(rxState === RX_EXEC2) {
    // Stage 2: Set TX parameters based on command
    when(rxCmdId === CMD_PING) {
      txStart      := True
      txCmdId      := CMD_PING
      txStatus     := STATUS_OK
      txPayloadLen := 0
      txPayloadSrc := B"00"

    }.elsewhen(rxCmdId === CMD_GET_INFO) {
      txStart      := True
      txCmdId      := CMD_GET_INFO
      txStatus     := Mux(io.emmcInfoValid, STATUS_OK, STATUS_ERR_EMMC)
      txPayloadLen := U(32, 16 bits)
      txPayloadSrc := B"01"

    }.elsewhen(rxCmdId === CMD_READ_SECTOR) {
      emmcCmdIdR    := CMD_READ_SECTOR
      emmcCmdValidR := True
      sectorsRemaining     := emmcCmdCountR.asUInt
      sectorsRemainingNext := emmcCmdCountR.asUInt - 1
      sectorsPending       := (emmcCmdCountR.asUInt =/= 0)

    }.elsewhen(rxCmdId === CMD_WRITE_SECTOR) {
      when(!earlyWriteDispatched) {
        emmcCmdIdR         := CMD_WRITE_SECTOR
        emmcCmdValidR      := True
        emmcWrSectorValidR := True
      }

    }.elsewhen(rxCmdId === CMD_ERASE) {
      emmcCmdIdR    := CMD_ERASE
      emmcCmdValidR := True

    }.elsewhen(rxCmdId === CMD_GET_STATUS) {
      // 12-byte extended debug status
      // Bytes 0-3: backward compatible
      infoShift(255 downto 248) := io.emmcRespStatus
      infoShift(247 downto 240) := io.emmcDbgInitState ## B"0" ## io.emmcDbgMcState(4 downto 2)
      infoShift(239 downto 232) := io.emmcDbgMcState(1 downto 0) ## io.emmcInfoValid ## io.emmcCmdReady ## B(0, 4 bits)
      infoShift(231 downto 224) := io.emmcDbgCmdPin ## io.emmcDbgDat0Pin ## B(0, 6 bits)
      // Bytes 4-11: new extended fields
      infoShift(223 downto 216) := io.emmcDbgCmdFsm ## io.emmcDbgDatFsm ## io.emmcDbgUseFastClk
      infoShift(215 downto 208) := io.emmcDbgPartition ## io.emmcDbgReinitPending ## B(0, 5 bits)
      infoShift(207 downto 200) := io.emmcDbgErrCmdTimeout
      infoShift(199 downto 192) := io.emmcDbgErrCmdCrc
      infoShift(191 downto 184) := io.emmcDbgErrDatRd
      infoShift(183 downto 176) := io.emmcDbgErrDatWr
      infoShift(175 downto 168) := io.emmcDbgInitRetryCnt
      infoShift(167 downto 160) := B(0, 3 bits) ## currentBaudPreset ## io.emmcDbgClkPreset
      txStart      := True
      txCmdId      := CMD_GET_STATUS
      txStatus     := STATUS_OK
      txPayloadLen := U(12, 16 bits)
      txPayloadSrc := B"01"

    }.elsewhen(rxCmdId === CMD_GET_EXT_CSD) {
      emmcCmdIdR    := CMD_GET_EXT_CSD
      emmcCmdValidR := True
      sectorsRemaining     := U(1, 16 bits)
      sectorsRemainingNext := U(0, 16 bits)
      sectorsPending       := True

    }.elsewhen(rxCmdId === CMD_SET_PARTITION) {
      emmcCmdIdR    := CMD_SET_PARTITION
      emmcCmdLbaR   := B(0, 24 bits) ## rxPayloadBuf(0)
      emmcCmdValidR := True

    }.elsewhen(rxCmdId === CMD_WRITE_EXT_CSD) {
      emmcCmdIdR    := CMD_WRITE_EXT_CSD
      emmcCmdLbaR   := B(0, 16 bits) ## rxPayloadBuf(0) ## rxPayloadBuf(1)
      emmcCmdValidR := True

    }.elsewhen(rxCmdId === CMD_GET_CARD_STATUS) {
      emmcCmdIdR         := CMD_GET_CARD_STATUS
      emmcCmdValidR      := True
      cardStatusPending  := True

    }.elsewhen(rxCmdId === CMD_REINIT) {
      emmcCmdIdR    := CMD_REINIT
      emmcCmdValidR := True

    }.elsewhen(rxCmdId === CMD_SECURE_ERASE) {
      emmcCmdIdR    := CMD_SECURE_ERASE
      emmcCmdValidR := True

    }.elsewhen(rxCmdId === CMD_SET_CLK_DIV) {
      emmcCmdIdR    := CMD_SET_CLK_DIV
      emmcCmdLbaR   := B(0, 29 bits) ## rxPayloadBuf(0)(2 downto 0)
      emmcCmdValidR := True

    }.elsewhen(rxCmdId === CMD_SEND_RAW) {
      emmcCmdIdR    := CMD_SEND_RAW
      emmcCmdLbaR   := rxPayloadBuf(1) ## rxPayloadBuf(2) ## rxPayloadBuf(3) ## rxPayloadBuf(4)
      emmcCmdCountR := B(0, 5 bits) ## rxPayloadBuf(5)(2 downto 0) ## B(0, 2 bits) ## rxPayloadBuf(0)(5 downto 0)
      emmcCmdValidR    := True
      rawCmdPending    := True
      rawRespIsLong    := rxPayloadBuf(5)(1)
      rawRespExpected  := rxPayloadBuf(5)(0)

    }.elsewhen(rxCmdId === CMD_SET_RPMB_MODE) {
      emmcCmdIdR    := CMD_SET_RPMB_MODE
      emmcCmdLbaR   := B(0, 31 bits) ## rxPayloadBuf(0)(0)
      emmcCmdValidR := True

    }.elsewhen(rxCmdId === CMD_SET_BUS_WIDTH) {
      emmcCmdIdR    := CMD_SET_BUS_WIDTH
      emmcCmdLbaR   := B(0, 31 bits) ## rxPayloadBuf(0)(0)
      emmcCmdValidR := True

    }.elsewhen(rxCmdId === CMD_SET_BAUD) {
      if (!config.useFifo) {
        // UART mode: validate preset and switch baud rate
        when(rxPayloadBuf(0)(7 downto 2) === 0 && rxPayloadBuf(0)(1 downto 0).asUInt <= 3
             && rxPayloadBuf(0)(1 downto 0) =/= B"10") {
          baudSwitchCpb     := baudPresetToCpb(rxPayloadBuf(0))
          baudSwitchPreset  := rxPayloadBuf(0)(1 downto 0)
          baudSwitchPending := True
          txStart      := True
          txCmdId      := CMD_SET_BAUD
          txStatus     := STATUS_OK
          txPayloadLen := 0
          txPayloadSrc := B"00"
        }.otherwise {
          txStart      := True
          txCmdId      := CMD_SET_BAUD
          txStatus     := STATUS_ERR_CMD
          txPayloadLen := 0
          txPayloadSrc := B"00"
        }
      } else {
        // FIFO mode: baud rate is irrelevant, always return OK
        txStart      := True
        txCmdId      := CMD_SET_BAUD
        txStatus     := STATUS_OK
        txPayloadLen := 0
        txPayloadSrc := B"00"
      }

    }.otherwise {
      protocolErrorR := True
      txStart      := True
      txCmdId      := rxCmdId
      txStatus     := STATUS_ERR_CMD
      txPayloadLen := 0
      txPayloadSrc := B"00"
    }

    rxState := RX_IDLE
  }

  // ============================================================
  // TX FSM - Send response packets
  // ============================================================
  when(txState === TX_IDLE) {
    when(txStartD) {
      txState     := TX_HEADER
      txCrcClearR := True
    }.elsewhen(io.emmcRdSectorReady && sectorsPending) {
      emmcRdSectorAckR := True
      txCmdId      := CMD_READ_SECTOR
      txStatus     := STATUS_OK
      txPayloadLen := U(512, 16 bits)
      txPayloadSrc := B"10"
      txState      := TX_HEADER
      txCrcClearR  := True
      sectorsRemaining     := sectorsRemainingNext
      sectorsRemainingNext := sectorsRemainingNext - 1
      sectorsPending       := (sectorsRemaining > 1)
    }.elsewhen(respValidR) {
      respValidR  := False
      txCmdId     := respCmdIdR
      txStatus    := respStatusR
      txCrcClearR := True
      txState     := TX_HEADER
      when(rawCmdPending && respStatusIsOk) {
        // Raw CMD response: 0/4/16 bytes depending on flags
        when(!rawRespExpected) {
          txPayloadLen := 0
          txPayloadSrc := B"00"
        }.elsewhen(rawRespIsLong) {
          infoShift    := io.emmcRawResp ## B(0, 128 bits)
          txPayloadLen := U(16, 16 bits)
          txPayloadSrc := B"01"
        }.otherwise {
          infoShift(255 downto 224) := respCardStatusR
          infoShift(223 downto 0)   := B(0, 224 bits)
          txPayloadLen := U(4, 16 bits)
          txPayloadSrc := B"01"
        }
        rawCmdPending     := False
        cardStatusPending := False
      }.elsewhen(rawCmdPending) {
        txPayloadLen := 0
        txPayloadSrc := B"00"
        rawCmdPending     := False
        cardStatusPending := False
      }.elsewhen(cardStatusPending && respStatusIsOk) {
        infoShift(255 downto 224) := respCardStatusR
        txPayloadLen := U(4, 16 bits)
        txPayloadSrc := B"01"
        cardStatusPending := False
      }.otherwise {
        txPayloadLen := 0
        txPayloadSrc := B"00"
        cardStatusPending := False
      }
    }

  }.elsewhen(txState === TX_HEADER) {
    when(!txBusy) {
      txDataR  := B"8'h55"
      txValidR := True
      txState  := TX_CMD
    }

  }.elsewhen(txState === TX_CMD) {
    when(!txBusy && !txValidR) {
      txDataR    := txCmdId
      txValidR   := True
      txCrcEnR   := True
      txCrcDataR := txCmdId
      txState    := TX_STATUS
    }

  }.elsewhen(txState === TX_STATUS) {
    when(!txBusy && !txValidR) {
      txDataR    := txStatus
      txValidR   := True
      txCrcEnR   := True
      txCrcDataR := txStatus
      txState    := TX_LEN_H
    }

  }.elsewhen(txState === TX_LEN_H) {
    when(!txBusy && !txValidR) {
      txDataR    := txPayloadLen(15 downto 8).asBits
      txValidR   := True
      txCrcEnR   := True
      txCrcDataR := txPayloadLen(15 downto 8).asBits
      txState    := TX_LEN_L
    }

  }.elsewhen(txState === TX_LEN_L) {
    when(!txBusy && !txValidR) {
      txDataR    := txPayloadLen(7 downto 0).asBits
      txValidR   := True
      txCrcEnR   := True
      txCrcDataR := txPayloadLen(7 downto 0).asBits
      txPayloadCnt  := txPayloadLen - 1
      txPayloadLast := (txPayloadLen === 1)
      emmcRdAddrR   := 0
      when(txPayloadLen === 0) {
        txState := TX_CRC
      }.otherwise {
        txState := TX_PAYLOAD
      }
    }

  }.elsewhen(txState === TX_PAYLOAD) {
    when(!txBusy && !txValidR) {
      switch(txPayloadSrc) {
        is(B"01") {
          // Shift register: MSB byte out first
          txDataR    := infoShift(255 downto 248)
          txCrcDataR := infoShift(255 downto 248)
          infoShift  := infoShift(247 downto 0) ## B(0, 8 bits)
        }
        is(B"10") {
          txDataR    := emmcRdDataReg
          txCrcDataR := emmcRdDataReg
          emmcRdAddrR := emmcRdAddrR + 1
        }
        default {
          txDataR    := B(0, 8 bits)
          txCrcDataR := B(0, 8 bits)
        }
      }
      txValidR  := True
      txCrcEnR  := True
      txPayloadCnt  := txPayloadCnt - 1
      txPayloadLast := (txPayloadCnt === 1)
      when(txPayloadLast) {
        txState := TX_CRC
      }
    }

  }.elsewhen(txState === TX_CRC) {
    when(!txBusy && !txValidR) {
      txDataR  := txCrcOut
      txValidR := True
      txState  := Mux(baudSwitchPending, TX_BAUD_WAIT, TX_IDLE)
    }

  }.elsewhen(txState === TX_BAUD_WAIT) {
    // Wait until CRC byte is fully transmitted, then apply new baud
    when(!txBusy && !txValidR) {
      uartClksPerBit    := baudSwitchCpb
      currentBaudPreset := baudSwitchPreset
      baudSwitchPending := False
      txState           := TX_IDLE
    }
  }
}
