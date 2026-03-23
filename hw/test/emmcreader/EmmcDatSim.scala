package emmcreader

import spinal.core._
import spinal.core.sim._
import org.scalatest.funsuite.AnyFunSuite

class EmmcDatSim extends AnyFunSuite {

  val simConfig = SimConfig
    .withVerilator
    .withConfig(SpinalConfig(
      defaultConfigForClockDomains = ClockDomainConfig(
        resetKind = ASYNC,
        resetActiveLevel = LOW
      )
    ))

  // Helper: set all 4 datIn lines to a value (0x0 or 0xF for low/high)
  def setDatIn(dut: EmmcDat, high: Boolean): Unit = {
    dut.io.datIn #= (if (high) 0xF else 0x0)
  }

  // Helper: set datIn as a 4-bit integer
  def setDatIn4(dut: EmmcDat, nibble: Int): Unit = {
    dut.io.datIn #= nibble & 0xF
  }

  def initDut(dut: EmmcDat, busWidth4: Boolean = false): Unit = {
    dut.io.clkEn     #= false
    dut.io.rdStart   #= false
    dut.io.wrStart   #= false
    dut.io.bufRdData #= 0
    dut.io.busWidth4 #= busWidth4
    setDatIn(dut, high = true)
    dut.clockDomain.forkStimulus(10)
    dut.clockDomain.waitRisingEdge(4)
  }

  def emmcCycle(dut: EmmcDat): Unit = {
    dut.io.clkEn #= true
    dut.clockDomain.waitRisingEdge()
    dut.io.clkEn #= false
    dut.clockDomain.waitRisingEdge()
  }

  // Sticky capture for 1-cycle done pulses (fork thread)
  class DoneCapture {
    var rdDone = false
    var rdCrcErr = false
    var wrDone = false
    var wrCrcErr = false
  }

  def forkDoneCapture(dut: EmmcDat): DoneCapture = {
    val cap = new DoneCapture
    fork {
      while (true) {
        dut.clockDomain.waitRisingEdge()
        if (dut.io.rdDone.toBoolean) { cap.rdDone = true; cap.rdCrcErr = dut.io.rdCrcErr.toBoolean }
        if (dut.io.wrDone.toBoolean) { cap.wrDone = true; cap.wrCrcErr = dut.io.wrCrcErr.toBoolean }
      }
    }
    cap
  }

  // Fork BRAM mock: provides bufRdData with 1-cycle latency
  def forkBram(dut: EmmcDat, data: Array[Int]): Unit = {
    fork {
      while (true) {
        dut.clockDomain.waitRisingEdge()
        dut.io.bufRdData #= data(dut.io.bufRdAddr.toInt % data.length)
      }
    }
  }

  // Fork BRAM write capture
  def forkBramCapture(dut: EmmcDat, captured: Array[Int]): Unit = {
    fork {
      while (true) {
        dut.clockDomain.waitRisingEdge()
        if (dut.io.bufWrEn.toBoolean) {
          val addr = dut.io.bufWrAddr.toInt
          if (addr < captured.length) captured(addr) = dut.io.bufWrData.toInt
        }
      }
    }
  }

  // ================================================================
  // 1-bit mode helpers (datIn(0) carries data, DAT[3:1] = high)
  // ================================================================

  // Send sector data on datIn(0): start + 4096 data bits + CRC-16 + end
  def cardSendSector(dut: EmmcDat, data: Array[Int], corruptCrc: Boolean = false): Unit = {
    // Nac gap
    for (_ <- 0 until 4) emmcCycle(dut)
    // Start bit
    setDatIn(dut, high = false)
    emmcCycle(dut)
    // Data bits (MSB first) on DAT0, DAT[3:1] = high
    val dataBits = Crc16Helper.bytesToBitsMsb(data.toSeq)
    val crc = if (corruptCrc) Crc16Helper.compute(dataBits) ^ 0xFFFF
              else Crc16Helper.compute(dataBits)
    for (bit <- dataBits) {
      dut.io.datIn #= (if (bit) 0xF else 0xE)  // DAT0=bit, DAT[3:1]=1
      emmcCycle(dut)
    }
    // CRC-16 (MSB first)
    for (i <- 15 to 0 by -1) {
      val b = ((crc >> i) & 1) == 1
      dut.io.datIn #= (if (b) 0xF else 0xE)
      emmcCycle(dut)
    }
    // End bit
    setDatIn(dut, high = true)
    emmcCycle(dut)
  }

