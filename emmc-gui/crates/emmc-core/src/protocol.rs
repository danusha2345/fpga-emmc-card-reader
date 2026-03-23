use anyhow::{bail, Result};
use std::time::Duration;

use crate::transport::Transport;

const HEADER_TX: u8 = 0xAA;
const HEADER_RX: u8 = 0x55;
pub const SECTOR_SIZE: usize = 512;

// Command IDs
pub const CMD_PING: u8 = 0x01;
pub const CMD_GET_INFO: u8 = 0x02;
pub const CMD_READ_SECTOR: u8 = 0x03;
pub const CMD_WRITE_SECTOR: u8 = 0x04;
pub const CMD_ERASE: u8 = 0x05;
pub const CMD_GET_STATUS: u8 = 0x06;
pub const CMD_GET_EXT_CSD: u8 = 0x07;
pub const CMD_SET_PARTITION: u8 = 0x08;
pub const CMD_WRITE_EXT_CSD: u8 = 0x09;
pub const CMD_GET_CARD_STATUS: u8 = 0x0A;
pub const CMD_REINIT: u8 = 0x0B;
pub const CMD_SECURE_ERASE: u8 = 0x0C;
pub const CMD_SET_CLK_DIV: u8 = 0x0D;
pub const CMD_SEND_RAW: u8 = 0x0E;
pub const CMD_SET_BAUD: u8 = 0x0F;
pub const CMD_SET_RPMB_MODE: u8 = 0x10;
pub const CMD_SET_BUS_WIDTH: u8 = 0x11;

// Status codes
pub const STATUS_OK: u8 = 0x00;
pub const STATUS_ERR_CRC: u8 = 0x01;
pub const STATUS_ERR_CMD: u8 = 0x02;
pub const STATUS_ERR_EMMC: u8 = 0x03;
pub const STATUS_BUSY: u8 = 0x04;

pub fn status_name(status: u8) -> &'static str {
    match status {
        STATUS_OK => "OK",
        STATUS_ERR_CRC => "CRC Error",
        STATUS_ERR_CMD => "Unknown Command",
        STATUS_ERR_EMMC => "eMMC Error",
        STATUS_BUSY => "Busy",
        _ => "Unknown",
    }
}

/// CRC-8 with polynomial 0x07
pub fn crc8(data: &[u8]) -> u8 {
    let mut crc: u8 = 0;
    for &byte in data {
        crc ^= byte;
        for _ in 0..8 {
            if crc & 0x80 != 0 {
                crc = (crc << 1) ^ 0x07;
            } else {
                crc <<= 1;
            }
        }
    }
    crc
}

/// Controller debug status (12-byte GET_STATUS response)
#[derive(Debug, Clone)]
pub struct ControllerStatus {
    pub resp_status: u8,
    pub init_state: u8,
    pub mc_state: u8,
    pub info_valid: bool,
    pub cmd_ready: bool,
    pub cmd_pin: bool,
    pub dat0_pin: bool,
    pub cmd_fsm: u8,
    pub dat_fsm: u8,
    pub use_fast_clk: bool,
    pub partition: u8,
    pub reinit_pending: bool,
    pub cmd_timeout_cnt: u8,
    pub cmd_crc_err_cnt: u8,
    pub dat_rd_err_cnt: u8,
    pub dat_wr_err_cnt: u8,
    pub init_retry_cnt: u8,
    pub baud_preset: u8,
    pub clk_preset: u8,
}

