use std::io;
use std::time::Duration;

use anyhow::Result;

use crate::error::ProtocolError;
use crate::protocol::{self, HEADER_RX};

pub struct RxPacket {
    #[allow(dead_code)]
    pub cmd_id: u8,
    pub status: u8,
    pub payload: Vec<u8>,
}

pub struct EmmcTool {
    port: Box<dyn serialport::SerialPort>,
    port_name: String,
    current_baud: u32,
    default_timeout: Duration,
    pub max_retries: u32,
    pub ignore_crc: bool,
}

impl EmmcTool {
    pub fn new(port_name: &str, baud: u32, timeout: Duration) -> Result<Self> {
        let port = serialport::new(port_name, baud)
            .timeout(timeout)
            .open()?;
        port.clear(serialport::ClearBuffer::Input)?;
        Ok(Self {
            port,
            port_name: port_name.to_string(),
            current_baud: baud,
            default_timeout: timeout,
            max_retries: 0,
            ignore_crc: false,
        })
    }

    #[allow(dead_code)]
    pub fn port_name(&self) -> &str {
        &self.port_name
    }

    #[allow(dead_code)]
    pub fn current_baud(&self) -> u32 {
        self.current_baud
    }

    pub fn reopen(&mut self, baud: u32) -> Result<()> {
        let port = serialport::new(&self.port_name, baud)
            .timeout(self.default_timeout)
            .open()?;
        port.clear(serialport::ClearBuffer::Input)?;
        self.port = port;
        self.current_baud = baud;
        Ok(())
    }

    pub fn set_timeout(&mut self, timeout: Duration) -> Result<()> {
        self.port.set_timeout(timeout)?;
        Ok(())
    }

    pub fn restore_timeout(&mut self) -> Result<()> {
        self.port.set_timeout(self.default_timeout)?;
        Ok(())
    }

    fn read_exact(&mut self, buf: &mut [u8]) -> Result<()> {
        let mut total = 0;
        while total < buf.len() {
            match self.port.read(&mut buf[total..]) {
                Ok(0) => return Err(ProtocolError::Timeout.into()),
                Ok(n) => total += n,
                Err(e) if e.kind() == io::ErrorKind::TimedOut => {
                    return Err(ProtocolError::Timeout.into());
                }
                Err(e) => return Err(e.into()),
            }
        }
        Ok(())
    }

    pub fn send_command(&mut self, cmd_id: u8, payload: &[u8]) -> Result<RxPacket> {
        self.send_command_no_recv(cmd_id, payload)?;
        self.recv_response()
    }

    pub fn send_command_no_recv(&mut self, cmd_id: u8, payload: &[u8]) -> Result<()> {
        let packet = protocol::build_tx_packet(cmd_id, payload);
        self.port.write_all(&packet)?;
        self.port.flush()?;
        Ok(())
    }

    pub fn recv_response(&mut self) -> Result<RxPacket> {
        // Scan for header byte 0x55
        let mut byte = [0u8; 1];
        loop {
            self.read_exact(&mut byte)?;
            if byte[0] == HEADER_RX {
                break;
            }
        }

        // Read CMD_ID, STATUS, LEN_H, LEN_L
        let mut hdr = [0u8; 4];
        self.read_exact(&mut hdr)?;

        let cmd_id = hdr[0];
        let status = hdr[1];
        let length = ((hdr[2] as u16) << 8) | (hdr[3] as u16);

        // Read payload
        let mut payload = vec![0u8; length as usize];
        if length > 0 {
            self.read_exact(&mut payload)?;
        }

        // Read CRC
        let mut crc_byte = [0u8; 1];
        self.read_exact(&mut crc_byte)?;

        // Verify CRC: covers CMD_ID + STATUS + LEN_H + LEN_L + PAYLOAD
        let mut crc_data = Vec::with_capacity(4 + payload.len());
        crc_data.extend_from_slice(&hdr);
        crc_data.extend_from_slice(&payload);
        let expected = protocol::crc8(&crc_data);
        if crc_byte[0] != expected {
            if self.ignore_crc {
                eprintln!(
                    "Warning: CRC mismatch ignored (got 0x{:02X}, expected 0x{:02X})",
                    crc_byte[0], expected
                );
            } else {
                eprintln!(
                    "Warning: CRC mismatch (got 0x{:02X}, expected 0x{:02X})",
                    crc_byte[0], expected
                );
            }
        }

        Ok(RxPacket {
            cmd_id,
            status,
            payload,
        })
    }
}

impl Drop for EmmcTool {
    fn drop(&mut self) {
        let _ = self.port.flush();
    }
}
