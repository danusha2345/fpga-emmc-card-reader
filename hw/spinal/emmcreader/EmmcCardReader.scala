package emmcreader

import spinal.core._

// Generates Verilog for all currently ported modules
object EmmcCardReaderVerilog extends App {
  val config = SpinalConfig(
    targetDirectory = "generated",
    defaultConfigForClockDomains = ClockDomainConfig(
      resetKind = ASYNC,
      resetActiveLevel = LOW
    )
  )

  // Phase A: CRC modules
  config.generateVerilog(new Crc7)
  config.generateVerilog(new Crc16)
  config.generateVerilog(new Crc8)

  // Phase B: UART + LED
  config.generateVerilog(new UartTx())
  config.generateVerilog(new UartRx())
  config.generateVerilog(new LedStatus)

  // Phase C: Sector Buffers
  config.generateVerilog(new SectorBuf)
  config.generateVerilog(new SectorBufWr)

  // Phase D: eMMC protocol modules
  config.generateVerilog(new EmmcCmd)
  config.generateVerilog(new EmmcDat)
  config.generateVerilog(new EmmcInit())

  // Phase E: Controllers
  config.generateVerilog(new EmmcController())
  config.generateVerilog(new UartBridge())

  // Phase F: FT245 FIFO variant
  config.generateVerilog(new Ft245Fifo)
  config.generateVerilog(new UartBridge(UartBridgeConfig(useFifo = true)))
}
