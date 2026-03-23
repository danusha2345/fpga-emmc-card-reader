package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class Ft245FifoSim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  def initDut(dut: Ft245Fifo): Unit = {
    dut.io.fifoRxfN     #= true   // no data available
    dut.io.fifoTxeN     #= true   // no room (safe default)
    dut.io.fifoDataRead #= 0
    dut.io.txDataIn     #= 0
    dut.io.txDataValid  #= false
    dut.io.rxSuppress   #= false
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  test("Idle state: RD# and WR# high, data bus hi-z") {
    simConfig.compile(new Ft245Fifo).doSim { dut =>
      initDut(dut)
      dut.clockDomain.waitRisingEdge(4)
      assert(dut.io.fifoRdN.toBoolean, "RD# should be high in idle")
      assert(dut.io.fifoWrN.toBoolean, "WR# should be high in idle")
      assert(!dut.io.fifoDataOe.toBoolean, "data OE should be low in idle")
      assert(!dut.io.rxDataValid.toBoolean, "rxDataValid should be low in idle")
      assert(!dut.io.txBusy.toBoolean, "txBusy should be low in idle")
    }
  }

  test("Read single byte from FT232H") {
    simConfig.compile(new Ft245Fifo).doSim { dut =>
      initDut(dut)

      // FT signals data available
      dut.io.fifoRxfN #= false
      dut.io.fifoDataRead #= 0xA5

      // Wait for sync pipeline (2 FF) + FSM to react
      dut.clockDomain.waitRisingEdge(6)

      // Should see rxDataValid pulse with correct data
      var gotValid = false
      var rxByte = 0
      for (_ <- 0 until 10) {
        if (dut.io.rxDataValid.toBoolean && !gotValid) {
          gotValid = true
          rxByte = dut.io.rxDataOut.toInt
        }
        dut.clockDomain.waitRisingEdge()
      }
      assert(gotValid, "rxDataValid pulse expected")
      assert(rxByte == 0xA5, f"expected 0xA5, got 0x$rxByte%02X")
    }
  }

  test("Read multiple bytes sequentially") {
    simConfig.compile(new Ft245Fifo).doSim { dut =>
      initDut(dut)

      val testData = Seq(0x55, 0xAA, 0x01, 0xFF)
      val received = scala.collection.mutable.ArrayBuffer[Int]()

      for (byte <- testData) {
        // Present byte: assert RXF# low with data
        dut.io.fifoRxfN #= false
        dut.io.fifoDataRead #= byte

        // Wait for rxDataValid pulse (through sync + read cycle)
        var gotByte = false
        for (_ <- 0 until 15 if !gotByte) {
          dut.clockDomain.waitRisingEdge()
          // Model FT232H: deassert RXF# after RD# goes low (byte consumed)
          if (!dut.io.fifoRdN.toBoolean) {
            dut.io.fifoRxfN #= true
          }
          if (dut.io.rxDataValid.toBoolean) {
            received += dut.io.rxDataOut.toInt
            gotByte = true
          }
        }

        // Gap between bytes (let sync pipeline settle)
        dut.clockDomain.waitRisingEdge(6)
      }

      assert(received.length == testData.length,
        s"expected ${testData.length} bytes, got ${received.length}")
      for (i <- testData.indices) {
        assert(received(i) == testData(i),
          f"byte $i: expected 0x${testData(i)}%02X, got 0x${received(i)}%02X")
      }
    }
  }

  test("Write single byte to FT232H") {
    simConfig.compile(new Ft245Fifo).doSim { dut =>
      initDut(dut)

      // Signal room in TX buffer
      dut.io.fifoTxeN #= false
      dut.clockDomain.waitRisingEdge(4)

      // Send byte
      dut.io.txDataIn    #= 0x3C
      dut.io.txDataValid #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.txDataValid #= false

      // txBusy should go high
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.txBusy.toBoolean, "txBusy should be high after txDataValid")

      // Wait for write cycle to complete
      var wrNWentLow = false
      var writtenData = 0
      for (_ <- 0 until 10) {
        if (!dut.io.fifoWrN.toBoolean) {
          wrNWentLow = true
          writtenData = dut.io.fifoDataWrite.toInt
        }
        dut.clockDomain.waitRisingEdge()
      }

      assert(wrNWentLow, "WR# should go low during write cycle")
      assert(writtenData == 0x3C, f"expected write data 0x3C, got 0x$writtenData%02X")

      // txBusy should return low after cycle
      dut.clockDomain.waitRisingEdge(4)
      assert(!dut.io.txBusy.toBoolean, "txBusy should be low after write completes")
    }
  }

  test("Write multiple bytes sequentially") {
    simConfig.compile(new Ft245Fifo).doSim { dut =>
      initDut(dut)

      dut.io.fifoTxeN #= false
      dut.clockDomain.waitRisingEdge(4)

      val testData = Seq(0x11, 0x22, 0x33, 0x44)
      val written = scala.collection.mutable.ArrayBuffer[Int]()

      for (byte <- testData) {
        // Wait until not busy
        while (dut.io.txBusy.toBoolean) {
          // Capture data during WR# low
          if (!dut.io.fifoWrN.toBoolean) {
            written += dut.io.fifoDataWrite.toInt
          }
          dut.clockDomain.waitRisingEdge()
        }

        dut.io.txDataIn    #= byte
        dut.io.txDataValid #= true
        dut.clockDomain.waitRisingEdge()
        dut.io.txDataValid #= false
      }

      // Wait for last byte
      for (_ <- 0 until 10) {
        if (!dut.io.fifoWrN.toBoolean) {
          written += dut.io.fifoDataWrite.toInt
        }
        dut.clockDomain.waitRisingEdge()
      }

      assert(written.length >= testData.length,
        s"expected ${testData.length} writes, got ${written.length}")
    }
  }

  test("TX priority over RX") {
    simConfig.compile(new Ft245Fifo).doSim { dut =>
      initDut(dut)

      // Queue TX data FIRST (before sync pipeline sees RXF#/TXE#)
      dut.io.txDataIn    #= 0xCC
      dut.io.txDataValid #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.txDataValid #= false

      // Now enable both RXF# and TXE# simultaneously
      dut.io.fifoRxfN #= false
      dut.io.fifoTxeN #= false
      dut.io.fifoDataRead #= 0xBB

      // After sync settles, TX should happen first (WR# goes low before RD#)
      var firstWrLow = false
      var firstRdLow = false
      for (_ <- 0 until 20) {
        if (!dut.io.fifoWrN.toBoolean && !firstRdLow) firstWrLow = true
        if (!dut.io.fifoRdN.toBoolean && !firstWrLow) firstRdLow = true
        dut.clockDomain.waitRisingEdge()
      }

      assert(firstWrLow, "TX (WR#) should take priority when txPending")
    }
  }

  test("Metastability sync: RXF# needs 2 cycles") {
    simConfig.compile(new Ft245Fifo).doSim { dut =>
      initDut(dut)

      // Assert RXF# and check RD# does NOT react for 2 cycles
      dut.io.fifoRxfN #= false
      dut.io.fifoDataRead #= 0x42

      // Cycle 0 and 1: RD# should still be high (sync pipeline)
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.fifoRdN.toBoolean, "RD# should be high after 1 cycle (sync)")
      dut.clockDomain.waitRisingEdge()
      assert(dut.io.fifoRdN.toBoolean, "RD# should be high after 2 cycles (sync)")

      // After sync settles, RD# should go low
      var rdWentLow = false
      for (_ <- 0 until 4) {
        dut.clockDomain.waitRisingEdge()
        if (!dut.io.fifoRdN.toBoolean) rdWentLow = true
      }
      assert(rdWentLow, "RD# should go low after sync pipeline settles")
    }
  }

  test("No activity when FT not connected (RXF#/TXE# pulled high)") {
    simConfig.compile(new Ft245Fifo).doSim { dut =>
      initDut(dut)

      // Simulate disconnected state (pull-ups keep signals high)
      dut.io.fifoRxfN #= true
      dut.io.fifoTxeN #= true

      // Try to send data
      dut.io.txDataIn    #= 0xDD
      dut.io.txDataValid #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.txDataValid #= false

      // TX should be pending but WR# should NOT activate (TXE# high = no room)
      for (_ <- 0 until 10) {
        assert(dut.io.fifoWrN.toBoolean, "WR# should stay high when TXE# is high")
        assert(dut.io.fifoRdN.toBoolean, "RD# should stay high when RXF# is high")
        dut.clockDomain.waitRisingEdge()
      }

      // txBusy should be high (data pending)
      assert(dut.io.txBusy.toBoolean, "txBusy should be high (data waiting)")

      // Now enable TXE# and it should complete
      dut.io.fifoTxeN #= false
      for (_ <- 0 until 10) {
        dut.clockDomain.waitRisingEdge()
      }
      assert(!dut.io.txBusy.toBoolean, "txBusy should clear after TXE# enables")
    }
  }

  test("Data bus direction: hi-z during read, driven during write") {
    simConfig.compile(new Ft245Fifo).doSim { dut =>
      initDut(dut)

      // Read: OE should be low
      dut.io.fifoRxfN #= false
      dut.io.fifoDataRead #= 0xEE
      dut.clockDomain.waitRisingEdge(6)

      var oeInRead = true
      for (_ <- 0 until 5) {
        if (!dut.io.fifoRdN.toBoolean) {
          oeInRead = dut.io.fifoDataOe.toBoolean
        }
        dut.clockDomain.waitRisingEdge()
      }
      assert(!oeInRead, "OE should be low during read (FPGA not driving)")

      dut.io.fifoRxfN #= true
      dut.clockDomain.waitRisingEdge(4)

      // Write: OE should be high
      dut.io.fifoTxeN #= false
      dut.clockDomain.waitRisingEdge(4)
      dut.io.txDataIn    #= 0x77
      dut.io.txDataValid #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.txDataValid #= false

      var oeInWrite = false
      for (_ <- 0 until 10) {
        if (!dut.io.fifoWrN.toBoolean) {
          oeInWrite = dut.io.fifoDataOe.toBoolean
        }
        dut.clockDomain.waitRisingEdge()
      }
      assert(oeInWrite, "OE should be high during write (FPGA driving)")
    }
  }
}
