use anyhow::{Context, Result};
use serialport::SerialPort;
use std::io::{Read, Write};
use std::time::Duration;

use crate::transport::Transport;

/// UART serial transport wrapping serialport::SerialPort.
pub struct SerialTransport {
    port: Box<dyn SerialPort>,
    name: String,
}

impl SerialTransport {
    /// Open serial port with FT2232C warm-up for ttyUSB ports.
    pub fn open(port_name: &str, baud: u32) -> Result<Self> {
        // FT2232C clone warm-up: open/close at target baud
        if port_name.contains("ttyUSB") {
            if let Ok(warmup) = serialport::new(port_name, baud)
                .timeout(Duration::from_millis(100))
                .open()
            {
                drop(warmup);
                std::thread::sleep(Duration::from_millis(50));
            }
        }

        let port = serialport::new(port_name, baud)
            .timeout(Duration::from_secs(2))
            .open()
            .with_context(|| format!("Failed to open {}", port_name))?;

        port.clear(serialport::ClearBuffer::Input)
            .context("Failed to clear input buffer")?;

        Ok(Self {
            port,
            name: format!("UART {}", port_name),
        })
    }
}

impl Transport for SerialTransport {
    fn write_all(&mut self, data: &[u8]) -> Result<()> {
        self.port.write_all(data)?;
        Ok(())
    }

    fn flush(&mut self) -> Result<()> {
        self.port.flush()?;
        Ok(())
    }

    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let n = self.port.read(buf)?;
        Ok(n)
    }

    fn read_exact(&mut self, buf: &mut [u8]) -> Result<()> {
        self.port.read_exact(buf)?;
        Ok(())
    }

    fn set_timeout(&mut self, timeout: Duration) -> Result<()> {
        self.port.set_timeout(timeout)?;
        Ok(())
    }

    fn purge_input(&mut self) -> Result<()> {
        self.port.clear(serialport::ClearBuffer::Input)?;
        Ok(())
    }

    fn name(&self) -> &str {
        &self.name
    }
}