impl ControllerStatus {
    pub fn parse(data: &[u8]) -> Self {
        let b = |i: usize| -> u8 { data.get(i).copied().unwrap_or(0) };
        let b0 = b(0);
        let b1 = b(1);
        let b2 = b(2);
        let b3 = b(3);
        let b4 = b(4);
        let b5 = b(5);
        Self {
            resp_status: b0,
            init_state: (b1 >> 4) & 0x0F,
            mc_state: ((b1 & 0x07) << 2) | ((b2 >> 6) & 0x03),
            info_valid: (b2 >> 5) & 1 != 0,
            cmd_ready: (b2 >> 4) & 1 != 0,
            cmd_pin: (b3 >> 7) & 1 != 0,
            dat0_pin: (b3 >> 6) & 1 != 0,
            cmd_fsm: (b4 >> 5) & 0x07,
            dat_fsm: (b4 >> 1) & 0x0F,
            use_fast_clk: b4 & 1 != 0,
            partition: (b5 >> 6) & 0x03,
            reinit_pending: (b5 >> 5) & 1 != 0,
            cmd_timeout_cnt: b(6),
            cmd_crc_err_cnt: b(7),
            dat_rd_err_cnt: b(8),
            dat_wr_err_cnt: b(9),
            init_retry_cnt: b(10),
            baud_preset: (b(11) >> 3) & 0x03,
            clk_preset: b(11) & 0x07,
        }
    }

    pub fn init_state_name(&self) -> &'static str {
        match self.init_state {
            0 => "IDLE",
            1 => "RST_LOW",
            2 => "RST_HIGH",
            3 => "CMD0",
            4 => "CMD1",
            5 => "CMD1_WAIT",
            6 => "CMD2",
            7 => "CMD3",
            8 => "CMD9",
            9 => "CMD7",
            10 => "CMD6",
            11 => "CMD16",
            12 => "DONE",
            13 => "ERROR",
            14 => "WAIT_CMD",
            15 => "CMD7_WAIT",
            _ => "?",
        }
    }

    pub fn mc_state_name(&self) -> &'static str {
        match self.mc_state {
            0 => "IDLE",
            1 => "INIT",
            2 => "READY",
            3 => "READ_CMD",
            4 => "READ_DAT",
            5 => "READ_DONE",
            6 => "WRITE_CMD",
            7 => "WRITE_DAT",
            8 => "WRITE_DONE",
            9 => "STOP_CMD",
            10 => "ERROR",
            11 => "EXT_CSD_CMD",
            12 => "EXT_CSD_DAT",
            13 => "SWITCH_CMD",
            14 => "SWITCH_WAIT",
            15 => "ERASE_START",
            16 => "ERASE_END",
            17 => "ERASE_CMD",
            18 => "ERASE_WAIT",
            19 => "STATUS_CMD",
            20 => "ERROR_STOP",
            21 => "STOP_WAIT",
            _ => "?",
        }
    }

    pub fn cmd_fsm_name(&self) -> &'static str {
        match self.cmd_fsm {
            0 => "IDLE",
            1 => "SEND",
            2 => "WAIT",
            3 => "RECV",
            4 => "DONE",
            _ => "?",
        }
    }

    pub fn dat_fsm_name(&self) -> &'static str {
        match self.dat_fsm {
            0 => "IDLE",
            1 => "RD_WAIT",
            2 => "RD_DATA",
            3 => "RD_CRC",
            4 => "RD_END",
            5 => "RD_DONE",
            6 => "WR_START",
            7 => "WR_DATA",
            8 => "WR_CRC",
            9 => "WR_END",
            10 => "WR_STAT",
            11 => "WR_BUSY",
            12 => "WR_DONE",
            13 => "WR_PRE2",
            _ => "?",
        }
    }

    pub fn partition_name(&self) -> &'static str {
        match self.partition {
            0 => "user",
            1 => "boot0",
            2 => "boot1",
            3 => "RPMB",
            _ => "?",
        }
    }

    pub fn baud_preset_name(&self) -> &'static str {
        match self.baud_preset {
            0 => "3 Mbaud",
            1 => "6 Mbaud",
            2 => "7.5 Mbaud",
            3 => "12 Mbaud",
            _ => "?",
        }
    }

    pub fn clk_preset_name(&self) -> &'static str {
        match self.clk_preset {
            0 => "2 MHz",
            1 => "3.75 MHz",
            2 => "6 MHz",
            3 => "10 MHz",
            4 => "15 MHz",
            5 => "15 MHz",
            6 => "30 MHz",
            _ => "?",
        }
    }
}

