package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class Crc7Sim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  def feedByte(dut: Crc7, b: Int): Unit = {
    for (i <- 7 to 0 by -1) {
      dut.io.bitIn #= ((b >> i) & 1) == 1
      dut.io.enable #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.enable #= false
      dut.clockDomain.waitRisingEdge()
    }
  }

  def feedBytes(dut: Crc7, bytes: Seq[Int]): Unit = {
    bytes.foreach(b => feedByte(dut, b))
  }

  def clearCrc(dut: Crc7): Unit = {
    dut.io.clear #= true
    dut.clockDomain.waitRisingEdge()
    dut.io.clear #= false
  }

  test("CMD0 (GO_IDLE_STATE)") {
    simConfig.compile(new Crc7).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      // CMD0: 0x40 0x00 0x00 0x00 0x00
      feedBytes(dut, Seq(0x40, 0x00, 0x00, 0x00, 0x00))
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x4A, s"CMD0: got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x4A")
    }
  }

  test("CMD1 (SEND_OP_COND, arg=0x40FF8000)") {
    simConfig.compile(new Crc7).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      feedBytes(dut, Seq(0x41, 0x40, 0xFF, 0x80, 0x00))
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x05, s"CMD1: got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x05")
    }
  }

  test("CMD2 (ALL_SEND_CID)") {
    simConfig.compile(new Crc7).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      feedBytes(dut, Seq(0x42, 0x00, 0x00, 0x00, 0x00))
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x26, s"CMD2: got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x26")
    }
  }

  test("CMD3 (SET_RELATIVE_ADDR)") {
    simConfig.compile(new Crc7).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      clearCrc(dut)
      feedBytes(dut, Seq(0x43, 0x00, 0x01, 0x00, 0x00))
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x3F, s"CMD3: got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x3F")
    }
  }

  test("clear resets CRC") {
    simConfig.compile(new Crc7).doSim { dut =>
      dut.clockDomain.forkStimulus(10)
      dut.io.clear #= false
      dut.io.enable #= false
      dut.io.bitIn #= false
      dut.clockDomain.waitRisingEdge(4)

      feedByte(dut, 0xFF)
      clearCrc(dut)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.crcOut.toInt == 0x00, s"clear: got 0x${dut.io.crcOut.toInt.toHexString}, expected 0x00")
    }
  }
}