  // Wait for host write phase to complete (datOe goes true then false)
  def waitHostWriteDone(dut: EmmcDat): Unit = {
    // Wait for datOe to go true
    var started = false
    for (_ <- 0 until 10 if !started) {
      emmcCycle(dut)
      if (dut.io.datOe.toBoolean) started = true
    }
    assert(started, "Host never started driving DAT0")
    // Wait for datOe to go false
    var finished = false
    for (_ <- 0 until 5000 if !finished) {
      emmcCycle(dut)
      if (!dut.io.datOe.toBoolean) finished = true
    }
    assert(finished, "Host never stopped driving DAT0")
  }

  // Card sends CRC status response on DAT0: start(0) + 3-bit status + end trigger
  // Then holds busy for busyCycles, then releases
  def cardSendCrcStatus(dut: EmmcDat, status: Int = 2, busyCycles: Int = 20): Unit = {
    val bits = Seq((status >> 2) & 1, (status >> 1) & 1, status & 1)
    dut.io.datIn #= (if (false) 0xF else 0xE); emmcCycle(dut) // start bit (DAT0=0)
    dut.io.datIn #= (if (bits(0) == 1) 0xF else 0xE); emmcCycle(dut)
    dut.io.datIn #= (if (bits(1) == 1) 0xF else 0xE); emmcCycle(dut)
    dut.io.datIn #= (if (bits(2) == 1) 0xF else 0xE); emmcCycle(dut)
    setDatIn(dut, high = true); emmcCycle(dut)  // check trigger
    // Busy (DAT0 = 0)
    dut.io.datIn #= 0xE  // DAT0=0, DAT[3:1]=1
    for (_ <- 0 until busyCycles) emmcCycle(dut)
    // Release
    setDatIn(dut, high = true)
  }

  // ================================================================
  // 4-bit mode helpers
  // ================================================================

  // Compute per-line CRC-16 for 4-bit data
  // Returns array of 4 CRCs, one per DAT line
  def computePerLineCrc(data: Array[Int]): Array[Int] = {
    val crcs = Array.fill(4)(0)
    for (byte <- data) {
      // High nibble: DAT[3]=bit7, DAT[2]=bit6, DAT[1]=bit5, DAT[0]=bit4
      val hiNib = (byte >> 4) & 0xF
      for (i <- 0 until 4) {
        val bit = (hiNib >> i) & 1
        val fb = ((crcs(i) >> 15) & 1) ^ bit
        crcs(i) = ((crcs(i) << 1) & 0xFFFF)
        if (fb != 0) crcs(i) ^= 0x1021
      }
      // Low nibble: DAT[3]=bit3, DAT[2]=bit2, DAT[1]=bit1, DAT[0]=bit0
      val loNib = byte & 0xF
      for (i <- 0 until 4) {
        val bit = (loNib >> i) & 1
        val fb = ((crcs(i) >> 15) & 1) ^ bit
        crcs(i) = ((crcs(i) << 1) & 0xFFFF)
        if (fb != 0) crcs(i) ^= 0x1021
      }
    }
    crcs
  }

  // Send sector data in 4-bit mode: start + 1024 clocks + 4×CRC-16 + end
  def cardSendSector4bit(dut: EmmcDat, data: Array[Int], corruptCrc: Boolean = false): Unit = {
    // Nac gap
    for (_ <- 0 until 4) emmcCycle(dut)
    // Start bit on all 4 lines
    setDatIn4(dut, 0x0)
    emmcCycle(dut)
    // Data: 2 clocks per byte (high nibble, low nibble)
    // JEDEC: DAT[3]=byte[7], DAT[2]=byte[6], DAT[1]=byte[5], DAT[0]=byte[4] (high nibble)
    //        DAT[3]=byte[3], DAT[2]=byte[2], DAT[1]=byte[1], DAT[0]=byte[0] (low nibble)
    for (byte <- data) {
      setDatIn4(dut, (byte >> 4) & 0xF)
      emmcCycle(dut)
      setDatIn4(dut, byte & 0xF)
      emmcCycle(dut)
    }
    // CRC-16: 16 clocks, each clock sends MSB of each line's CRC
    val crcs = computePerLineCrc(data)
    if (corruptCrc) crcs(0) ^= 0xFFFF
    for (bitIdx <- 15 to 0 by -1) {
      var nibble = 0
      for (i <- 0 until 4) {
        if (((crcs(i) >> bitIdx) & 1) == 1) nibble |= (1 << i)
      }
      setDatIn4(dut, nibble)
      emmcCycle(dut)
    }
    // End bit
    setDatIn4(dut, 0xF)
    emmcCycle(dut)
  }