/// eMMC connection over UART serial port or FT245 FIFO
pub struct EmmcConnection {
    transport: Box<dyn Transport>,
}

impl EmmcConnection {
    /// Connect to FPGA eMMC card reader via UART serial port.
    /// For ttyUSB ports, does FT2232C warm-up (open/close at target baud).
    /// Use port_name "fifo://" for FT245 FIFO transport (requires `fifo` feature).
    pub fn connect(port_name: &str, baud: u32) -> Result<Self> {
        // FIFO transport via sentinel port name
        if port_name == "fifo://" {
            #[cfg(feature = "fifo")]
            {
                let transport = crate::transport_fifo::FifoTransport::open()?;
                return Ok(Self {
                    transport: Box::new(transport),
                });
            }
            #[cfg(not(feature = "fifo"))]
            bail!("FIFO transport not compiled (enable 'fifo' feature)");
        }

        let transport =
            crate::transport_serial::SerialTransport::open(port_name, baud)?;
        Ok(Self {
            transport: Box::new(transport),
        })
    }

    /// Create connection with a pre-built transport.
    pub fn with_transport(transport: Box<dyn Transport>) -> Self {
        Self { transport }
    }

    /// True if using FT245 FIFO transport (baud switch is a no-op).
    pub fn is_fifo(&self) -> bool {
        self.transport.is_fifo()
    }

    /// Human-readable transport name.
    pub fn transport_name(&self) -> &str {
        self.transport.name()
    }

    /// Test connection with PING command
    pub fn ping(&mut self) -> Result<()> {
        let (_cmd, status, _payload) = self.send_command(CMD_PING, &[])?;
        if status != STATUS_OK {
            bail!("Ping failed: {}", status_name(status));
        }
        Ok(())
    }

    /// Read CID (16 bytes) and CSD (16 bytes)
    pub fn get_info(&mut self) -> Result<(Vec<u8>, Vec<u8>)> {
        let (_cmd, status, payload) = self.send_command(CMD_GET_INFO, &[])?;
        if status != STATUS_OK {
            bail!("GET_INFO failed: {}", status_name(status));
        }
        if payload.len() < 32 {
            bail!("Short info payload: {} bytes", payload.len());
        }
        Ok((payload[0..16].to_vec(), payload[16..32].to_vec()))
    }

    /// Read 512-byte Extended CSD
    ///
    /// FPGA sends 2 packets: 512B sector data (cmd=READ_SECTOR) + 0B completion (cmd=GET_EXT_CSD).
    pub fn get_ext_csd(&mut self) -> Result<Vec<u8>> {
        self.send_command_no_recv(CMD_GET_EXT_CSD, &[])?;
        // Packet 1: sector data (512 bytes)
        let (_cmd, status, payload) = self.recv_response()?;
        if status != STATUS_OK {
            bail!("GET_EXT_CSD failed: {}", status_name(status));
        }
        if payload.len() < 512 {
            bail!("Short ExtCSD: {} bytes", payload.len());
        }
        // Packet 2: completion (0 bytes) — must drain to keep protocol in sync
        let (_cmd2, final_status, _) = self.recv_response()?;
        if final_status != STATUS_OK {
            bail!(
                "GET_EXT_CSD completion error: {}",
                status_name(final_status)
            );
        }
        Ok(payload[..512].to_vec())
    }

    /// Get full controller debug status (12 bytes from FPGA).
    pub fn get_status(&mut self) -> Result<ControllerStatus> {
        let (_cmd, status, payload) = self.send_command(CMD_GET_STATUS, &[])?;
        if status != STATUS_OK {
            bail!("GET_STATUS failed: {}", status_name(status));
        }
        Ok(ControllerStatus::parse(&payload))
    }

