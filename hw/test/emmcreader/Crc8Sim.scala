package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class Crc8Sim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  def feedByte(dut: Crc8, b: Int): Unit = {
    dut.io.dataIn #= b
    dut.io.enable #= true
    dut.clockDomain.waitRisingEdge()
    dut.io.enable #= false
    dut.clockDomain.waitRisingEdge()
  }

  def clearCrc(dut: Crc8): Unit = {
    dut.io.clear #= true
    dut.clockDomain.waitRisingEdge()
    dut.io.clear #= false
  }

  test("single byte 0x01") {
    simConfig.compile(new Crc8).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.dataIn #= 0
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      feedByte(dut, 0x01)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x07, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x07")
    }
  }

  test("PING packet [01,00,00]") {
    simConfig.compile(new Crc8).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.dataIn #= 0
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      Seq(0x01, 0x00, 0x00).foreach(b => feedByte(dut, b))
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x6B, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x6B")
    }
  }

  test("GET_INFO [02,00,00]") {
    simConfig.compile(new Crc8).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.dataIn #= 0
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      Seq(0x02, 0x00, 0x00).foreach(b => feedByte(dut, b))
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0xD6, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0xD6")
    }
  }

  test("unknown cmd [FF,00,00]") {
    simConfig.compile(new Crc8).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.dataIn #= 0
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      Seq(0xFF, 0x00, 0x00).foreach(b => feedByte(dut, b))
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x2B, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x2B")
    }
  }

  test("PING response [01,00,00,00]") {
    simConfig.compile(new Crc8).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.dataIn #= 0
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      Seq(0x01, 0x00, 0x00, 0x00).foreach(b => feedByte(dut, b))
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x16, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x16")
    }
  }

  test("single byte 0x55") {
    simConfig.compile(new Crc8).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.dataIn #= 0
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      feedByte(dut, 0x55)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0xAC, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0xAC")
    }
  }

  test("single byte 0xAA") {
    simConfig.compile(new Crc8).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.dataIn #= 0
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      feedByte(dut, 0xAA)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x5F, s"got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x5F")
    }
  }

  test("clear mid-stream") {
    simConfig.compile(new Crc8).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.dataIn #= 0
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      feedByte(dut, 0xFF)
      clearCrc(dut)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x00, s"clear mid-stream: got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x00")
    }
  }
}
