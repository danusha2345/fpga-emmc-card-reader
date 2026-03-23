package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class SectorBufWrSim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  def initDut(dut: SectorBufWr): Unit = {
    dut.io.rdBank #= 0
    dut.io.rdAddr #= 0
    dut.io.wrBank #= 0
    dut.io.wrAddr #= 0
    dut.io.wrData #= 0
    dut.io.wrEn #= false
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  test("Write and read bank 0") {
    simConfig.compile(new SectorBufWr).doSim { dut =>
      initDut(dut)
      // Write 0xAB to bank 0, addr 42
      dut.io.wrBank #= 0
      dut.io.wrAddr #= 42
      dut.io.wrData #= 0xAB
      dut.io.wrEn #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.wrEn #= false
      // Read back (1 cycle for BRAM + 1 cycle for registered mux)
      dut.io.rdBank #= 0
      dut.io.rdAddr #= 42
      dut.clockDomain.waitRisingEdge()
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdData.toInt == 0xAB, s"bank 0: expected 0xAB, got 0x${dut.io.rdData.toInt.toHexString}")
    }
  }

  test("Write and read bank 15 (hi half)") {
    simConfig.compile(new SectorBufWr).doSim { dut =>
      initDut(dut)
      dut.io.wrBank #= 15
      dut.io.wrAddr #= 100
      dut.io.wrData #= 0xCD
      dut.io.wrEn #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.wrEn #= false
      dut.io.rdBank #= 15
      dut.io.rdAddr #= 100
      dut.clockDomain.waitRisingEdge()
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdData.toInt == 0xCD, s"bank 15: expected 0xCD, got 0x${dut.io.rdData.toInt.toHexString}")
    }
  }

  test("All 16 banks independent") {
    simConfig.compile(new SectorBufWr).doSim { dut =>
      initDut(dut)
      // Write distinct values to addr 0 of each bank
      for (bank <- 0 until 16) {
        dut.io.wrBank #= bank
        dut.io.wrAddr #= 0
        dut.io.wrData #= bank * 0x10 + 5
        dut.io.wrEn #= true
        dut.clockDomain.waitRisingEdge()
      }
      dut.io.wrEn #= false
      // Read back all
      for (bank <- 0 until 16) {
        dut.io.rdBank #= bank
        dut.io.rdAddr #= 0
        dut.clockDomain.waitRisingEdge()
        dut.clockDomain.waitRisingEdge()
        val expected = bank * 0x10 + 5
        assert(dut.io.rdData.toInt == expected,
          s"bank $bank: expected 0x${expected.toHexString}, got 0x${dut.io.rdData.toInt.toHexString}")
      }
    }
  }

  test("Fill sector and read back") {
    simConfig.compile(new SectorBufWr).doSim { dut =>
      initDut(dut)
      // Fill bank 3 with pattern
      for (i <- 0 until 512) {
        dut.io.wrBank #= 3
        dut.io.wrAddr #= i
        dut.io.wrData #= (i & 0xFF)
        dut.io.wrEn #= true
        dut.clockDomain.waitRisingEdge()
      }
      dut.io.wrEn #= false
      // Read back
      for (i <- 0 until 512) {
        dut.io.rdBank #= 3
        dut.io.rdAddr #= i
        dut.clockDomain.waitRisingEdge()
        dut.clockDomain.waitRisingEdge()
        assert(dut.io.rdData.toInt == (i & 0xFF),
          s"sector[${i}]: expected 0x${(i & 0xFF).toHexString}, got 0x${dut.io.rdData.toInt.toHexString}")
      }
    }
  }

  test("Concurrent write and read (different banks)") {
    simConfig.compile(new SectorBufWr).doSim { dut =>
      initDut(dut)
      // Pre-fill bank 0
      dut.io.wrBank #= 0
      dut.io.wrAddr #= 10
      dut.io.wrData #= 0x42
      dut.io.wrEn #= true
      dut.clockDomain.waitRisingEdge()

      // Simultaneously write to bank 8 and read from bank 0
      dut.io.wrBank #= 8
      dut.io.wrAddr #= 10
      dut.io.wrData #= 0x99
      dut.io.wrEn #= true
      dut.io.rdBank #= 0
      dut.io.rdAddr #= 10
      dut.clockDomain.waitRisingEdge()
      dut.io.wrEn #= false
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdData.toInt == 0x42,
        s"concurrent read: expected 0x42, got 0x${dut.io.rdData.toInt.toHexString}")

      // Verify bank 8 write
      dut.io.rdBank #= 8
      dut.io.rdAddr #= 10
      dut.clockDomain.waitRisingEdge()
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.rdData.toInt == 0x99,
        s"concurrent write verify: expected 0x99, got 0x${dut.io.rdData.toInt.toHexString}")
    }
  }
}