    /// Switch eMMC partition (0=user, 1=boot0, 2=boot1, 3=RPMB)
    ///
    /// WARNING: RPMB (partition 3) requires authenticated frame protocol.
    /// Plain CMD17/CMD24 on RPMB is a JEDEC protocol violation that can brick eMMC.
    /// Callers should warn the user before switching to partition 3.
    pub fn set_partition(&mut self, partition: u8) -> Result<()> {
        let (_cmd, status, _payload) = self.send_command(CMD_SET_PARTITION, &[partition & 0x07])?;
        if status != STATUS_OK {
            bail!("SET_PARTITION failed: {}", status_name(status));
        }
        Ok(())
    }

    /// Read sectors from eMMC. Returns concatenated sector data.
    /// Uses CMD18 (multi-block) for count>1, CMD17 (single-block) for count=1.
    pub fn read_sectors(&mut self, lba: u32, count: u16) -> Result<Vec<u8>> {
        if count == 0 {
            return Ok(Vec::new());
        }
        if count == 1 {
            return self.read_sectors_single(lba, 1);
        }
        self.read_sectors_multi(lba, count)
    }

    /// Single-block reads (CMD17): one command per sector.
    /// FPGA sends 2 packets per single read: 512B sector data + 0B completion.
    fn read_sectors_single(&mut self, lba: u32, count: u16) -> Result<Vec<u8>> {
        let mut data = Vec::with_capacity(count as usize * SECTOR_SIZE);
        for i in 0..count as u32 {
            let mut payload = Vec::with_capacity(6);
            payload.extend_from_slice(&(lba + i).to_be_bytes());
            payload.extend_from_slice(&1u16.to_be_bytes());

            self.send_command_no_recv(CMD_READ_SECTOR, &payload)?;
            // Packet 1: sector data (512 bytes)
            let (_cmd, status, sector_data) = self.recv_response()?;
            if status != STATUS_OK {
                bail!(
                    "Read error at LBA {}: {}",
                    lba as u64 + i as u64,
                    status_name(status)
                );
            }
            // Packet 2: completion (0 bytes)
            let (_cmd2, final_status, _) = self.recv_response()?;
            if final_status != STATUS_OK {
                bail!(
                    "Read completion error at LBA {}: {}",
                    lba as u64 + i as u64,
                    status_name(final_status)
                );
            }
            data.extend_from_slice(&sector_data);
        }
        Ok(data)
    }

    /// Multi-block read (CMD18): one command, N sector packets + 1 completion packet.
    ///
    /// Each packet from FPGA: [0x55] [CMD] [STATUS] [LEN_H] [LEN_L] [512 bytes] [CRC8]
    /// IMPORTANT: Read exact byte counts — do NOT search for 0x55 header between packets,
    /// because 0x55 can appear inside sector data.
    fn read_sectors_multi(&mut self, lba: u32, count: u16) -> Result<Vec<u8>> {
        let mut payload = Vec::with_capacity(6);
        payload.extend_from_slice(&lba.to_be_bytes());
        payload.extend_from_slice(&count.to_be_bytes());

        self.send_command_no_recv(CMD_READ_SECTOR, &payload)?;

        let mut data = Vec::with_capacity(count as usize * SECTOR_SIZE);
        for i in 0..count {
            // Read header (must be 0x55)
            let mut hdr = [0u8; 1];
            self.transport.read_exact(&mut hdr)?;
            if hdr[0] != HEADER_RX {
                bail!(
                    "Multi-read sector {}/{}: expected header 0x55, got 0x{:02x}",
                    i,
                    count,
                    hdr[0]
                );
            }

            // Read CMD, STATUS, LEN_H, LEN_L
            let mut pkt_hdr = [0u8; 4];
            self.transport.read_exact(&mut pkt_hdr)?;
            let cmd_id = pkt_hdr[0];
            let status = pkt_hdr[1];
            let length = ((pkt_hdr[2] as u16) << 8) | pkt_hdr[3] as u16;

            if status != STATUS_OK {
                bail!(
                    "Multi-read error at sector {}/{} (LBA {}): {}",
                    i,
                    count,
                    lba as u64 + i as u64,
                    status_name(status)
                );
            }
            if length as usize != SECTOR_SIZE {
                bail!(
                    "Short sector at {}/{}: length={} (cmd=0x{:02x})",
                    i,
                    count,
                    length,
                    cmd_id
                );
            }

            // Read payload (512 bytes) + CRC (1 byte) in one call
            let mut sector_buf = vec![0u8; SECTOR_SIZE + 1];
            self.transport.read_exact(&mut sector_buf)?;

            // Verify CRC
            let crc_byte = sector_buf[SECTOR_SIZE];
            let mut crc_data = Vec::with_capacity(4 + SECTOR_SIZE);
            crc_data.push(cmd_id);
            crc_data.push(status);
            crc_data.extend_from_slice(&length.to_be_bytes());
            crc_data.extend_from_slice(&sector_buf[..SECTOR_SIZE]);
            let expected = crc8(&crc_data);
            if crc_byte != expected {
                bail!(
                    "Multi-read sector {}: CRC mismatch got=0x{:02x} expected=0x{:02x}",
                    i,
                    crc_byte,
                    expected
                );
            }

            data.extend_from_slice(&sector_buf[..SECTOR_SIZE]);
        }

        // Final completion packet (0-byte payload)
        let (_cmd, final_status, _) = self.recv_response()?;
        if final_status != STATUS_OK {
            bail!("Multi-read completion error: {}", status_name(final_status));
        }

        Ok(data)
    }