  // Wait for host write in 4-bit mode, capture data
  def waitHostWrite4bitDone(dut: EmmcDat): Array[Int] = {
    // Wait for datOe to go true
    var started = false
    for (_ <- 0 until 10 if !started) {
      emmcCycle(dut)
      if (dut.io.datOe.toBoolean) started = true
    }
    assert(started, "Host never started driving DAT[3:0]")

    // Now capture: start bit already happened (datOut=0x0)
    // Capture 1024 data clocks (512 bytes × 2 clocks/byte)
    val captured = new Array[Int](512)
    for (byteIdx <- 0 until 512) {
      emmcCycle(dut)
      val hiNib = dut.io.datOut.toInt & 0xF
      emmcCycle(dut)
      val loNib = dut.io.datOut.toInt & 0xF
      captured(byteIdx) = (hiNib << 4) | loNib
    }

    // Skip CRC (16 clocks) + end (1 clock)
    for (_ <- 0 until 17) emmcCycle(dut)

    // Wait for datOe to go false
    var finished = false
    for (_ <- 0 until 10 if !finished) {
      emmcCycle(dut)
      if (!dut.io.datOe.toBoolean) finished = true
    }
    captured
  }

  // ================================================================
  // Test 1: Read 1-bit — CRC OK, verify data
  // ================================================================
  test("Read sector with correct CRC") {
    simConfig.compile(new EmmcDat).doSim { dut =>
      initDut(dut)
      val cap = forkDoneCapture(dut)
      val captured = Array.fill(512)(-1)
      forkBramCapture(dut, captured)

      dut.io.rdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.rdStart #= false

      val sectorData = Array.tabulate(512)(i => i & 0xFF)
      cardSendSector(dut, sectorData)

      for (_ <- 0 until 20 if !cap.rdDone) dut.clockDomain.waitRisingEdge()

      assert(cap.rdDone, "rdDone not asserted")
      assert(!cap.rdCrcErr, "unexpected rdCrcErr")
      for (i <- 0 until 512) {
        assert(captured(i) == sectorData(i),
          s"data[$i]=0x${captured(i).toHexString} expected 0x${sectorData(i).toHexString}")
      }
    }
  }

  // ================================================================
  // Test 2: Read 1-bit — CRC mismatch
  // ================================================================
  test("Read sector with CRC mismatch") {
    simConfig.compile(new EmmcDat).doSim { dut =>
      initDut(dut)
      val cap = forkDoneCapture(dut)

      dut.io.rdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.rdStart #= false

      val sectorData = Array.tabulate(512)(i => i & 0xFF)
      cardSendSector(dut, sectorData, corruptCrc = true)

      for (_ <- 0 until 20 if !cap.rdDone) dut.clockDomain.waitRisingEdge()

      assert(cap.rdDone, "rdDone not asserted")
      assert(cap.rdCrcErr, "rdCrcErr not set")
    }
  }

  // ================================================================
  // Test 3: Read 1-bit — timeout (no start bit)
  // ================================================================
  test("Read timeout when no card response") {
    simConfig.compile(new EmmcDat).doSim { dut =>
      initDut(dut)
      val cap = forkDoneCapture(dut)

      dut.io.rdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.rdStart #= false

      // datIn stays high — no start bit → timeout after ~65K clkEn cycles
      for (_ <- 0 until 200000 if !cap.rdDone) emmcCycle(dut)

      assert(cap.rdDone, "rdDone not asserted after timeout")
      assert(cap.rdCrcErr, "rdCrcErr not set (timeout indicator)")
    }
  }

