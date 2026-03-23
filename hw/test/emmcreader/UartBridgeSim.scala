package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class UartBridgeSim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  val cidValue = BigInt("DEADBEEF12345678ABCDEF0123456789", 16)
  val csdValue = BigInt("CAFEBABE98765432FEDCBA9876543210", 16)

  def initDut(dut: UartBridge): Unit = {
    dut.io.uartRxPin          #= true
    dut.io.emmcCmdReady        #= true
    dut.io.emmcRespValid       #= false
    dut.io.emmcRespStatus      #= 0
    dut.io.emmcRdData          #= 0
    dut.io.emmcRdSectorReady   #= false
    dut.io.emmcWrSectorAck     #= false
    dut.io.emmcCid             #= cidValue
    dut.io.emmcCsd             #= csdValue
    dut.io.emmcInfoValid       #= true
    dut.io.emmcCardStatus      #= 0
    dut.io.emmcRawResp         #= BigInt(0)
    dut.io.emmcDbgInitState    #= 0
    dut.io.emmcDbgMcState      #= 0
    dut.io.emmcDbgCmdPin       #= true
    dut.io.emmcDbgDat0Pin      #= true
    dut.io.emmcDbgCmdFsm       #= 0
    dut.io.emmcDbgDatFsm       #= 0
    dut.io.emmcDbgPartition    #= 0
    dut.io.emmcDbgUseFastClk   #= false
    dut.io.emmcDbgReinitPending #= false
    dut.io.emmcDbgErrCmdTimeout #= 0
    dut.io.emmcDbgErrCmdCrc    #= 0
    dut.io.emmcDbgErrDatRd     #= 0
    dut.io.emmcDbgErrDatWr     #= 0
    dut.io.emmcDbgInitRetryCnt #= 0
    dut.io.emmcDbgClkPreset    #= 0
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  // ============================================================
  // UART bit-bang helpers
  // ============================================================
  def sendByte(dut: UartBridge, byte: Int, cpb: Int = 20): Unit = {
    // Start bit
    dut.io.uartRxPin #= false
    for (_ <- 0 until cpb) dut.clockDomain.waitRisingEdge()
    // Data bits (LSB first)
    for (i <- 0 until 8) {
      dut.io.uartRxPin #= ((byte >> i) & 1) == 1
      for (_ <- 0 until cpb) dut.clockDomain.waitRisingEdge()
    }
    // Stop bit
    dut.io.uartRxPin #= true
    for (_ <- 0 until cpb) dut.clockDomain.waitRisingEdge()
  }

  def recvByte(dut: UartBridge, cpb: Int = 20, timeout: Int = 50000): Int = {
    // Wait for start bit (falling edge)
    var waited = 0
    while (dut.io.uartTxPin.toBoolean && waited < timeout) {
      dut.clockDomain.waitRisingEdge()
      waited += 1
    }
    assert(waited < timeout, "recvByte: timeout waiting for start bit")
    // Advance to middle of start bit
    for (_ <- 0 until cpb / 2) dut.clockDomain.waitRisingEdge()
    // Sample 8 data bits (LSB first)
    var byte = 0
    for (i <- 0 until 8) {
      for (_ <- 0 until cpb) dut.clockDomain.waitRisingEdge()
      if (dut.io.uartTxPin.toBoolean) byte |= (1 << i)
    }
    // Wait through stop bit
    for (_ <- 0 until cpb) dut.clockDomain.waitRisingEdge()
    byte
  }

  // ============================================================
  // CRC-8 (poly 0x07, init 0x00)
  // ============================================================
  def crc8sw(data: Seq[Int]): Int = {
    var crc = 0
    for (b <- data) {
      crc ^= (b & 0xFF)
      for (_ <- 0 until 8) {
        if ((crc & 0x80) != 0) crc = ((crc << 1) ^ 0x07) & 0xFF
        else crc = (crc << 1) & 0xFF
      }
    }
    crc
  }

  // ============================================================
  // Packet-level helpers
  // ============================================================
  def sendPacket(dut: UartBridge, cmd: Int, payload: Seq[Int], cpb: Int = 20): Unit = {
    val lenH = (payload.length >> 8) & 0xFF
    val lenL = payload.length & 0xFF
    sendByte(dut, 0xAA, cpb)
    sendByte(dut, cmd, cpb)
    sendByte(dut, lenH, cpb)
    sendByte(dut, lenL, cpb)
    for (b <- payload) sendByte(dut, b, cpb)
    val crc = crc8sw(Seq(cmd, lenH, lenL) ++ payload)
    sendByte(dut, crc, cpb)
  }

  def recvPacket(dut: UartBridge, cpb: Int = 20): (Int, Int, Seq[Int]) = {
    val header = recvByte(dut, cpb)
    assert(header == 0x55, s"Expected header 0x55, got 0x${header.toHexString}")
    val cmd = recvByte(dut, cpb)
    val status = recvByte(dut, cpb)
    val lenH = recvByte(dut, cpb)
    val lenL = recvByte(dut, cpb)
    val len = (lenH << 8) | lenL
    val payload = (0 until len).map(_ => recvByte(dut, cpb))
    val crc = recvByte(dut, cpb)
    val expectedCrc = crc8sw(Seq(cmd, status, lenH, lenL) ++ payload)
    assert(crc == expectedCrc,
      s"CRC mismatch: got 0x${crc.toHexString}, expected 0x${expectedCrc.toHexString}")
    (cmd, status, payload)
  }

  // ================================================================
  // Test 1: PING
  // ================================================================
  test("PING returns OK with no payload") {
    simConfig.compile(new UartBridge()).doSim { dut =>
      initDut(dut)
      sendPacket(dut, 0x01, Seq.empty)
      val (cmd, status, payload) = recvPacket(dut)
      assert(cmd == 0x01, s"cmd=0x${cmd.toHexString}")
      assert(status == 0x00, s"status=0x${status.toHexString}")
      assert(payload.isEmpty, s"Expected empty payload, got ${payload.length} bytes")
    }
  }

  // ================================================================
  // Test 2: GET_INFO returns CID+CSD (32 bytes)
  // ================================================================
  test("GET_INFO returns CID and CSD") {
    simConfig.compile(new UartBridge()).doSim { dut =>
      initDut(dut)
      sendPacket(dut, 0x02, Seq.empty)
      val (cmd, status, payload) = recvPacket(dut)
      assert(cmd == 0x02)
      assert(status == 0x00)
      assert(payload.length == 32, s"Expected 32 bytes, got ${payload.length}")
      // Verify CID bytes (big-endian, MSB first)
      val cidBytes = (0 until 16).map(i => ((cidValue >> (120 - i * 8)) & 0xFF).toInt)
      val csdBytes = (0 until 16).map(i => ((csdValue >> (120 - i * 8)) & 0xFF).toInt)
      for (i <- 0 until 16) {
        assert(payload(i) == cidBytes(i),
          s"CID byte[$i]=0x${payload(i).toHexString} expected 0x${cidBytes(i).toHexString}")
      }
      for (i <- 0 until 16) {
        assert(payload(16 + i) == csdBytes(i),
          s"CSD byte[$i]=0x${payload(16 + i).toHexString} expected 0x${csdBytes(i).toHexString}")
      }
    }
  }

  // ================================================================
  // Test 3: GET_STATUS returns 12-byte debug payload
  // ================================================================
  test("GET_STATUS returns 12-byte payload") {
    simConfig.compile(new UartBridge()).doSim { dut =>
      initDut(dut)
      sendPacket(dut, 0x06, Seq.empty)
      val (cmd, status, payload) = recvPacket(dut)
      assert(cmd == 0x06)
      assert(status == 0x00)
      assert(payload.length == 12, s"Expected 12 bytes, got ${payload.length}")
    }
  }

  // ================================================================
  // Test 4: CRC error response
  // ================================================================
  test("CRC error returns status 0x01") {
    simConfig.compile(new UartBridge()).doSim { dut =>
      initDut(dut)
      // Fork a monitor to capture transient protocolError flag
      // (it's cleared when FSM returns to RX_IDLE, before recvPacket finishes)
      var protocolErrorSeen = false
      fork {
        while (true) {
          dut.clockDomain.waitRisingEdge()
          if (dut.io.protocolError.toBoolean) protocolErrorSeen = true
        }
      }
      // Send packet with intentionally wrong CRC
      sendByte(dut, 0xAA)
      sendByte(dut, 0x01) // PING cmd
      sendByte(dut, 0x00) // len_h
      sendByte(dut, 0x00) // len_l
      sendByte(dut, 0xFF) // wrong CRC (correct would be crc8sw of [0x01, 0x00, 0x00])
      // Receive error response
      val (cmd, status, payload) = recvPacket(dut)
      assert(cmd == 0x01)
      assert(status == 0x01, s"Expected CRC error status 0x01, got 0x${status.toHexString}")
      assert(payload.isEmpty)
      // Verify protocolError flag was pulsed during error handling
      assert(protocolErrorSeen, "protocolError never pulsed")
    }
  }

  // ================================================================
  // Test 5: Unknown CMD returns status 0x02
  // ================================================================
  test("Unknown CMD returns status 0x02") {
    simConfig.compile(new UartBridge()).doSim { dut =>
      initDut(dut)
      sendPacket(dut, 0xFF, Seq.empty)
      val (cmd, status, payload) = recvPacket(dut)
      assert(cmd == 0xFF)
      assert(status == 0x02, s"Expected ERR_CMD status 0x02, got 0x${status.toHexString}")
      assert(payload.isEmpty)
    }
  }

  // ================================================================
  // Test 6: SET_BAUD switches baud rate
  // ================================================================
  test("SET_BAUD switches to 6M then PING works") {
    simConfig.compile(new UartBridge()).doSim { dut =>
      initDut(dut)
      // Send SET_BAUD preset=1 (6M, CPB=10)
      sendPacket(dut, 0x0F, Seq(0x01))
      // Response comes at OLD baud (3M, CPB=20)
      val (cmd, status, _) = recvPacket(dut)
      assert(cmd == 0x0F)
      assert(status == 0x00, s"Expected OK, got 0x${status.toHexString}")
      // Wait for baud switch to complete
      for (_ <- 0 until 100) dut.clockDomain.waitRisingEdge()
      // Send PING at new baud (6M, CPB=10)
      sendPacket(dut, 0x01, Seq.empty, cpb = 10)
      val (cmd2, status2, _) = recvPacket(dut, cpb = 10)
      assert(cmd2 == 0x01)
      assert(status2 == 0x00, s"Expected OK at 6M, got 0x${status2.toHexString}")
    }
  }

  // ================================================================
  // Test 7: READ dispatch + sector stream
  // ================================================================
  test("READ dispatches to controller and streams sector") {
    simConfig.compile(new UartBridge()).doSim { dut =>
      initDut(dut)

      val testData = Array.tabulate(512)(i => (i * 11 + 0x33) & 0xFF)

      // Fork BRAM mock: provide data based on read address
      fork {
        while (true) {
          dut.clockDomain.waitRisingEdge()
          dut.io.emmcRdData #= testData(dut.io.emmcRdAddr.toInt % testData.length)
        }
      }

      // Fork controller mock: watch emmcCmdValid, then assert rdSectorReady
      var cmdSeen = false
      var capturedCmdId = 0
      fork {
        while (true) {
          dut.clockDomain.waitRisingEdge()
          if (dut.io.emmcCmdValid.toBoolean && !cmdSeen) {
            cmdSeen = true
            capturedCmdId = dut.io.emmcCmdId.toInt
            // Small delay, then signal sector ready
            for (_ <- 0 until 10) dut.clockDomain.waitRisingEdge()
            dut.io.emmcRdSectorReady #= true
            // Wait for ack
            while (!dut.io.emmcRdSectorAck.toBoolean) dut.clockDomain.waitRisingEdge()
            dut.io.emmcRdSectorReady #= false
            // Send response after sector is sent
            for (_ <- 0 until 10) dut.clockDomain.waitRisingEdge()
            dut.io.emmcRespValid  #= true
            dut.io.emmcRespStatus #= 0x00
            dut.clockDomain.waitRisingEdge()
            dut.io.emmcRespValid #= false
          }
        }
      }

      // Send READ_SECTOR: LBA=0, count=1
      val payload = Seq(0x00, 0x00, 0x00, 0x00, 0x00, 0x01)
      sendPacket(dut, 0x03, payload)

      // Receive sector packet (cmd=0x03, status=0x00, 512 bytes)
      val (cmd1, status1, sectorPayload) = recvPacket(dut)
      assert(cmd1 == 0x03)
      assert(status1 == 0x00)
      assert(sectorPayload.length == 512, s"Expected 512 bytes, got ${sectorPayload.length}")
      for (i <- 0 until 512) {
        assert(sectorPayload(i) == testData(i),
          s"Sector byte[$i]=0x${sectorPayload(i).toHexString} expected 0x${testData(i).toHexString}")
      }

      // Receive final status packet
      val (cmd2, status2, finalPayload) = recvPacket(dut)
      assert(cmd2 == 0x03)
      assert(status2 == 0x00)
      assert(finalPayload.isEmpty)

      // Verify controller saw correct cmd
      assert(cmdSeen, "Controller never saw emmcCmdValid")
      assert(capturedCmdId == 0x03, s"Expected cmdId 0x03, got 0x${capturedCmdId.toHexString}")
    }
  }
}
