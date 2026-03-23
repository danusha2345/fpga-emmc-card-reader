package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class UartTxSim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  val cpb = 20   // default clks_per_bit at 60MHz/3M

  // Capture a UART byte from the TX line at given CPB
  def captureByte(dut: UartTx, activeCpb: Int): Int = {
    // Wait for start bit (tx goes low)
    waitUntil(dut.io.tx.toBoolean == false)
    // Advance to middle of start bit
    dut.clockDomain.waitRisingEdge(activeCpb / 2)
    assert(!dut.io.tx.toBoolean, "start bit not low")
    // Sample 8 data bits (LSB first)
    var byte = 0
    for (i <- 0 until 8) {
      dut.clockDomain.waitRisingEdge(activeCpb)
      if (dut.io.tx.toBoolean) byte |= (1 << i)
    }
    // Check stop bit
    dut.clockDomain.waitRisingEdge(activeCpb)
    assert(dut.io.tx.toBoolean, "stop bit not high")
    byte
  }

  def sendByte(dut: UartTx, b: Int): Unit = {
    dut.io.dataIn #= b
    dut.io.dataValid #= true
    dut.clockDomain.waitRisingEdge()
    dut.io.dataValid #= false
  }

  def initDut(dut: UartTx): Unit = {
    dut.io.dataIn #= 0
    dut.io.dataValid #= false
    dut.io.clksPerBit #= 0
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  test("TX idle state") {
    simConfig.compile(new UartTx()).doSim { dut =>
      initDut(dut)
      dut.clockDomain.waitRisingEdge(2)
      assert(dut.io.tx.toBoolean, "TX not idle high")
      assert(!dut.io.busy.toBoolean, "busy should be 0 in idle")
    }
  }

  test("Send 0x55") {
    simConfig.compile(new UartTx()).doSim { dut =>
      initDut(dut)
      sendByte(dut, 0x55)
      val captured = captureByte(dut, cpb)
      assert(captured == 0x55, s"sent 0x55, captured 0x${captured.toHexString}")
    }
  }

  test("Send 0xAA") {
    simConfig.compile(new UartTx()).doSim { dut =>
      initDut(dut)
      sendByte(dut, 0xAA)
      val captured = captureByte(dut, cpb)
      assert(captured == 0xAA, s"sent 0xAA, captured 0x${captured.toHexString}")
    }
  }

  test("Send 0x00") {
    simConfig.compile(new UartTx()).doSim { dut =>
      initDut(dut)
      sendByte(dut, 0x00)
      val captured = captureByte(dut, cpb)
      assert(captured == 0x00, s"sent 0x00, captured 0x${captured.toHexString}")
    }
  }

  test("Send 0xFF") {
    simConfig.compile(new UartTx()).doSim { dut =>
      initDut(dut)
      sendByte(dut, 0xFF)
      val captured = captureByte(dut, cpb)
      assert(captured == 0xFF, s"sent 0xFF, captured 0x${captured.toHexString}")
    }
  }

  test("Busy signal during transmission") {
    simConfig.compile(new UartTx()).doSim { dut =>
      initDut(dut)
      sendByte(dut, 0x42)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.busy.toBoolean, "busy should be 1 during TX")
      waitUntil(!dut.io.busy.toBoolean)
      dut.clockDomain.waitRisingEdge(2)
    }
  }

  test("Runtime CPB=16 (6M baud)") {
    simConfig.compile(new UartTx()).doSim { dut =>
      initDut(dut)
      dut.io.clksPerBit #= 16
      dut.clockDomain.waitRisingEdge(4)
      sendByte(dut, 0xA5)
      val captured = captureByte(dut, 16)
      assert(captured == 0xA5, s"CPB=16: sent 0xA5, captured 0x${captured.toHexString}")
    }
  }

  test("Runtime CPB=8 (12M baud)") {
    simConfig.compile(new UartTx()).doSim { dut =>
      initDut(dut)
      dut.io.clksPerBit #= 8
      dut.clockDomain.waitRisingEdge(4)
      sendByte(dut, 0x3C)
      val captured = captureByte(dut, 8)
      assert(captured == 0x3C, s"CPB=8: sent 0x3C, captured 0x${captured.toHexString}")
    }
  }

  test("Switch back to default CPB=0") {
    simConfig.compile(new UartTx()).doSim { dut =>
      initDut(dut)
      dut.io.clksPerBit #= 8
      dut.clockDomain.waitRisingEdge(4)
      sendByte(dut, 0x3C)
      captureByte(dut, 8)
      waitUntil(!dut.io.busy.toBoolean)
      dut.clockDomain.waitRisingEdge(16)

      // Switch back to default
      dut.io.clksPerBit #= 0
      dut.clockDomain.waitRisingEdge(4)
      sendByte(dut, 0xB7)
      val captured = captureByte(dut, cpb)
      assert(captured == 0xB7, s"CPB=0 (default): sent 0xB7, captured 0x${captured.toHexString}")
    }
  }
}