  // ================================================================
  // Test 4: Write 1-bit — CRC status OK (010)
  // ================================================================
  test("Write sector with CRC OK status") {
    simConfig.compile(new EmmcDat).doSim { dut =>
      initDut(dut)
      val cap = forkDoneCapture(dut)
      val bramData = Array.tabulate(512)(i => (i * 3 + 0x42) & 0xFF)
      forkBram(dut, bramData)

      dut.io.wrStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.wrStart #= false
      dut.clockDomain.waitRisingEdge(3) // prefetch

      waitHostWriteDone(dut)
      cardSendCrcStatus(dut, status = 2, busyCycles = 20) // 010 = OK

      for (_ <- 0 until 50 if !cap.wrDone) emmcCycle(dut)

      assert(cap.wrDone, "wrDone not asserted")
      assert(!cap.wrCrcErr, "unexpected wrCrcErr")
    }
  }

  // ================================================================
  // Test 5: Write 1-bit — CRC status error (101)
  // ================================================================
  test("Write sector with CRC error status") {
    simConfig.compile(new EmmcDat).doSim { dut =>
      initDut(dut)
      val cap = forkDoneCapture(dut)
      val bramData = Array.tabulate(512)(i => (i * 3 + 0x42) & 0xFF)
      forkBram(dut, bramData)

      dut.io.wrStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.wrStart #= false
      dut.clockDomain.waitRisingEdge(3)

      waitHostWriteDone(dut)
      cardSendCrcStatus(dut, status = 5, busyCycles = 0) // 101 = error, no busy

      for (_ <- 0 until 50 if !cap.wrDone) emmcCycle(dut)
      // Also check sys clocks (pulse might fire without clkEn)
      for (_ <- 0 until 20 if !cap.wrDone) dut.clockDomain.waitRisingEdge()

      assert(cap.wrDone, "wrDone not asserted")
      assert(cap.wrCrcErr, "wrCrcErr not set")
    }
  }

  // ================================================================
  // Test 6: Read 4-bit — CRC OK, verify data
  // ================================================================
  test("Read 4-bit sector with correct CRC") {
    simConfig.compile(new EmmcDat).doSim { dut =>
      initDut(dut, busWidth4 = true)
      val cap = forkDoneCapture(dut)
      val captured = Array.fill(512)(-1)
      forkBramCapture(dut, captured)

      dut.io.rdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.rdStart #= false

      val sectorData = Array.tabulate(512)(i => i & 0xFF)
      cardSendSector4bit(dut, sectorData)

      for (_ <- 0 until 20 if !cap.rdDone) dut.clockDomain.waitRisingEdge()

      assert(cap.rdDone, "rdDone not asserted")
      assert(!cap.rdCrcErr, "unexpected rdCrcErr")
      for (i <- 0 until 512) {
        assert(captured(i) == sectorData(i),
          s"data[$i]=0x${captured(i).toHexString} expected 0x${sectorData(i).toHexString}")
      }
    }
  }

  // ================================================================
  // Test 7: Read 4-bit — CRC error (corrupt one line)
  // ================================================================
  test("Read 4-bit sector with CRC error") {
    simConfig.compile(new EmmcDat).doSim { dut =>
      initDut(dut, busWidth4 = true)
      val cap = forkDoneCapture(dut)

      dut.io.rdStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.rdStart #= false

      val sectorData = Array.tabulate(512)(i => i & 0xFF)
      cardSendSector4bit(dut, sectorData, corruptCrc = true)

      for (_ <- 0 until 20 if !cap.rdDone) dut.clockDomain.waitRisingEdge()

      assert(cap.rdDone, "rdDone not asserted")
      assert(cap.rdCrcErr, "rdCrcErr not set")
    }
  }

  // ================================================================
  // Test 8: Write 4-bit — CRC status OK
  // ================================================================
  test("Write 4-bit sector with CRC OK status") {
    simConfig.compile(new EmmcDat).doSim { dut =>
      initDut(dut, busWidth4 = true)
      val cap = forkDoneCapture(dut)
      val bramData = Array.tabulate(512)(i => (i * 3 + 0x42) & 0xFF)
      forkBram(dut, bramData)

      dut.io.wrStart #= true
      dut.clockDomain.waitRisingEdge()
      dut.io.wrStart #= false
      dut.clockDomain.waitRisingEdge(3) // prefetch

      // Wait for host to finish writing
      waitHostWriteDone(dut)
      // CRC status on DAT0 (same protocol as 1-bit)
      cardSendCrcStatus(dut, status = 2, busyCycles = 20)

      for (_ <- 0 until 50 if !cap.wrDone) emmcCycle(dut)

      assert(cap.wrDone, "wrDone not asserted")
      assert(!cap.wrCrcErr, "unexpected wrCrcErr")
    }
  }
}
