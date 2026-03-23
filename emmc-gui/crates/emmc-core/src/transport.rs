use anyhow::Result;
use std::time::Duration;

/// Abstract transport layer for PC <-> FPGA communication.
/// Implementations: SerialTransport (UART), FifoTransport (FT245 async FIFO).
pub trait Transport: Send {
    fn write_all(&mut self, data: &[u8]) -> Result<()>;
    fn flush(&mut self) -> Result<()>;
    /// Read up to buf.len() bytes. Blocks until at least 1 byte or timeout.
    fn read(&mut self, buf: &mut [u8]) -> Result<usize>;
    /// Read exactly buf.len() bytes, blocking until complete or error.
    fn read_exact(&mut self, buf: &mut [u8]) -> Result<()>;
    fn set_timeout(&mut self, timeout: Duration) -> Result<()>;
    fn purge_input(&mut self) -> Result<()>;
    /// Human-readable name, e.g. "UART /dev/ttyUSB1" or "FIFO FT2232HL"
    fn name(&self) -> &str;
    /// True for FT245 FIFO transport (baud switch is a no-op)
    fn is_fifo(&self) -> bool {
        false
    }
}
