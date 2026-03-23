use std::time::Duration;
use std::thread;

use anyhow::{bail, Result};

use crate::ext4::SectorIO;
use crate::protocol::*;
use crate::transport::{EmmcTool, RxPacket};

impl SectorIO for EmmcTool {
    fn read_sectors(&mut self, lba: u32, count: u16) -> Result<Vec<u8>> {
        self.read_sectors(lba, count)
    }

    fn write_sectors(&mut self, lba: u32, data: &[u8]) -> Result<()> {
        self.write_sectors(lba, data)
    }
}

fn hex_encode(data: &[u8]) -> String {
    data.iter().map(|b| format!("{:02x}", b)).collect()
}

#[allow(dead_code)]
pub struct CardInfo {
    pub cid_raw: String,
    pub csd_raw: String,
    pub manufacturer_id: u8,
    pub device_type: u16,
    pub product_name: String,
    pub product_rev: String,
    pub serial_number: u32,
    pub mfg_date: String,
    pub csd_structure: u8,
    pub capacity_bytes: Option<u64>,
    pub capacity_note: Option<String>,
}

#[allow(dead_code)]
pub struct ExtCsdInfo {
    pub life_time_est_a: u8,
    pub life_time_est_b: u8,
    pub pre_eol_info: u8,
    pub sec_count: u32,
    pub capacity_bytes: u64,
    pub boot_partition_size: u64,
    pub rpmb_size: u64,
    pub boot_ack: bool,
    pub boot_partition: u8,
    pub partition_access: u8,
    pub hs_support: bool,
    pub hs52_support: bool,
    pub ddr_support: bool,
    pub fw_version: String,
}

impl EmmcTool {
    pub fn ping(&mut self) -> Result<bool> {
        let rx = self.send_command(CMD_PING, &[])?;
        Ok(rx.status == STATUS_OK)
    }

    pub fn get_info(&mut self) -> Result<CardInfo> {
        let rx = self.send_command(CMD_GET_INFO, &[])?;
        check_status(&rx, "GET_INFO")?;
        if rx.payload.len() < 32 {
            bail!("Short info payload: {} bytes", rx.payload.len());
        }
        let cid = &rx.payload[0..16];
        let csd = &rx.payload[16..32];
        Ok(parse_info(cid, csd))
    }

    pub fn read_sectors(&mut self, lba: u32, count: u16) -> Result<Vec<u8>> {
        let mut payload = Vec::with_capacity(6);
        payload.extend_from_slice(&lba.to_be_bytes());
        payload.extend_from_slice(&count.to_be_bytes());
        self.send_command_no_recv(CMD_READ_SECTOR, &payload)?;

        let mut data = Vec::with_capacity(count as usize * SECTOR_SIZE);
        for i in 0..count {
            let rx = self.recv_response()?;
            if rx.status != STATUS_OK {
                bail!(
                    "Read error at LBA {}: {}",
                    lba as u64 + i as u64,
                    status_name(rx.status)
                );
            }
            data.extend_from_slice(&rx.payload);
        }
        Ok(data)
    }

    pub fn write_sectors(&mut self, lba: u32, data: &[u8]) -> Result<()> {
        let mut padded;
        let write_data = if data.len() % SECTOR_SIZE != 0 {
            padded = data.to_vec();
            padded.resize(data.len() + (SECTOR_SIZE - data.len() % SECTOR_SIZE), 0);
            &padded
        } else {
            data
        };

        let count = write_data.len() / SECTOR_SIZE;
        for i in 0..count {
            let sector = &write_data[i * SECTOR_SIZE..(i + 1) * SECTOR_SIZE];
            let mut payload = Vec::with_capacity(6 + SECTOR_SIZE);
            payload.extend_from_slice(&(lba + i as u32).to_be_bytes());
            payload.extend_from_slice(&1u16.to_be_bytes());
            payload.extend_from_slice(sector);
            let rx = self.send_command(CMD_WRITE_SECTOR, &payload)?;
            if rx.status != STATUS_OK {
                bail!(
                    "Write error at LBA {}: {}",
                    lba as u64 + i as u64,
                    status_name(rx.status)
                );
            }
        }
        Ok(())
    }

