//! RPMB (Replay Protected Memory Block) frame protocol.
//!
//! Implements JEDEC eMMC 5.1 section 6.6.22 RPMB authenticated frame protocol.
//! Frame layout: 512 bytes with HMAC-SHA256 MAC over bytes [228..512].

use crate::protocol::EmmcConnection;
use anyhow::{bail, Result};
use hmac::{Hmac, Mac};
use sha2::Sha256;

/// Hardcoded RPMB test key (all zeros)
pub const RPMB_TEST_KEY: [u8; 32] = [
    0xD3, 0xEB, 0x3E, 0xC3, 0x6E, 0x33, 0x4C, 0x9F, 0x98, 0x8C, 0xE2, 0xC0, 0xB8, 0x59, 0x54, 0x61,
    0x0D, 0x2B, 0xCF, 0x86, 0x64, 0x84, 0x4D, 0xF2, 0xAB, 0x56, 0xC9, 0xB4, 0x1B, 0xB7, 0x01, 0xE4,
];

/// RPMB result code names
pub fn result_name(code: u16) -> &'static str {
    match code {
        0x0000 => "OK",
        0x0001 => "General failure",
        0x0002 => "Authentication failure",
        0x0003 => "Counter failure",
        0x0004 => "Address failure",
        0x0005 => "Write failure",
        0x0006 => "Read failure",
        0x0007 => "Auth key not programmed",
        _ => "Unknown",
    }
}

/// Parsed RPMB frame
#[derive(Debug, Clone)]
pub struct RpmbFrame {
    pub mac: [u8; 32],
    pub data: [u8; 256],
    pub nonce: [u8; 16],
    pub write_counter: u32,
    pub address: u16,
    pub block_count: u16,
    pub result: u16,
    pub req_resp_type: u16,
}

/// Build a 512-byte RPMB request frame
pub fn build_frame(
    req_type: u16,
    address: u16,
    block_count: u16,
    nonce: Option<&[u8; 16]>,
    data: Option<&[u8; 256]>,
    mac: Option<&[u8; 32]>,
) -> [u8; 512] {
    let mut frame = [0u8; 512];
    if let Some(m) = mac {
        frame[196..228].copy_from_slice(m);
    }
    if let Some(d) = data {
        frame[228..484].copy_from_slice(d);
    }
    if let Some(n) = nonce {
        frame[484..500].copy_from_slice(n);
    }
    frame[504] = (address >> 8) as u8;
    frame[505] = address as u8;
    frame[506] = (block_count >> 8) as u8;
    frame[507] = block_count as u8;
    frame[510] = (req_type >> 8) as u8;
    frame[511] = req_type as u8;
    frame
}

/// Parse a 512-byte RPMB response frame
pub fn parse_frame(raw: &[u8]) -> RpmbFrame {
    let mut mac = [0u8; 32];
    let mut data = [0u8; 256];
    let mut nonce = [0u8; 16];
    mac.copy_from_slice(&raw[196..228]);
    data.copy_from_slice(&raw[228..484]);
    nonce.copy_from_slice(&raw[484..500]);
    RpmbFrame {
        mac,
        data,
        nonce,
        write_counter: u32::from_be_bytes([raw[500], raw[501], raw[502], raw[503]]),
        address: u16::from_be_bytes([raw[504], raw[505]]),
        block_count: u16::from_be_bytes([raw[506], raw[507]]),
        result: u16::from_be_bytes([raw[508], raw[509]]),
        req_resp_type: u16::from_be_bytes([raw[510], raw[511]]),
    }
}

/// Calculate HMAC-SHA256 MAC over bytes [228..512] of RPMB frame
pub fn calc_mac(frame: &[u8], key: &[u8; 32]) -> [u8; 32] {
    type HmacSha256 = Hmac<Sha256>;
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC key");
    mac.update(&frame[228..512]);
    let result = mac.finalize();
    let mut out = [0u8; 32];
    out.copy_from_slice(&result.into_bytes());
    out
}

/// Verify HMAC-SHA256 MAC in RPMB response frame
pub fn verify_mac(frame: &[u8], key: &[u8; 32]) -> bool {
    let expected = calc_mac(frame, key);
    frame[196..228] == expected
}

/// Read RPMB write counter.
/// Returns (parsed frame, mac_valid).
///
/// Sequence: set_rpmb_mode(true) → set_partition(3) → write request → read response →
/// set_partition(0) → set_rpmb_mode(false)
pub fn read_counter(conn: &mut EmmcConnection) -> Result<(RpmbFrame, bool)> {
    let mut nonce = [0u8; 16];
    getrandom(&mut nonce);
    let req = build_frame(0x0002, 0, 0, Some(&nonce), None, None);

    conn.set_rpmb_mode(true)?;
    let result = (|| -> Result<(RpmbFrame, bool)> {
        conn.set_partition(3)?;
        let inner_result = (|| -> Result<(RpmbFrame, bool)> {
            conn.write_sectors(0, &req)?;
            let resp_data = conn.read_sectors(0, 1)?;
            if resp_data.len() < 512 {
                bail!("RPMB response too short: {} bytes", resp_data.len());
            }
            let frame = parse_frame(&resp_data);
            if frame.result != 0 {
                tracing::warn!(
                    "RPMB result: 0x{:04x} ({})",
                    frame.result,
                    result_name(frame.result)
                );
            }
            let mac_valid = verify_mac(&resp_data, &RPMB_TEST_KEY);
            Ok((frame, mac_valid))
        })();
        let _ = conn.set_partition(0);
        inner_result
    })();
    let _ = conn.set_rpmb_mode(false);
    result
}

/// Authenticated RPMB read at given half-sector address.
/// Returns (parsed frame, mac_valid, raw 256-byte data).
pub fn read_data(conn: &mut EmmcConnection, address: u16) -> Result<(RpmbFrame, bool)> {
    let mut nonce = [0u8; 16];
    getrandom(&mut nonce);
    let req = build_frame(0x0004, address, 1, Some(&nonce), None, None);

    conn.set_rpmb_mode(true)?;
    let result = (|| -> Result<(RpmbFrame, bool)> {
        conn.set_partition(3)?;
        let inner_result = (|| -> Result<(RpmbFrame, bool)> {
            conn.write_sectors(0, &req)?;
            let resp_data = conn.read_sectors(0, 1)?;
            if resp_data.len() < 512 {
                bail!("RPMB response too short: {} bytes", resp_data.len());
            }
            let frame = parse_frame(&resp_data);
            if frame.result != 0 {
                tracing::warn!(
                    "RPMB result: 0x{:04x} ({})",
                    frame.result,
                    result_name(frame.result)
                );
            }
            let mac_valid = verify_mac(&resp_data, &RPMB_TEST_KEY);
            Ok((frame, mac_valid))
        })();
        let _ = conn.set_partition(0);
        inner_result
    })();
    let _ = conn.set_rpmb_mode(false);
    result
}

/// Simple random bytes using /dev/urandom or equivalent
fn getrandom(buf: &mut [u8]) {
    use std::io::Read;
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(buf);
    }
}
