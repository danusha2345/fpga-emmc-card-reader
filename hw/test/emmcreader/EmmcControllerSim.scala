package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class EmmcControllerSim extends AnyFunSuite {

  // Fast clkFreq: TICKS_1MS=10, TICKS_50MS=500 → init completes in ~600K sysclk
  val testClkFreq = 10000

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

  // Helper: set datIn[3:0] with boolean on DAT0, DAT[3:1]=1
  def setDatIn0(dut: EmmcController, dat0: Boolean): Unit = {
    dut.io.datIn #= (if (dat0) 0xF else 0xE)
  }

  def initDut(dut: EmmcController): Unit = {
    dut.io.cmdIn            #= true
    dut.io.datIn            #= 0xF  // all high
    dut.io.cmdValid         #= false
    dut.io.cmdId            #= 0
    dut.io.cmdLba           #= 0
    dut.io.cmdCount         #= 0
    dut.io.uartRdAddr       #= 0
    dut.io.rdSectorAck      #= false
    dut.io.uartWrData       #= 0
    dut.io.uartWrAddr       #= 0
    dut.io.uartWrEn         #= false
    dut.io.uartWrSectorValid #= false
    dut.io.uartWrBank       #= 0
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  // ============================================================
  // Wait for emmcClk 0→1 transition
  // ============================================================
  def waitEmmcClkRising(dut: EmmcController): Unit = {
    var prev = dut.io.emmcClk.toBoolean
    while (true) {
      dut.clockDomain.waitRisingEdge()
      val cur = dut.io.emmcClk.toBoolean
      if (cur && !prev) return
      prev = cur
    }
  }

  // ============================================================
  // Card stub: emulates eMMC card at CMD/DAT physical level
  // Works in 1-bit mode (DAT0 only). datIn/datOut are Bits(4 bits).
  // ============================================================
  class ControllerCardStub(dut: EmmcController) {
    private val crcHelper = new EmmcCardStub(null, null, null)

    var sectorData: Array[Int] = Array.tabulate(512)(i => i & 0xFF)
    var capturedWriteData: Array[Int] = Array.fill(512)(0)
    var writeCrcOk: Boolean = true
    var sectorsToTransfer: Int = 1

    private def sendCmdResponse(bits: Seq[Boolean]): Unit = {
      for (b <- bits) {
        dut.io.cmdIn #= b
        waitEmmcClkRising(dut)
      }
      dut.io.cmdIn #= true
    }

    private def sendSectorOnDat(data: Array[Int]): Unit = {
      // NAC gap
      for (_ <- 0 until 4) waitEmmcClkRising(dut)
      // Start bit on DAT0
      setDatIn0(dut, dat0 = false)
      waitEmmcClkRising(dut)
      // Data bits MSB first on DAT0
      val dataBits = Crc16Helper.bytesToBitsMsb(data.toSeq)
      val crc = Crc16Helper.compute(dataBits)
      for (b <- dataBits) {
        setDatIn0(dut, dat0 = b)
        waitEmmcClkRising(dut)
      }
      // CRC-16
      for (i <- 15 to 0 by -1) {
        setDatIn0(dut, dat0 = ((crc >> i) & 1) == 1)
        waitEmmcClkRising(dut)
      }
      // End bit
      dut.io.datIn #= 0xF
      waitEmmcClkRising(dut)
    }

    private def captureWriteFromDat(): Unit = {
      // Wait for host start bit (datOe=true, datOut[0]=0)
      var found = false
      for (_ <- 0 until 5200 if !found) {
        waitEmmcClkRising(dut)
        if (dut.io.datOe.toBoolean && (dut.io.datOut.toInt & 1) == 0) found = true
      }
      if (!found) return

      // Capture 4096 data bits (512 bytes, MSB first) from DAT0
      for (byteIdx <- 0 until 512) {
        var byte = 0
        for (bitIdx <- 7 to 0 by -1) {
          waitEmmcClkRising(dut)
          if ((dut.io.datOut.toInt & 1) != 0) byte |= (1 << bitIdx)
        }
        capturedWriteData(byteIdx) = byte
      }

      // Skip CRC-16 (16 bits) + end bit (1 bit)
      for (_ <- 0 until 17) waitEmmcClkRising(dut)

      // Wait for host to release bus
      waitEmmcClkRising(dut)

      // CRC status token on DAT0: start(0) + status[2:0] + check(1)
      val status = if (writeCrcOk) 2 else 5
      val statusBits = Seq((status >> 2) & 1, (status >> 1) & 1, status & 1)
      setDatIn0(dut, dat0 = false); waitEmmcClkRising(dut)   // start
      for (b <- statusBits) {
        setDatIn0(dut, dat0 = b == 1); waitEmmcClkRising(dut)
      }
      dut.io.datIn #= 0xF; waitEmmcClkRising(dut)    // check trigger

      // Busy on DAT0
      setDatIn0(dut, dat0 = false)
      for (_ <- 0 until 10) waitEmmcClkRising(dut)
      dut.io.datIn #= 0xF
    }

    def start(): Unit = {
      fork {
        dut.io.cmdIn #= true
        dut.io.datIn #= 0xF

        while (true) {
          waitEmmcClkRising(dut)

          // Detect command start: cmdOe=true && cmdOut=0 (start bit)
          if (dut.io.cmdOe.toBoolean && !dut.io.cmdOut.toBoolean) {
            // Capture remaining 47 bits of the 48-bit frame
            val cmdBits = new Array[Boolean](48)
            cmdBits(0) = false
            for (i <- 1 until 48) {
              waitEmmcClkRising(dut)
              cmdBits(i) = dut.io.cmdOut.toBoolean
            }

            // Decode cmd index (bits 2-7)
            val cmdIdx = (0 until 6).foldLeft(0) { (acc, i) =>
              acc | (if (cmdBits(2 + i)) 1 << (5 - i) else 0)
            }

            // N_CR gap (2 cycles)
            waitEmmcClkRising(dut)
            waitEmmcClkRising(dut)

            cmdIdx match {
              case 0 => // CMD0: no response

              case 1 => // CMD1 SEND_OP_COND: R3
                sendCmdResponse(crcHelper.buildR3(crcHelper.ocr))

              case 2 => // CMD2 ALL_SEND_CID: R2
                sendCmdResponse(crcHelper.buildR2(cidValue))

              case 3 => // CMD3 SET_RELATIVE_ADDR: R1
                sendCmdResponse(crcHelper.buildR1(3, 0x00000500))

              case 6 => // CMD6 SWITCH: R1 + busy on DAT0
                sendCmdResponse(crcHelper.buildR1(6, 0x00000900))
                setDatIn0(dut, dat0 = false)
                for (_ <- 0 until 20) waitEmmcClkRising(dut)
                dut.io.datIn #= 0xF

              case 7 => // CMD7 SELECT: R1
                sendCmdResponse(crcHelper.buildR1(7, 0x00000700))

              case 8 => // CMD8 SEND_EXT_CSD: R1 + data
                sendCmdResponse(crcHelper.buildR1(8, 0x00000900))
                sendSectorOnDat(sectorData)

              case 9 => // CMD9 SEND_CSD: R2
                sendCmdResponse(crcHelper.buildR2(csdValue))

              case 12 => // CMD12 STOP: R1 + brief busy
                sendCmdResponse(crcHelper.buildR1(12, 0x00000900))
                setDatIn0(dut, dat0 = false)
                for (_ <- 0 until 5) waitEmmcClkRising(dut)
                dut.io.datIn #= 0xF

              case 13 => // CMD13 STATUS: R1
                sendCmdResponse(crcHelper.buildR1(13, 0x00000900))

              case 16 => // CMD16 SET_BLOCKLEN: R1
                sendCmdResponse(crcHelper.buildR1(16, 0x00000900))

              case 17 => // CMD17 READ_SINGLE: R1 + sector
                sendCmdResponse(crcHelper.buildR1(17, 0x00000900))
                sendSectorOnDat(sectorData)

              case 18 => // CMD18 READ_MULTI: R1 + N sectors
                sendCmdResponse(crcHelper.buildR1(18, 0x00000900))
                for (_ <- 0 until sectorsToTransfer) sendSectorOnDat(sectorData)

              case 23 => // CMD23 SET_BLOCK_COUNT: R1
                sendCmdResponse(crcHelper.buildR1(23, 0x00000900))

              case 24 => // CMD24 WRITE_SINGLE: R1 + capture
                sendCmdResponse(crcHelper.buildR1(24, 0x00000900))
                captureWriteFromDat()

              case 25 => // CMD25 WRITE_MULTI: R1 + capture N
                sendCmdResponse(crcHelper.buildR1(25, 0x00000900))
                for (_ <- 0 until sectorsToTransfer) captureWriteFromDat()

              case 35 => sendCmdResponse(crcHelper.buildR1(35, 0x00000900))
              case 36 => sendCmdResponse(crcHelper.buildR1(36, 0x00000900))

              case 38 => // CMD38 ERASE: R1 + busy
                sendCmdResponse(crcHelper.buildR1(38, 0x00000900))
                setDatIn0(dut, dat0 = false)
                for (_ <- 0 until 20) waitEmmcClkRising(dut)
                dut.io.datIn #= 0xF

              case _ =>
                sendCmdResponse(crcHelper.buildR1(cmdIdx, 0x00000900))
            }
          }
        }
      }
    }
  }

  // ============================================================
  // Sticky capture for 1-cycle respValid pulses
  // ============================================================
  class ResponseCapture {
    var seen = false
    var status = 0
  }

  def forkResponseCapture(dut: EmmcController): ResponseCapture = {
    val cap = new ResponseCapture
    fork {
      while (true) {
        dut.clockDomain.waitRisingEdge()
        if (dut.io.respValid.toBoolean) {
          cap.seen = true
          cap.status = dut.io.respStatus.toInt
        }
      }
    }
    cap
  }

  def waitReady(dut: EmmcController, maxCycles: Int = 800000): Boolean = {
    for (_ <- 0 until maxCycles) {
      dut.clockDomain.waitRisingEdge()
      if (dut.io.ready.toBoolean) return true
    }
    false
  }

  def issueCommand(dut: EmmcController, cmdId: Int, lba: Long = 0, count: Int = 0): Unit = {
    dut.io.cmdId    #= cmdId
    dut.io.cmdLba   #= lba
    dut.io.cmdCount #= count
    dut.io.cmdValid #= true
    dut.clockDomain.waitRisingEdge()
    dut.io.cmdValid #= false
    dut.clockDomain.waitRisingEdge()
  }

  // ================================================================
  // Test 1: Init sequence reaches READY state
  // ================================================================
  test("Init sequence reaches READY state") {
    simConfig.compile(new EmmcController(EmmcControllerConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val stub = new ControllerCardStub(dut)
      stub.start()

      assert(waitReady(dut), "Controller did not reach READY state")
      assert(dut.io.infoValid.toBoolean, "infoValid not set")
      assert(dut.io.cid.toBigInt == cidValue,
        s"CID mismatch: 0x${dut.io.cid.toBigInt.toString(16)}")
      assert(dut.io.csd.toBigInt == csdValue,
        s"CSD mismatch: 0x${dut.io.csd.toBigInt.toString(16)}")
    }
  }

  // ================================================================
  // Test 2: Single sector read via CMD17
  // ================================================================
  test("Single sector read via CMD17") {
    simConfig.compile(new EmmcController(EmmcControllerConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val stub = new ControllerCardStub(dut)
      stub.sectorData = Array.tabulate(512)(i => (i * 7 + 0x42) & 0xFF)
      stub.start()
      val cap = forkResponseCapture(dut)

      assert(waitReady(dut), "Controller did not reach READY")

      issueCommand(dut, 0x03, lba = 100, count = 1)

      // Wait for rdSectorReady
      var sectorReady = false
      for (_ <- 0 until 800000 if !sectorReady) {
        dut.clockDomain.waitRisingEdge()
        if (dut.io.rdSectorReady.toBoolean) sectorReady = true
      }
      assert(sectorReady, "rdSectorReady not asserted")

      // Read data from sector buffer
      for (addr <- 0 until 512) {
        dut.io.uartRdAddr #= addr
        dut.clockDomain.waitRisingEdge(3) // BRAM read latency
        val data = dut.io.uartRdData.toInt
        assert(data == stub.sectorData(addr),
          s"Data[$addr]=0x${data.toHexString} expected 0x${stub.sectorData(addr).toHexString}")
      }

      // Acknowledge sector
      dut.io.rdSectorAck #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.rdSectorAck #= false

      // Wait for response
      for (_ <- 0 until 800000 if !cap.seen) dut.clockDomain.waitRisingEdge()
      assert(cap.seen, "Response not received")
      assert(cap.status == 0, s"Unexpected status: 0x${cap.status.toHexString}")
    }
  }

  // ================================================================
  // Test 3: Multi sector read via CMD18 with backpressure
  // ================================================================
  test("Multi sector read via CMD18 with backpressure") {
    simConfig.compile(new EmmcController(EmmcControllerConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val stub = new ControllerCardStub(dut)
      stub.sectorData = Array.tabulate(512)(i => (i * 3 + 0x11) & 0xFF)
      stub.sectorsToTransfer = 2
      stub.start()
      val cap = forkResponseCapture(dut)

      assert(waitReady(dut), "Controller did not reach READY")

      issueCommand(dut, 0x03, lba = 0, count = 2)

      for (sectorIdx <- 0 until 2) {
        // Wait for rdSectorReady
        var ready = false
        for (_ <- 0 until 800000 if !ready) {
          dut.clockDomain.waitRisingEdge()
          if (dut.io.rdSectorReady.toBoolean) ready = true
        }
        assert(ready, s"rdSectorReady not asserted for sector $sectorIdx")

        // Read data
        for (addr <- 0 until 512) {
          dut.io.uartRdAddr #= addr
          dut.clockDomain.waitRisingEdge(3)
          val data = dut.io.uartRdData.toInt
          assert(data == stub.sectorData(addr),
            s"Sector $sectorIdx data[$addr]=0x${data.toHexString} expected 0x${stub.sectorData(addr).toHexString}")
        }

        // Ack
        dut.io.rdSectorAck #= true
        dut.clockDomain.waitRisingEdge()
        dut.io.rdSectorAck #= false
      }

      // Wait for final response (after CMD12)
      for (_ <- 0 until 800000 if !cap.seen) dut.clockDomain.waitRisingEdge()
      assert(cap.seen, "Final response not received")
      assert(cap.status == 0, s"Unexpected status: 0x${cap.status.toHexString}")
    }
  }

  // ================================================================
  // Test 4: Single sector write via CMD24
  // ================================================================
  test("Single sector write via CMD24") {
    simConfig.compile(new EmmcController(EmmcControllerConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val stub = new ControllerCardStub(dut)
      stub.start()
      val cap = forkResponseCapture(dut)

      assert(waitReady(dut), "Controller did not reach READY")

      // Pre-fill write buffer (bank 0)
      val writeData = Array.tabulate(512)(i => (i * 5 + 0xAB) & 0xFF)
      dut.io.uartWrBank #= 0
      for (addr <- 0 until 512) {
        dut.io.uartWrData #= writeData(addr)
        dut.io.uartWrAddr #= addr
        dut.io.uartWrEn   #= true
        dut.clockDomain.waitRisingEdge()
      }
      dut.io.uartWrEn #= false

      // Issue write command with wrSectorValid (must be simultaneous)
      dut.io.cmdId             #= 0x04
      dut.io.cmdLba            #= 0
      dut.io.cmdCount          #= 1
      dut.io.cmdValid          #= true
      dut.io.uartWrSectorValid #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.cmdValid #= false
      dut.clockDomain.waitRisingEdge()
      dut.io.uartWrSectorValid #= false

      // Wait for response
      for (_ <- 0 until 800000 if !cap.seen) dut.clockDomain.waitRisingEdge()
      assert(cap.seen, "Write response not received")
      assert(cap.status == 0, s"Unexpected status: 0x${cap.status.toHexString}")

      // Verify captured write data
      for (i <- 0 until 512) {
        assert(stub.capturedWriteData(i) == writeData(i),
          s"Write data[$i]=0x${stub.capturedWriteData(i).toHexString} expected 0x${writeData(i).toHexString}")
      }
    }
  }

  // ================================================================
  // Test 5: Clock preset change via SET_CLK_DIV
  // ================================================================
  test("Clock preset change via SET_CLK_DIV") {
    simConfig.compile(new EmmcController(EmmcControllerConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val stub = new ControllerCardStub(dut)
      stub.start()
      val cap = forkResponseCapture(dut)

      assert(waitReady(dut), "Controller did not reach READY")

      // Set clock preset 3 (10 MHz)
      issueCommand(dut, 0x0D, lba = 3, count = 0)

      // Response is immediate (no eMMC command involved)
      for (_ <- 0 until 100 if !cap.seen) dut.clockDomain.waitRisingEdge()
      assert(cap.seen, "SET_CLK response not received")
      assert(cap.status == 0, s"Unexpected status: 0x${cap.status.toHexString}")
      assert(dut.io.dbgClkPreset.toInt == 3, s"Clock preset not updated: ${dut.io.dbgClkPreset.toInt}")
    }
  }

  // ================================================================
  // Test 6: SET_BUS_WIDTH command + read
  // ================================================================
  test("SET_BUS_WIDTH command succeeds") {
    simConfig.compile(new EmmcController(EmmcControllerConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val stub = new ControllerCardStub(dut)
      stub.start()
      val cap = forkResponseCapture(dut)

      assert(waitReady(dut), "Controller did not reach READY")

      // Set bus width to 4-bit
      issueCommand(dut, 0x11, lba = 1, count = 0)

      // Wait for response (CMD6 SWITCH + DAT0 busy wait)
      for (_ <- 0 until 800000 if !cap.seen) dut.clockDomain.waitRisingEdge()
      assert(cap.seen, "SET_BUS_WIDTH response not received")
      assert(cap.status == 0, s"Unexpected status: 0x${cap.status.toHexString}")
    }
  }

  // ================================================================
  // Test 7: REINIT resets bus width to 1-bit
  // ================================================================
  test("REINIT resets bus width to 1-bit") {
    simConfig.compile(new EmmcController(EmmcControllerConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val stub = new ControllerCardStub(dut)
      stub.start()

      assert(waitReady(dut), "Controller did not reach READY")

      // Set bus width to 4-bit
      val cap1 = forkResponseCapture(dut)
      issueCommand(dut, 0x11, lba = 1, count = 0)
      for (_ <- 0 until 800000 if !cap1.seen) dut.clockDomain.waitRisingEdge()
      assert(cap1.seen, "SET_BUS_WIDTH response not received")

      // Now reinit
      val cap2 = new ResponseCapture
      fork {
        while (true) {
          dut.clockDomain.waitRisingEdge()
          if (dut.io.respValid.toBoolean) {
            cap2.seen = true
            cap2.status = dut.io.respStatus.toInt
          }
        }
      }
      issueCommand(dut, 0x0B) // REINIT

      // Wait for reinit to complete and controller to be ready again
      assert(waitReady(dut), "Controller did not reach READY after REINIT")
    }
  }
}