    pub fn get_status(&mut self) -> Result<u8> {
        let rx = self.send_command(CMD_GET_STATUS, &[])?;
        check_status(&rx, "GET_STATUS")?;
        Ok(if rx.payload.is_empty() {
            0
        } else {
            rx.payload[0]
        })
    }

    pub fn get_ext_csd(&mut self) -> Result<Vec<u8>> {
        self.send_command_no_recv(CMD_GET_EXT_CSD, &[])?;
        let rx = self.recv_response()?;
        check_status(&rx, "GET_EXT_CSD")?;
        if rx.payload.len() < 512 {
            bail!("Short ExtCSD: {} bytes", rx.payload.len());
        }
        Ok(rx.payload[..512].to_vec())
    }

    pub fn set_partition(&mut self, partition: u8) -> Result<()> {
        let rx = self.send_command(CMD_SET_PARTITION, &[partition & 0x07])?;
        check_status(&rx, "SET_PARTITION")?;
        Ok(())
    }

    pub fn erase(&mut self, lba: u32, count: u16) -> Result<()> {
        let mut payload = Vec::with_capacity(6);
        payload.extend_from_slice(&lba.to_be_bytes());
        payload.extend_from_slice(&count.to_be_bytes());
        let rx = self.send_command(CMD_ERASE, &payload)?;
        check_status(&rx, "ERASE")?;
        Ok(())
    }

    pub fn secure_erase(&mut self, lba: u32, count: u16) -> Result<()> {
        let mut payload = Vec::with_capacity(6);
        payload.extend_from_slice(&lba.to_be_bytes());
        payload.extend_from_slice(&count.to_be_bytes());
        let rx = self.send_command(CMD_SECURE_ERASE, &payload)?;
        check_status(&rx, "SECURE_ERASE")?;
        Ok(())
    }

    pub fn write_ext_csd(&mut self, index: u8, value: u8) -> Result<()> {
        let rx = self.send_command(CMD_WRITE_EXT_CSD, &[index, value])?;
        check_status(&rx, "WRITE_EXT_CSD")?;
        Ok(())
    }

    pub fn get_card_status(&mut self) -> Result<u32> {
        let rx = self.send_command(CMD_GET_CARD_STATUS, &[])?;
        check_status(&rx, "GET_CARD_STATUS")?;
        if rx.payload.len() < 4 {
            bail!("Short card status payload: {} bytes", rx.payload.len());
        }
        Ok(u32::from_be_bytes(rx.payload[0..4].try_into().unwrap()))
    }

    pub fn reinit(&mut self) -> Result<()> {
        self.set_timeout(Duration::from_secs(5))?;
        let rx = self.send_command(CMD_REINIT, &[]);
        self.restore_timeout()?;
        check_status(&rx?, "REINIT")?;
        Ok(())
    }

    pub fn set_clk_speed(&mut self, preset: u8) -> Result<()> {
        let rx = self.send_command(CMD_SET_CLK_DIV, &[preset])?;
        check_status(&rx, "SET_CLK_DIV")?;
        Ok(())
    }

    pub fn send_raw_cmd(&mut self, index: u8, arg: u32, flags: u8) -> Result<Vec<u8>> {
        let mut payload = Vec::with_capacity(6);
        payload.push(index);
        payload.extend_from_slice(&arg.to_be_bytes());
        payload.push(flags);
        let rx = self.send_command(CMD_SEND_RAW, &payload)?;
        check_status(&rx, "SEND_RAW")?;
        Ok(rx.payload)
    }

    pub fn set_baud(&mut self, preset: u8) -> Result<()> {
        let baud = BAUD_PRESETS
            .iter()
            .find(|(p, _)| *p == preset)
            .map(|(_, b)| *b)
            .unwrap_or(3_000_000);

        // Send baud change command
        let rx = self.send_command(CMD_SET_BAUD, &[preset])?;
        check_status(&rx, "SET_BAUD")?;

        // Close and reopen port at new baud
        thread::sleep(Duration::from_millis(70));
        self.reopen(baud)?;

        // Verify connection
        thread::sleep(Duration::from_millis(30));
        if !self.ping()? {
            bail!("Failed to verify connection after baud change to {}", baud);
        }
        Ok(())
    }

