package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class UartRxSim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  val cpb = 20   // default clks_per_bit at 60MHz/3M

  // Generate UART waveform on RX pin
  def sendUartByte(dut: UartRx, b: Int, activeCpb: Int): Unit = {
    // Start bit
    dut.io.rx #= false
    dut.clockDomain.waitRisingEdge(activeCpb)
    // 8 data bits, LSB first
    for (i <- 0 until 8) {
      dut.io.rx #= ((b >> i) & 1) == 1
      dut.clockDomain.waitRisingEdge(activeCpb)
    }
    // Stop bit
    dut.io.rx #= true
    dut.clockDomain.waitRisingEdge(activeCpb)
  }

  // Generate bad frame (stop bit = 0)
  def sendBadStop(dut: UartRx, b: Int): Unit = {
    dut.io.rx #= false
    dut.clockDomain.waitRisingEdge(cpb)
    for (i <- 0 until 8) {
      dut.io.rx #= ((b >> i) & 1) == 1
      dut.clockDomain.waitRisingEdge(cpb)
    }
    // Bad stop bit (low instead of high)
    dut.io.rx #= false
    dut.clockDomain.waitRisingEdge(cpb)
    dut.io.rx #= true   // return to idle
  }

  // Wait for data_valid pulse, return (gotValid, data)
  def waitForValid(dut: UartRx, maxCycles: Int): (Boolean, Int) = {
    for (_ <- 0 until maxCycles) {
      dut.clockDomain.waitRisingEdge()
      if (dut.io.dataValid.toBoolean) {
        return (true, dut.io.dataOut.toInt)
      }
    }
    (false, 0)
  }

  def initDut(dut: UartRx): Unit = {
    dut.io.rx #= true
    dut.io.clksPerBit #= 0
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  def testReceiveByte(b: Int, name: String): Unit = {
    test(s"Receive 0x${b.toHexString} ($name)") {
      simConfig.compile(new UartRx()).doSim { dut =>
        initDut(dut)
        dut.clockDomain.waitRisingEdge(4)
        // Fork send + receive
        val sendThread = fork {
          sendUartByte(dut, b, cpb)
        }
        val (valid, data) = waitForValid(dut, cpb * 12)
        sendThread.join()
        assert(valid, s"0x${b.toHexString} - no data_valid")
        assert(data == b, s"0x${b.toHexString} - got 0x${data.toHexString}")
      }
    }
  }

  testReceiveByte(0x55, "alternating 01")
  testReceiveByte(0xAA, "alternating 10")
  testReceiveByte(0x00, "all zeros")
  testReceiveByte(0xFF, "all ones")

  test("Frame error (bad stop bit)") {
    simConfig.compile(new UartRx()).doSim { dut =>
      initDut(dut)
      dut.clockDomain.waitRisingEdge(4)
      val sendThread = fork {
        sendBadStop(dut, 0x42)
      }
      var gotFrameErr = false
      for (_ <- 0 until cpb * 12 if !gotFrameErr) {
        dut.clockDomain.waitRisingEdge()
        if (dut.io.frameErr.toBoolean) gotFrameErr = true
      }
      sendThread.join()
      assert(gotFrameErr, "frame error not detected")
    }
  }

  test("Recovery after frame error") {
    simConfig.compile(new UartRx()).doSim { dut =>
      initDut(dut)
      dut.clockDomain.waitRisingEdge(4)
      // Send bad frame
      sendBadStop(dut, 0x42)
      dut.clockDomain.waitRisingEdge(cpb * 4)
      // Send good frame
      val sendThread = fork {
        sendUartByte(dut, 0x7E, cpb)
      }
      val (valid, data) = waitForValid(dut, cpb * 12)
      sendThread.join()
      assert(valid, "recovery: no data_valid")
      assert(data == 0x7E, s"recovery: got 0x${data.toHexString}")
    }
  }

  test("Runtime CPB=16 (6M baud)") {
    simConfig.compile(new UartRx()).doSim { dut =>
      initDut(dut)
      dut.io.clksPerBit #= 16
      dut.clockDomain.waitRisingEdge(4)
      val sendThread = fork {
        sendUartByte(dut, 0xA5, 16)
      }
      val (valid, data) = waitForValid(dut, 16 * 12)
      sendThread.join()
      assert(valid && data == 0xA5, s"CPB=16: valid=$valid, data=0x${data.toHexString}")
    }
  }

  test("Runtime CPB=8 (12M baud)") {
    simConfig.compile(new UartRx()).doSim { dut =>
      initDut(dut)
      dut.io.clksPerBit #= 8
      dut.clockDomain.waitRisingEdge(4)
      val sendThread = fork {
        sendUartByte(dut, 0x3C, 8)
      }
      val (valid, data) = waitForValid(dut, 8 * 12)
      sendThread.join()
      assert(valid && data == 0x3C, s"CPB=8: valid=$valid, data=0x${data.toHexString}")
    }
  }

  test("Switch back to default CPB=0") {
    simConfig.compile(new UartRx()).doSim { dut =>
      initDut(dut)
      dut.io.clksPerBit #= 8
      dut.clockDomain.waitRisingEdge(4)
      sendUartByte(dut, 0x3C, 8)
      dut.clockDomain.waitRisingEdge(8 * 2)
      dut.io.clksPerBit #= 0
      dut.clockDomain.waitRisingEdge(4)
      val sendThread = fork {
        sendUartByte(dut, 0xB7, cpb)
      }
      val (valid, data) = waitForValid(dut, cpb * 12)
      sendThread.join()
      assert(valid && data == 0xB7, s"CPB=0 (default): valid=$valid, data=0x${data.toHexString}")
    }
  }
}