    /// Max sectors per multi-sector write (FPGA 16-bank FIFO hw limit)
    const MAX_WRITE_CHUNK: usize = 16;

    /// Write sectors to eMMC using multi-sector CMD25 for count > 1
    pub fn write_sectors(&mut self, lba: u32, data: &[u8]) -> Result<()> {
        let mut padded;
        let data = if data.len() % SECTOR_SIZE != 0 {
            padded = data.to_vec();
            padded.resize(data.len() + (SECTOR_SIZE - data.len() % SECTOR_SIZE), 0);
            &padded
        } else {
            data
        };

        let total = data.len() / SECTOR_SIZE;
        let mut offset = 0;
        let mut current_lba = lba;
        let mut remaining = total;

        while remaining > 0 {
            let n = remaining.min(Self::MAX_WRITE_CHUNK);
            let chunk = &data[offset..offset + n * SECTOR_SIZE];

            let mut payload = Vec::with_capacity(6 + n * SECTOR_SIZE);
            payload.extend_from_slice(&current_lba.to_be_bytes());
            payload.extend_from_slice(&(n as u16).to_be_bytes());
            payload.extend_from_slice(chunk);

            let (_cmd, status, _resp) = self.send_command(CMD_WRITE_SECTOR, &payload)?;
            if status != STATUS_OK {
                bail!(
                    "Write error at LBA {}, count={}: {}",
                    current_lba,
                    n,
                    status_name(status)
                );
            }

            current_lba += n as u32;
            offset += n * SECTOR_SIZE;
            remaining -= n;
        }
        Ok(())
    }

    /// Send a write command without waiting for response (for pipelining).
    /// Returns the number of sectors sent.
    pub fn send_write_command(&mut self, lba: u32, data: &[u8]) -> Result<usize> {
        let count = data.len() / SECTOR_SIZE;
        let mut payload = Vec::with_capacity(6 + data.len());
        payload.extend_from_slice(&lba.to_be_bytes());
        payload.extend_from_slice(&(count as u16).to_be_bytes());
        payload.extend_from_slice(data);
        self.send_command_no_recv(CMD_WRITE_SECTOR, &payload)?;
        Ok(count)
    }

    /// Receive write response (for pipelining). Returns Ok on STATUS_OK.
    pub fn recv_write_response(&mut self, lba: u32) -> Result<()> {
        let (_cmd, status, _resp) = self.recv_response()?;
        if status != STATUS_OK {
            bail!("Write error at LBA {}: {}", lba, status_name(status));
        }
        Ok(())
    }

