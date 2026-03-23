package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class UartLoopbackSim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  // Loopback wrapper component: TX -> RX direct wire
  class UartLoopback extends Component {
    val io = new Bundle {
      val txData      = in  Bits(8 bits)
      val txValid     = in  Bool()
      val clksPerBit  = in  Bits(8 bits)
      val txBusy      = out Bool()
      val rxData      = out Bits(8 bits)
      val rxValid     = out Bool()
      val rxFrameErr  = out Bool()
    }

    val uTx = new UartTx()
    val uRx = new UartRx()

    uTx.io.dataIn     := io.txData
    uTx.io.dataValid  := io.txValid
    uTx.io.clksPerBit := io.clksPerBit
    io.txBusy         := uTx.io.busy

    // Loopback: TX output -> RX input
    uRx.io.rx         := uTx.io.tx
    uRx.io.clksPerBit := io.clksPerBit
    io.rxData          := uRx.io.dataOut
    io.rxValid         := uRx.io.dataValid
    io.rxFrameErr      := uRx.io.frameErr
  }

  test("TX -> RX loopback: 8 bytes") {
    simConfig.compile(new UartLoopback()).doSim { dut =>
      dut.io.txData #= 0
      dut.io.txValid #= false
      dut.io.clksPerBit #= 0
      dut.clockDomain.forkStimulus(10)
      dut.clockDomain.waitRisingEdge(4)

      val cpb = 20
      val testPattern = Seq(0x00, 0xFF, 0xAA, 0x55, 0x01, 0x80, 0x7E, 0xDE)
      val recvBuf = scala.collection.mutable.ArrayBuffer[Int]()

      // Background receiver
      val rxThread = fork {
        while (recvBuf.size < testPattern.size) {
          dut.clockDomain.waitRisingEdge()
          if (dut.io.rxValid.toBoolean) {
            recvBuf += dut.io.rxData.toInt
          }
        }
      }

      // Send all bytes
      for (b <- testPattern) {
        dut.clockDomain.waitRisingEdge()
        dut.io.txData #= b
        dut.io.txValid #= true
        dut.clockDomain.waitRisingEdge()
        dut.io.txValid #= false
        // Wait for busy high
        var cnt = 0
        while (!dut.io.txBusy.toBoolean && cnt < 10) {
          dut.clockDomain.waitRisingEdge()
          cnt += 1
        }
        // Wait for busy low
        waitUntil(!dut.io.txBusy.toBoolean)
        // Inter-byte gap
        dut.clockDomain.waitRisingEdge(cpb * 2)
      }

      // Wait for last byte
      dut.clockDomain.waitRisingEdge(cpb * 12)
      rxThread.join()

      assert(recvBuf.size == 8, s"expected 8 bytes, received ${recvBuf.size}")
      for ((expected, actual) <- testPattern.zip(recvBuf)) {
        assert(actual == expected, s"byte mismatch: expected 0x${expected.toHexString}, got 0x${actual.toHexString}")
      }
    }
  }
}
