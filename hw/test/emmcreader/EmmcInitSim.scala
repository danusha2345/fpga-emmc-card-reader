package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class EmmcInitSim extends AnyFunSuite {

  // Use small clkFreq for fast simulation: TICKS_1MS=10, TICKS_50MS=500
  val testClkFreq = 10000

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  def initDut(dut: EmmcInit): Unit = {
    dut.io.initStart  #= false
    dut.io.cmdDone    #= false
    dut.io.cmdTimeout #= false
    dut.io.cmdCrcErr  #= false
    dut.io.respStatus #= 0
    dut.io.respData   #= BigInt(0)
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  // Sticky capture for 1-cycle pulses
  class InitCapture {
    var doneSeen = false
    var errorSeen = false
    var infoValidSeen = false
    var capturedCid: BigInt = 0
    var capturedCsd: BigInt = 0
  }

  def forkInitCapture(dut: EmmcInit): InitCapture = {
    val cap = new InitCapture
    fork {
      while (true) {
        dut.clockDomain.waitRisingEdge()
        if (dut.io.initDone.toBoolean) cap.doneSeen = true
        if (dut.io.initError.toBoolean) cap.errorSeen = true
        if (dut.io.infoValid.toBoolean) {
          cap.infoValidSeen = true
          cap.capturedCid = dut.io.cidReg.toBigInt
          cap.capturedCsd = dut.io.csdReg.toBigInt
        }
      }
    }
    cap
  }

  val cidValue = BigInt("DEADBEEF12345678ABCDEF0123456789", 16)
  val csdValue = BigInt("CAFEBABE98765432FEDCBA9876543210", 16)

  // Mock CMD responder: detects cmdStart pulse, responds 2 cycles later
  class CmdResponder(dut: EmmcInit) {
    var cmd1ReadyAfter = 0
    var injectTimeout = false
    var timeoutCmdIdx = 0
    var injectCrcErr = false
    var crcErrCmdIdx = 0
    var cmd1RetryCount = 0

    def start(): Unit = {
      fork {
        var prev = false
        var prevPrev = false
        var capturedIdx = 0

        while (true) {
          dut.clockDomain.waitRisingEdge()

          val cur = dut.io.cmdStart.toBoolean
          // Capture index on first rising edge of cmdStart
          if (cur && !prev) capturedIdx = dut.io.cmdIndex.toInt
          val rising = prev && !prevPrev

          // Default: clear pulses
          dut.io.cmdDone    #= false
          dut.io.cmdTimeout #= false
          dut.io.cmdCrcErr  #= false

          if (rising) {
            if (injectTimeout && capturedIdx == timeoutCmdIdx) {
              dut.io.cmdDone    #= true
              dut.io.cmdTimeout #= true
            } else if (injectCrcErr && capturedIdx == crcErrCmdIdx) {
              dut.io.cmdDone   #= true
              dut.io.cmdCrcErr #= true
              // For CMD1 CRC error, still provide valid OCR (R3 CRC ignored)
              if (capturedIdx == 1) dut.io.respStatus #= 0xC0FF8080L
            } else {
              capturedIdx match {
                case 0 =>
                  dut.io.cmdDone #= true
                case 1 =>
                  dut.io.cmdDone #= true
                  if (cmd1RetryCount >= cmd1ReadyAfter)
                    dut.io.respStatus #= 0xC0FF8080L  // ready + sector mode
                  else
                    dut.io.respStatus #= 0x00FF8080L  // not ready
                  cmd1RetryCount += 1
                case 2 =>
                  dut.io.cmdDone #= true
                  dut.io.respData #= cidValue
                case 3 =>
                  dut.io.cmdDone    #= true
                  dut.io.respStatus #= 0x00000500L
                case 9 =>
                  dut.io.cmdDone #= true
                  dut.io.respData #= csdValue
                case 7 =>
                  dut.io.cmdDone    #= true
                  dut.io.respStatus #= 0x00000700L
                case 16 =>
                  dut.io.cmdDone    #= true
                  dut.io.respStatus #= 0x00000900L
                case _ =>
                  dut.io.cmdDone    #= true
                  dut.io.respStatus #= 0x00000900L
              }
            }
          }

          prevPrev = prev
          prev = cur
        }
      }
    }
  }

  def startAndWait(dut: EmmcInit, cap: InitCapture, maxCycles: Int = 10000): Unit = {
    dut.io.initStart #= true
    dut.clockDomain.waitRisingEdge(2)
    dut.io.initStart #= false

    for (_ <- 0 until maxCycles if !cap.doneSeen && !cap.errorSeen) {
      dut.clockDomain.waitRisingEdge()
    }
    dut.clockDomain.waitRisingEdge(4) // settle
  }

  // ================================================================
  // Test 1: Happy path — full init sequence
  // ================================================================
  test("Happy path init sequence") {
    simConfig.compile(new EmmcInit(EmmcInitConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val cap = forkInitCapture(dut)
      val resp = new CmdResponder(dut)
      resp.cmd1ReadyAfter = 0
      resp.start()

      startAndWait(dut, cap)

      assert(cap.doneSeen, "initDone not set")
      assert(!cap.errorSeen, "unexpected initError")
      assert(dut.io.useFastClk.toBoolean, "useFastClk not set")
      assert(cap.infoValidSeen, "infoValid not seen")
      assert(cap.capturedCid == cidValue,
        s"CID mismatch: 0x${cap.capturedCid.toString(16)}")
      assert(cap.capturedCsd == csdValue,
        s"CSD mismatch: 0x${cap.capturedCsd.toString(16)}")
    }
  }

  // ================================================================
  // Test 2: CMD1 polling — ready after 5 retries
  // ================================================================
  test("CMD1 polling with 5 retries") {
    simConfig.compile(new EmmcInit(EmmcInitConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val cap = forkInitCapture(dut)
      val resp = new CmdResponder(dut)
      resp.cmd1ReadyAfter = 5
      resp.start()

      startAndWait(dut, cap)

      assert(cap.doneSeen, "initDone not set after CMD1 retries")
      assert(!cap.errorSeen, "unexpected initError")
    }
  }

  // ================================================================
  // Test 3: CMD1 extended polling — ready after 50 retries
  // ================================================================
  test("CMD1 extended polling with 50 retries") {
    simConfig.compile(new EmmcInit(EmmcInitConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val cap = forkInitCapture(dut)
      val resp = new CmdResponder(dut)
      resp.cmd1ReadyAfter = 50
      resp.start()

      startAndWait(dut, cap, maxCycles = 50000)

      assert(cap.doneSeen, "initDone not set after 50 CMD1 retries")
      assert(!cap.errorSeen, "unexpected initError")
    }
  }

  // ================================================================
  // Test 4: CMD timeout on CMD2 → init error
  // ================================================================
  test("CMD timeout on CMD2") {
    simConfig.compile(new EmmcInit(EmmcInitConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val cap = forkInitCapture(dut)
      val resp = new CmdResponder(dut)
      resp.cmd1ReadyAfter = 0
      resp.injectTimeout = true
      resp.timeoutCmdIdx = 2
      resp.start()

      startAndWait(dut, cap)

      assert(!cap.doneSeen, "initDone should not be set on timeout")
      assert(cap.errorSeen, "initError not set")
    }
  }

  // ================================================================
  // Test 5: CRC error on CMD3 → init error
  // ================================================================
  test("CRC error on CMD3") {
    simConfig.compile(new EmmcInit(EmmcInitConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val cap = forkInitCapture(dut)
      val resp = new CmdResponder(dut)
      resp.cmd1ReadyAfter = 0
      resp.injectCrcErr = true
      resp.crcErrCmdIdx = 3
      resp.start()

      startAndWait(dut, cap)

      assert(!cap.doneSeen, "initDone should not be set on CRC error")
      assert(cap.errorSeen, "initError not set")
    }
  }

  // ================================================================
  // Test 6: CRC error on CMD1 — ignored (R3 has no valid CRC)
  // ================================================================
  test("CRC error on CMD1 is ignored") {
    simConfig.compile(new EmmcInit(EmmcInitConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val cap = forkInitCapture(dut)
      val resp = new CmdResponder(dut)
      resp.cmd1ReadyAfter = 0
      resp.injectCrcErr = true
      resp.crcErrCmdIdx = 1
      resp.start()

      startAndWait(dut, cap)

      assert(cap.doneSeen, "initDone not set (CMD1 CRC should be ignored)")
      assert(!cap.errorSeen, "unexpected initError")
    }
  }

  // ================================================================
  // Test 7: RST_n timing — low before init, high during init
  // ================================================================
  test("RST_n timing") {
    simConfig.compile(new EmmcInit(EmmcInitConfig(clkFreq = testClkFreq))).doSim { dut =>
      initDut(dut)
      val cap = forkInitCapture(dut)
      val resp = new CmdResponder(dut)
      resp.cmd1ReadyAfter = 0
      resp.start()

      // Before init: RST_n should be low
      assert(!dut.io.emmcRstnOut.toBoolean, "RST_n should be low before init")

      dut.io.initStart #= true
      dut.clockDomain.waitRisingEdge(2)
      dut.io.initStart #= false

      // Wait for RST_n to go high
      var rstnHigh = false
      for (_ <- 0 until 2000 if !rstnHigh) {
        dut.clockDomain.waitRisingEdge()
        if (dut.io.emmcRstnOut.toBoolean) rstnHigh = true
      }
      assert(rstnHigh, "RST_n never went high")

      // Wait for init to complete
      for (_ <- 0 until 10000 if !cap.doneSeen && !cap.errorSeen) {
        dut.clockDomain.waitRisingEdge()
      }

      assert(cap.doneSeen, "initDone not set")
    }
  }
}