    /// Erase sectors
    pub fn erase(&mut self, lba: u32, count: u16) -> Result<()> {
        let mut payload = Vec::with_capacity(6);
        payload.extend_from_slice(&lba.to_be_bytes());
        payload.extend_from_slice(&count.to_be_bytes());

        let (_cmd, status, _resp) = self.send_command(CMD_ERASE, &payload)?;
        if status != STATUS_OK {
            bail!("Erase failed at LBA {}: {}", lba, status_name(status));
        }
        Ok(())
    }

    /// Secure erase sectors (CMD38 arg=0x80000000, physical overwrite)
    pub fn secure_erase(&mut self, lba: u32, count: u16) -> Result<()> {
        let mut payload = Vec::with_capacity(6);
        payload.extend_from_slice(&lba.to_be_bytes());
        payload.extend_from_slice(&count.to_be_bytes());

        let (_cmd, status, _resp) = self.send_command(CMD_SECURE_ERASE, &payload)?;
        if status != STATUS_OK {
            bail!(
                "Secure erase failed at LBA {}: {}",
                lba,
                status_name(status)
            );
        }
        Ok(())
    }

    /// Write a byte to ExtCSD via CMD6 SWITCH
    pub fn write_ext_csd(&mut self, index: u8, value: u8) -> Result<()> {
        let (_cmd, status, _resp) = self.send_command(CMD_WRITE_EXT_CSD, &[index, value])?;
        if status != STATUS_OK {
            bail!("WRITE_EXT_CSD failed: {}", status_name(status));
        }
        Ok(())
    }

    /// Read Card Status Register via CMD13 SEND_STATUS.
    /// Returns 32-bit Card Status Register value.
    pub fn get_card_status(&mut self) -> Result<u32> {
        let (_cmd, status, payload) = self.send_command(CMD_GET_CARD_STATUS, &[])?;
        if status != STATUS_OK {
            bail!("GET_CARD_STATUS failed: {}", status_name(status));
        }
        if payload.len() < 4 {
            bail!("Short card status: {} bytes", payload.len());
        }
        Ok(u32::from_be_bytes([
            payload[0], payload[1], payload[2], payload[3],
        ]))
    }

    /// Full re-initialization: CMD0 + init sequence.
    /// Useful for error recovery when the card is in an unknown state.
    pub fn reinit(&mut self) -> Result<()> {
        // Increase timeout for init sequence (can take ~1s)
        self.transport.set_timeout(Duration::from_secs(5))?;
        let result = self.send_command(CMD_REINIT, &[]);
        // Restore default timeout
        let _ = self.transport.set_timeout(Duration::from_secs(2));
        let (_cmd, status, _payload) = result?;
        if status != STATUS_OK {
            bail!("REINIT failed: {}", status_name(status));
        }
        Ok(())
    }

    /// Set eMMC clock speed by preset index (0-6).
    pub fn set_clk_speed(&mut self, preset: u8) -> Result<()> {
        let (_cmd, status, _payload) = self.send_command(CMD_SET_CLK_DIV, &[preset])?;
        if status != STATUS_OK {
            bail!("SET_CLK_DIV failed: {}", status_name(status));
        }
        Ok(())
    }

    /// Set UART baud rate by preset index (0-3).
    /// Response is sent on the OLD baud rate. Reconnection must happen at caller level.
    /// No-op in FIFO mode (no baud concept).
    pub fn set_baud(&mut self, preset: u8) -> Result<()> {
        if self.transport.is_fifo() {
            return Ok(());
        }
        let (_cmd, status, _payload) = self.send_command(CMD_SET_BAUD, &[preset])?;
        if status != STATUS_OK {
            bail!("SET_BAUD failed: {}", status_name(status));
        }
        Ok(())
    }

    /// Enable/disable RPMB mode. In RPMB mode, FPGA uses CMD25/CMD18 for count=1
    /// and automatically sends CMD23 SET_BLOCK_COUNT before each transfer.
    pub fn set_rpmb_mode(&mut self, enable: bool) -> Result<()> {
        let (_cmd, status, _payload) = self.send_command(CMD_SET_RPMB_MODE, &[enable as u8])?;
        if status != STATUS_OK {
            bail!("SET_RPMB_MODE failed: {}", status_name(status));
        }
        Ok(())
    }