    pub fn set_rpmb_mode(&mut self, enable: bool) -> Result<()> {
        let rx = self.send_command(CMD_SET_RPMB_MODE, &[enable as u8])?;
        check_status(&rx, "SET_RPMB_MODE")?;
        Ok(())
    }

    pub fn set_bus_width(&mut self, width: u8) -> Result<()> {
        let w = match width {
            1 => 0,
            4 => 1,
            _ => bail!("Invalid bus width: {}. Use 1 or 4", width),
        };
        let rx = self.send_command(CMD_SET_BUS_WIDTH, &[w])?;
        check_status(&rx, "SET_BUS_WIDTH")?;
        Ok(())
    }
}

fn check_status(rx: &RxPacket, cmd_name: &str) -> Result<()> {
    if rx.status != STATUS_OK {
        bail!("{} failed: {}", cmd_name, status_name(rx.status));
    }
    Ok(())
}

fn parse_info(cid: &[u8], csd: &[u8]) -> CardInfo {
    let product_name = String::from_utf8_lossy(&cid[3..9])
        .trim()
        .to_string();

    let csd_structure = (csd[0] >> 6) & 0x03;
    let read_bl_len = csd[5] & 0x0F;
    let c_size = ((csd[6] as u32 & 0x03) << 10) | ((csd[7] as u32) << 2) | ((csd[8] as u32) >> 6);
    let c_size_mult = ((csd[9] as u32 & 0x03) << 1) | ((csd[10] as u32) >> 7);

    let (capacity_bytes, capacity_note) = if c_size == 0xFFF {
        (None, Some(">= 2 GB (need EXT_CSD for exact size)".to_string()))
    } else {
        let blocks = (c_size + 1) * (1 << (c_size_mult + 2));
        (Some(blocks as u64 * (1u64 << read_bl_len)), None)
    };

    let serial_number =
        ((cid[10] as u32) << 24) | ((cid[11] as u32) << 16) | ((cid[12] as u32) << 8) | (cid[13] as u32);

    CardInfo {
        cid_raw: hex_encode(cid),
        csd_raw: hex_encode(csd),
        manufacturer_id: cid[0],
        device_type: ((cid[1] as u16) << 8) | cid[2] as u16,
        product_name,
        product_rev: format!("{}.{}", cid[9] >> 4, cid[9] & 0xF),
        serial_number,
        mfg_date: format!("{}-{:02}", 2013 + (cid[14] >> 4) as u16, cid[14] & 0xF),
        csd_structure,
        capacity_bytes,
        capacity_note,
    }
}

pub fn parse_ext_csd(ext_csd: &[u8]) -> ExtCsdInfo {
    let sec_count = u32::from_le_bytes(ext_csd[212..216].try_into().unwrap());
    let boot_size_multi = ext_csd[226] as u64;
    let rpmb_size_mult = ext_csd[168] as u64;
    let part_config = ext_csd[179];
    let device_type = ext_csd[196];

    ExtCsdInfo {
        life_time_est_a: ext_csd[267],
        life_time_est_b: ext_csd[268],
        pre_eol_info: ext_csd[269],
        sec_count,
        capacity_bytes: sec_count as u64 * 512,
        boot_partition_size: boot_size_multi * 128 * 1024,
        rpmb_size: rpmb_size_mult * 128 * 1024,
        boot_ack: (part_config >> 6) & 0x01 != 0,
        boot_partition: (part_config >> 3) & 0x07,
        partition_access: part_config & 0x07,
        hs_support: device_type & 0x01 != 0,
        hs52_support: device_type & 0x02 != 0,
        ddr_support: device_type & 0x04 != 0,
        fw_version: hex_encode(&ext_csd[254..262]),
    }
}
