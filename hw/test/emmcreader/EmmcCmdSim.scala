package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class EmmcCmdSim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  def initDut(dut: EmmcCmd): Unit = {
    dut.io.clkEn #= false
    dut.io.cmdStart #= false
    dut.io.cmdIndex #= 0
    dut.io.cmdArgument #= 0
    dut.io.respTypeLong #= false
    dut.io.respExpected #= false
    dut.io.cmdIn #= true
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  // One eMMC cycle: pulse clkEn high for 1 sys_clk
  def emmcCycle(dut: EmmcCmd): Unit = {
    dut.io.clkEn #= true
    dut.clockDomain.waitRisingEdge()
    dut.io.clkEn #= false
    dut.clockDomain.waitRisingEdge()
  }

  // Wait for cmd_done pulse (up to maxCycles system clocks)
  def waitDone(dut: EmmcCmd, maxCycles: Int = 20): Boolean = {
    for (_ <- 0 until maxCycles) {
      dut.clockDomain.waitRisingEdge()
      if (dut.io.cmdDone.toBoolean) return true
    }
    false
  }

  val stub = new EmmcCardStub(null, null, null)

  test("CMD0 (no response)") {
    simConfig.compile(new EmmcCmd).doSim { dut =>
      initDut(dut)
      dut.io.cmdIndex #= 0
      dut.io.cmdArgument #= 0
      dut.io.respExpected #= false
      dut.io.respTypeLong #= false
      dut.io.cmdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.cmdStart #= false

      // CMD0 has no response: 48 bits send + S_DONE
      // Monitor cmdDone during clock cycles
      var done = false
      for (_ <- 0 until 60 if !done) {
        emmcCycle(dut)
        if (dut.io.cmdDone.toBoolean) done = true
        // Also check between eMMC cycles
        dut.clockDomain.waitRisingEdge()
        if (dut.io.cmdDone.toBoolean) done = true
      }
      assert(done, "CMD0: cmd_done not asserted")
    }
  }

  test("CMD1 with R3 response") {
    simConfig.compile(new EmmcCmd).doSim { dut =>
      initDut(dut)
      dut.io.cmdIndex #= 1
      dut.io.cmdArgument #= BigInt("40FF8080", 16).toLong
      dut.io.respExpected #= true
      dut.io.respTypeLong #= false
      dut.io.cmdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.cmdStart #= false

      // Clock out command (48+ bits)
      for (_ <- 0 until 55) emmcCycle(dut)

      // Send R3 response
      val r3 = stub.buildR3(0xC0FF8080)
      for (b <- r3) {
        dut.io.cmdIn #= b
        emmcCycle(dut)
      }
      dut.io.cmdIn #= true

      // Wait for done
      assert(waitDone(dut), "CMD1: cmd_done not asserted")
    }
  }

  test("CMD2 with R2 (136-bit) response") {
    simConfig.compile(new EmmcCmd).doSim { dut =>
      initDut(dut)
      dut.io.cmdIndex #= 2
      dut.io.cmdArgument #= 0
      dut.io.respExpected #= true
      dut.io.respTypeLong #= true
      dut.io.cmdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.cmdStart #= false

      for (_ <- 0 until 55) emmcCycle(dut)

      val cidData = BigInt("0123456789ABCDEF0123456789ABCDEF", 16)
      val r2 = stub.buildR2(cidData)
      var done = false
      for (b <- r2 if !done) {
        dut.io.cmdIn #= b
        emmcCycle(dut)
        if (dut.io.cmdDone.toBoolean) done = true
        dut.clockDomain.waitRisingEdge()
        if (dut.io.cmdDone.toBoolean) done = true
      }
      dut.io.cmdIn #= true
      // Also check a few more cycles in case pulse comes late
      if (!done) done = waitDone(dut)

      assert(done, "CMD2: cmd_done not asserted")
      val respData = dut.io.respData.toBigInt
      assert(respData == cidData, s"CMD2: resp_data mismatch: got 0x${respData.toString(16)}")
    }
  }

  test("CMD3 with R1 response and CRC check") {
    simConfig.compile(new EmmcCmd).doSim { dut =>
      initDut(dut)
      dut.io.cmdIndex #= 3
      dut.io.cmdArgument #= 0x00010000L
      dut.io.respExpected #= true
      dut.io.respTypeLong #= false
      dut.io.cmdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.cmdStart #= false

      for (_ <- 0 until 55) emmcCycle(dut)

      val r1 = stub.buildR1(3, 0x00000900)
      for (b <- r1) {
        dut.io.cmdIn #= b
        emmcCycle(dut)
      }
      dut.io.cmdIn #= true

      assert(waitDone(dut), "CMD3: cmd_done not asserted")
      assert(!dut.io.cmdCrcErr.toBoolean, "CMD3: unexpected CRC error")
      assert(dut.io.respStatus.toInt == 0x00000900, s"CMD3: resp_status=0x${dut.io.respStatus.toInt.toHexString}")
    }
  }

  test("Timeout when no response") {
    simConfig.compile(new EmmcCmd).doSim { dut =>
      initDut(dut)
      dut.io.cmdIndex #= 13
      dut.io.cmdArgument #= 0
      dut.io.respExpected #= true
      dut.io.respTypeLong #= false
      dut.io.cmdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.cmdStart #= false

      // Clock out command + wait for timeout (1024+ clkEn cycles)
      var done = false
      var timedOut = false
      for (_ <- 0 until 1200 if !done) {
        emmcCycle(dut)
        if (dut.io.cmdDone.toBoolean) {
          done = true
          timedOut = dut.io.cmdTimeout.toBoolean
        }
      }
      assert(done, "Timeout: cmd_done not asserted")
      assert(timedOut, "Timeout: cmd_timeout not asserted")
    }
  }
}