    /// Set eMMC bus width. width=1 for 1-bit, width=4 for 4-bit.
    /// Sends CMD6 SWITCH to ExtCSD[183] (BUS_WIDTH).
    pub fn set_bus_width(&mut self, width: u8) -> Result<()> {
        let val = match width {
            1 => 0u8,
            4 => 1u8,
            _ => bail!("Bus width must be 1 or 4, got {}", width),
        };
        let (_cmd, status, _payload) = self.send_command(CMD_SET_BUS_WIDTH, &[val])?;
        if status != STATUS_OK {
            bail!("SET_BUS_WIDTH failed: {}", status_name(status));
        }
        Ok(())
    }

    /// Enable eMMC write cache (ExtCSD[33] CACHE_CTRL=1).
    /// Returns Ok(true) if cache enabled, Ok(false) if card doesn't support cache.
    pub fn enable_cache(&mut self) -> Result<bool> {
        let ext_csd = self.get_ext_csd()?;
        // CACHE_SIZE at offset 249, 4 bytes LE
        let cache_size =
            u32::from_le_bytes([ext_csd[249], ext_csd[250], ext_csd[251], ext_csd[252]]);
        if cache_size == 0 {
            return Ok(false);
        }
        // Check if already enabled
        if ext_csd[33] == 1 {
            return Ok(true);
        }
        self.write_ext_csd(33, 1)?;
        Ok(true)
    }

    /// Flush eMMC write cache to flash (ExtCSD[32] FLUSH_CACHE=1).
    pub fn flush_cache(&mut self) -> Result<()> {
        self.write_ext_csd(32, 1)
    }

    /// Send a raw eMMC command (arbitrary CMD index + argument).
    /// Returns (protocol_status, response_data).
    pub fn send_raw_cmd(
        &mut self,
        cmd_index: u8,
        argument: u32,
        resp_expected: bool,
        resp_long: bool,
        check_busy: bool,
    ) -> Result<(u8, Vec<u8>)> {
        let flags = (resp_expected as u8) | ((resp_long as u8) << 1) | ((check_busy as u8) << 2);
        let mut payload = vec![cmd_index & 0x3F];
        payload.extend_from_slice(&argument.to_be_bytes());
        payload.push(flags);
        let (_cmd, status, data) = self.send_command(CMD_SEND_RAW, &payload)?;
        Ok((status, data))
    }

    /// Send command and receive response.
    /// Returns (cmd_id, status, payload).
    fn send_command(&mut self, cmd_id: u8, payload: &[u8]) -> Result<(u8, u8, Vec<u8>)> {
        self.send_command_no_recv(cmd_id, payload)?;
        self.recv_response()
    }

    /// Send command packet without waiting for response
    fn send_command_no_recv(&mut self, cmd_id: u8, payload: &[u8]) -> Result<()> {
        let length = payload.len() as u16;
        // CRC covers: CMD + LEN_H + LEN_L + PAYLOAD
        let mut crc_data = Vec::with_capacity(3 + payload.len());
        crc_data.push(cmd_id);
        crc_data.extend_from_slice(&length.to_be_bytes());
        crc_data.extend_from_slice(payload);
        let checksum = crc8(&crc_data);

        let mut packet = Vec::with_capacity(4 + payload.len() + 1);
        packet.push(HEADER_TX);
        packet.push(cmd_id);
        packet.extend_from_slice(&length.to_be_bytes());
        packet.extend_from_slice(payload);
        packet.push(checksum);

        self.transport.write_all(&packet)?;
        self.transport.flush()?;
        Ok(())
    }

