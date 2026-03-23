use anyhow::{bail, Result};
use hmac::{Hmac, Mac};
use sha2::Sha256;

use crate::protocol::SECTOR_SIZE;
use crate::transport::EmmcTool;

type HmacSha256 = Hmac<Sha256>;

#[allow(dead_code)]
pub const RPMB_RESP_READ_COUNTER: u16 = 0x0200;
#[allow(dead_code)]
pub const RPMB_RESP_READ_DATA: u16 = 0x0400;

/// Default RPMB test key (all zeros)
pub const RPMB_TEST_KEY: [u8; 32] = [
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

// RPMB request types
pub const RPMB_REQ_READ_COUNTER: u16 = 0x0002;
pub const RPMB_REQ_READ_DATA: u16 = 0x0004;

#[derive(Debug)]
#[allow(dead_code)]
pub struct RpmbResponse {
    pub data: [u8; 256],
    pub nonce: [u8; 16],
    pub write_counter: u32,
    pub address: u16,
    pub block_count: u16,
    pub result: u16,
    pub req_resp: u16,
    pub mac: [u8; 32],
}

pub fn build_rpmb_frame(req_type: u16, address: u16, nonce: &[u8; 16]) -> [u8; SECTOR_SIZE] {
    let mut frame = [0u8; SECTOR_SIZE];
    // Nonce at offset 196..212
    frame[196..212].copy_from_slice(nonce);
    // Address at offset 226..228 (big-endian)
    frame[226] = (address >> 8) as u8;
    frame[227] = (address & 0xFF) as u8;
    // Request/Response type at offset 228..230 (big-endian)
    frame[228] = (req_type >> 8) as u8;
    frame[229] = (req_type & 0xFF) as u8;
    frame
}

pub fn parse_rpmb_frame(frame: &[u8]) -> Result<RpmbResponse> {
    if frame.len() < SECTOR_SIZE {
        bail!("RPMB frame too short: {} bytes", frame.len());
    }

    let mut data = [0u8; 256];
    data.copy_from_slice(&frame[0..256]);

    let mut nonce = [0u8; 16];
    nonce.copy_from_slice(&frame[196..212]);

    let write_counter = u32::from_be_bytes(frame[212..216].try_into().unwrap());
    let address = u16::from_be_bytes(frame[226..228].try_into().unwrap());
    let block_count = u16::from_be_bytes(frame[224..226].try_into().unwrap());
    let result = u16::from_be_bytes(frame[218..220].try_into().unwrap());
    let req_resp = u16::from_be_bytes(frame[228..230].try_into().unwrap());

    let mut mac = [0u8; 32];
    mac.copy_from_slice(&frame[SECTOR_SIZE - 32..SECTOR_SIZE]);

    Ok(RpmbResponse {
        data,
        nonce,
        write_counter,
        address,
        block_count,
        result,
        req_resp,
        mac,
    })
}

pub fn rpmb_calc_mac(frame: &[u8], key: &[u8; 32]) -> [u8; 32] {
    // MAC covers bytes 0..480 (everything except the last 32 bytes which is the MAC itself)
    let mut hmac = HmacSha256::new_from_slice(key).unwrap();
    hmac.update(&frame[..SECTOR_SIZE - 32]);
    let result = hmac.finalize();
    let mut mac = [0u8; 32];
    mac.copy_from_slice(&result.into_bytes());
    mac
}

pub fn rpmb_result_name(result: u16) -> &'static str {
    match result {
        0x0000 => "OK",
        0x0001 => "General failure",
        0x0002 => "Authentication failure",
        0x0003 => "Counter failure",
        0x0004 => "Address failure",
        0x0005 => "Write failure",
        0x0006 => "Read failure",
        0x0007 => "Key not programmed",
        0x0080 => "Write counter expired",
        _ => "Unknown",
    }
}

impl EmmcTool {
    pub fn rpmb_read_counter(&mut self) -> Result<(u32, bool)> {
        self.set_rpmb_mode(true)?;
        self.set_partition(3)?; // RPMB partition

        let nonce: [u8; 16] = rand_nonce();
        let frame = build_rpmb_frame(RPMB_REQ_READ_COUNTER, 0, &nonce);

        // Write request frame
        self.write_sectors(0, &frame)?;
        // Read response frame
        let resp_data = self.read_sectors(0, 1)?;

        self.set_partition(0)?; // back to user
        self.set_rpmb_mode(false)?;

        let resp = parse_rpmb_frame(&resp_data)?;

        if resp.result != 0 {
            bail!("RPMB read counter failed: {} (0x{:04X})",
                rpmb_result_name(resp.result), resp.result);
        }

        // Verify nonce
        if resp.nonce != nonce {
            bail!("RPMB nonce mismatch");
        }

        // Verify MAC
        let expected_mac = rpmb_calc_mac(&resp_data, &RPMB_TEST_KEY);
        let mac_ok = resp.mac == expected_mac;

        Ok((resp.write_counter, mac_ok))
    }

    pub fn rpmb_read_data(&mut self, address: u16) -> Result<RpmbResponse> {
        self.set_rpmb_mode(true)?;
        self.set_partition(3)?;

        let nonce: [u8; 16] = rand_nonce();
        let frame = build_rpmb_frame(RPMB_REQ_READ_DATA, address, &nonce);

        self.write_sectors(0, &frame)?;
        let resp_data = self.read_sectors(0, 1)?;

        self.set_partition(0)?;
        self.set_rpmb_mode(false)?;

        let resp = parse_rpmb_frame(&resp_data)?;

        if resp.result != 0 {
            bail!("RPMB read failed: {} (0x{:04X})",
                rpmb_result_name(resp.result), resp.result);
        }

        if resp.nonce != nonce {
            bail!("RPMB nonce mismatch");
        }

        // Verify MAC
        let expected_mac = rpmb_calc_mac(&resp_data, &RPMB_TEST_KEY);
        if resp.mac != expected_mac {
            eprintln!("Warning: RPMB MAC verification failed (wrong key?)");
        }

        Ok(resp)
    }
}

fn rand_nonce() -> [u8; 16] {
    let mut nonce = [0u8; 16];
    // Simple timestamp-based nonce (good enough for read operations)
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let ns = now.as_nanos();
    nonce[0..8].copy_from_slice(&(ns as u64).to_le_bytes());
    nonce[8..16].copy_from_slice(&((ns >> 64) as u64).to_le_bytes());
    // Mix in process ID for uniqueness
    let pid = std::process::id();
    nonce[12..16].copy_from_slice(&pid.to_le_bytes());
    nonce
}
