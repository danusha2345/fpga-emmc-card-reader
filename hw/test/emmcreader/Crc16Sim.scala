package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class Crc16Sim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  def feedByte(dut: Crc16, b: Int): Unit = {
    for (i <- 7 to 0 by -1) {
      dut.io.bitIn #= ((b >> i) & 1) == 1
      dut.io.enable #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.enable #= false
      dut.clockDomain.waitRisingEdge()
    }
  }

  def clearCrc(dut: Crc16): Unit = {
    dut.io.clear #= true
    dut.clockDomain.waitRisingEdge()
    dut.io.clear #= false
  }

  test("4-byte [01,02,03,04]") {
    simConfig.compile(new Crc16).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      Seq(0x01, 0x02, 0x03, 0x04).foreach(b => feedByte(dut, b))
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x0D03, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x0D03")
    }
  }

  test("single byte 0x55") {
    simConfig.compile(new Crc16).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      feedByte(dut, 0x55)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x0A50, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x0A50")
    }
  }

  test("512 bytes all-zeros") {
    simConfig.compile(new Crc16).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      for (_ <- 0 until 512) feedByte(dut, 0x00)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x0000, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x0000")
    }
  }

  test("512 bytes all-FF") {
    simConfig.compile(new Crc16).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      for (_ <- 0 until 512) feedByte(dut, 0xFF)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x7FA1, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x7FA1")
    }
  }

  test("clear resets CRC") {
    simConfig.compile(new Crc16).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      feedByte(dut, 0xAB)
      clearCrc(dut)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x0000, s"clear: got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x0000")
    }
  }
}