    /// Receive response packet.
    /// Returns (cmd_id, status, payload).
    fn recv_response(&mut self) -> Result<(u8, u8, Vec<u8>)> {
        // Wait for header byte 0x55 (limit sync scan to prevent infinite loop)
        let mut buf = [0u8; 1];
        let mut sync_attempts = 0u32;
        loop {
            let n = self.transport.read(&mut buf)?;
            if n == 0 {
                bail!("No response from FPGA (timeout)");
            }
            if buf[0] == HEADER_RX {
                break;
            }
            sync_attempts += 1;
            if sync_attempts > 4096 {
                bail!("FPGA sync lost (4096 bytes without header)");
            }
        }

        // Read CMD_ID, STATUS, LEN_H, LEN_L
        let mut hdr = [0u8; 4];
        self.transport.read_exact(&mut hdr)?;

        let cmd_id = hdr[0];
        let status = hdr[1];
        let length = ((hdr[2] as u16) << 8) | hdr[3] as u16;

        // Read payload
        let mut payload = vec![0u8; length as usize];
        if length > 0 {
            self.transport.read_exact(&mut payload)?;
        }

        // Read CRC
        let mut crc_byte = [0u8; 1];
        self.transport.read_exact(&mut crc_byte)?;

        // Verify CRC
        let mut crc_data = Vec::with_capacity(4 + payload.len());
        crc_data.push(cmd_id);
        crc_data.push(status);
        crc_data.extend_from_slice(&(length).to_be_bytes());
        crc_data.extend_from_slice(&payload);
        let expected = crc8(&crc_data);
        if crc_byte[0] != expected {
            bail!(
                "CRC mismatch: got 0x{:02X}, expected 0x{:02X}",
                crc_byte[0],
                expected
            );
        }

        Ok((cmd_id, status, payload))
    }
}

/// eMMC clock frequencies by preset index (Hz)
pub const EMMC_CLK_FREQS: [u32; 7] = [
    2_000_000,  // preset 0: 2 MHz
    3_750_000,  // preset 1: 3.75 MHz
    6_000_000,  // preset 2: 6 MHz
    10_000_000, // preset 3: 10 MHz
    15_000_000, // preset 4: 15 MHz
    15_000_000, // preset 5: 15 MHz (same)
    30_000_000, // preset 6: 30 MHz
];

/// UART baud rates by preset index
pub const UART_BAUD_RATES: [u32; 4] = [
    3_000_000,  // preset 0: 3 Mbaud
    6_000_000,  // preset 1: 6 Mbaud
    7_500_000,  // preset 2: 7.5 Mbaud (rejected by FPGA)
    12_000_000, // preset 3: 12 Mbaud
];

/// Retry a fallible operation up to `max_retries` times with 50ms delay between attempts.
/// Logs each retry attempt via tracing. Returns the last error if all retries fail.
pub fn with_retry<F, T>(max_retries: u32, mut f: F) -> Result<T>
where
    F: FnMut() -> Result<T>,
{
    let mut last_err = None;
    for attempt in 0..=max_retries {
        match f() {
            Ok(val) => return Ok(val),
            Err(e) => {
                if attempt < max_retries {
                    tracing::warn!("Retry {}/{}: {}", attempt + 1, max_retries, e);
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                last_err = Some(e);
            }
        }
    }
    Err(last_err.unwrap())
}

/// CMD18 chunk size — always 64 with FPGA CLK gating backpressure.
pub fn safe_read_chunk(_baud: u32, _emmc_freq: u32) -> u16 {
    64
}

/// List available serial ports (only ttyACM* and ttyUSB* — real USB devices)
pub fn list_serial_ports() -> Vec<String> {
    serialport::available_ports()
        .unwrap_or_default()
        .into_iter()
        .filter(|p| {
            let name = &p.port_name;
            name.contains("ttyACM") || name.contains("ttyUSB")
        })
        .map(|p| p.port_name)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_crc8() {
        assert_eq!(crc8(&[]), 0);
        assert_eq!(crc8(&[0x01, 0x00, 0x00]), crc8(&[0x01, 0x00, 0x00]));
        // CRC of PING command: CMD=0x01, LEN=0x0000
        let ping_crc = crc8(&[0x01, 0x00, 0x00]);
        assert_ne!(ping_crc, 0); // should be non-zero for non-zero input
    }
}
