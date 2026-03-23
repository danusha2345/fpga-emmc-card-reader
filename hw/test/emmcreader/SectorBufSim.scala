package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class SectorBufSim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  def initDut(dut: SectorBuf): Unit = {
    dut.io.bufSelA #= 0
    dut.io.addrA #= 0
    dut.io.wdataA #= 0
    dut.io.weA #= false
    dut.io.bufSelB #= 0
    dut.io.addrB #= 0
    dut.io.wdataB #= 0
    dut.io.weB #= false
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  test("Port A write then read") {
    simConfig.compile(new SectorBuf).doSim { dut =>
      initDut(dut)
      // Write 0xAB to bank 0, addr 42
      dut.io.bufSelA #= 0
      dut.io.addrA #= 42
      dut.io.wdataA #= 0xAB
      dut.io.weA #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.weA #= false
      // Read back (1-cycle latency)
      dut.io.addrA #= 42
      dut.clockDomain.waitRisingEdge()
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdataA.toInt == 0xAB, s"Port A read: expected 0xAB, got 0x${dut.io.rdataA.toInt.toHexString}")
    }
  }

  test("Port B write then read") {
    simConfig.compile(new SectorBuf).doSim { dut =>
      initDut(dut)
      dut.io.bufSelB #= 1
      dut.io.addrB #= 100
      dut.io.wdataB #= 0xCD
      dut.io.weB #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.weB #= false
      dut.io.addrB #= 100
      dut.clockDomain.waitRisingEdge()
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdataB.toInt == 0xCD, s"Port B read: expected 0xCD, got 0x${dut.io.rdataB.toInt.toHexString}")
    }
  }

  test("Cross-port: A writes, B reads") {
    simConfig.compile(new SectorBuf).doSim { dut =>
      initDut(dut)
      // Write via Port A
      dut.io.bufSelA #= 0
      dut.io.addrA #= 200
      dut.io.wdataA #= 0x55
      dut.io.weA #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.weA #= false
      // Read via Port B
      dut.io.bufSelB #= 0
      dut.io.addrB #= 200
      dut.clockDomain.waitRisingEdge()
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdataB.toInt == 0x55, s"Cross-port: expected 0x55, got 0x${dut.io.rdataB.toInt.toHexString}")
    }
  }

  test("Bank independence") {
    simConfig.compile(new SectorBuf).doSim { dut =>
      initDut(dut)
      // Write 0xAA to bank 0, addr 0
      dut.io.bufSelA #= 0
      dut.io.addrA #= 0
      dut.io.wdataA #= 0xAA
      dut.io.weA #= true
      dut.clockDomain.waitRisingEdge()
      // Write 0xBB to bank 1, addr 0
      dut.io.bufSelA #= 1
      dut.io.addrA #= 0
      dut.io.wdataA #= 0xBB
      dut.clockDomain.waitRisingEdge()
      dut.io.weA #= false

      // Read bank 0
      dut.io.bufSelA #= 0
      dut.io.addrA #= 0
      dut.clockDomain.waitRisingEdge()
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdataA.toInt == 0xAA, s"Bank 0: expected 0xAA, got 0x${dut.io.rdataA.toInt.toHexString}")

      // Read bank 1
      dut.io.bufSelA #= 1
      dut.io.addrA #= 0
      dut.clockDomain.waitRisingEdge()
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdataA.toInt == 0xBB, s"Bank 1: expected 0xBB, got 0x${dut.io.rdataA.toInt.toHexString}")
    }
  }

  test("Write then immediate read returns written data") {
    simConfig.compile(new SectorBuf).doSim { dut =>
      initDut(dut)
      // Write 0xEF to addr 50
      dut.io.bufSelA #= 0
      dut.io.addrA #= 50
      dut.io.wdataA #= 0xEF
      dut.io.weA #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.weA #= false
      // Read same address — 1 cycle latency for BRAM output
      dut.io.addrA #= 50
      dut.clockDomain.waitRisingEdge()
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdataA.toInt == 0xEF, s"Read after write: expected 0xEF, got 0x${dut.io.rdataA.toInt.toHexString}")
    }
  }

  test("Full sector fill and read back") {
    simConfig.compile(new SectorBuf).doSim { dut =>
      initDut(dut)
      // Fill bank 0 with pattern
      for (i <- 0 until 512) {
        dut.io.bufSelA #= 0
        dut.io.addrA #= i
        dut.io.wdataA #= (i & 0xFF)
        dut.io.weA #= true
        dut.clockDomain.waitRisingEdge()
      }
      dut.io.weA #= false
      // Read back via Port B
      for (i <- 0 until 512) {
        dut.io.bufSelB #= 0
        dut.io.addrB #= i
        dut.clockDomain.waitRisingEdge()
        dut.clockDomain.waitRisingEdge()
        assert(dut.io.rdataB.toInt == (i & 0xFF),
          s"sector[$i]: expected 0x${(i & 0xFF).toHexString}, got 0x${dut.io.rdataB.toInt.toHexString}")
      }
    }
  }
}
