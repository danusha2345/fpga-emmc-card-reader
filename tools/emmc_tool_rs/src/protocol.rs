pub const HEADER_TX: u8 = 0xAA;
pub const HEADER_RX: u8 = 0x55;
pub const SECTOR_SIZE: usize = 512;

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

pub const STATUS_OK: u8 = 0x00;
pub const STATUS_ERR_CRC: u8 = 0x01;
pub const STATUS_ERR_CMD: u8 = 0x02;
pub const STATUS_ERR_EMMC: u8 = 0x03;
pub const STATUS_BUSY: u8 = 0x04;

pub const READ_CHUNK_SECTORS: u16 = 64;
pub const WRITE_CHUNK_SECTORS: u16 = 32;

/// Clock preset → (divider, MHz)
pub const CLK_PRESETS: [(u8, f64); 7] = [
    (15, 2.0),    // preset 0
    (8, 3.75),    // preset 1
    (5, 6.0),     // preset 2
    (3, 10.0),    // preset 3
    (2, 15.0),    // preset 4
    (0, 0.0),     // preset 5 (unused)
    (1, 30.0),    // preset 6
];

/// Baud preset → actual baud rate
pub const BAUD_PRESETS: [(u8, u32); 4] = [
    (0, 3_000_000),
    (1, 6_000_000),
    (2, 9_000_000),
    (3, 12_000_000),
];

pub fn mhz_to_clk_preset(mhz: f64) -> Option<u8> {
    let mut best_preset = None;
    let mut best_diff = f64::MAX;
    for (i, &(_, freq)) in CLK_PRESETS.iter().enumerate() {
        if freq == 0.0 {
            continue;
        }
        let diff = (freq - mhz).abs();
        if diff < best_diff {
            best_diff = diff;
            best_preset = Some(i as u8);
        }
    }
    best_preset
}

pub fn status_name(code: u8) -> &'static str {
    match code {
        STATUS_OK => "OK",
        STATUS_ERR_CRC => "CRC Error",
        STATUS_ERR_CMD => "Unknown Command",
        STATUS_ERR_EMMC => "eMMC Error",
        STATUS_BUSY => "Busy",
        _ => "Unknown",
    }
}

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

pub fn build_tx_packet(cmd_id: u8, payload: &[u8]) -> Vec<u8> {
    let length = payload.len() as u16;
    let mut crc_data = Vec::with_capacity(3 + payload.len());
    crc_data.push(cmd_id);
    crc_data.push((length >> 8) as u8);
    crc_data.push((length & 0xFF) as u8);
    crc_data.extend_from_slice(payload);
    let checksum = crc8(&crc_data);

    let mut packet = Vec::with_capacity(1 + crc_data.len() + 1);
    packet.push(HEADER_TX);
    packet.extend_from_slice(&crc_data);
    packet.push(checksum);
    packet
}

pub fn parse_int(s: &str) -> anyhow::Result<u64> {
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        Ok(u64::from_str_radix(hex, 16)?)
    } else {
        Ok(s.parse::<u64>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_crc8() {
        assert_eq!(crc8(b"123456789"), 0xF4);
    }

    #[test]
    fn test_parse_int_decimal() {
        assert_eq!(parse_int("123").unwrap(), 123);
    }

    #[test]
    fn test_parse_int_hex() {
        assert_eq!(parse_int("0x1A").unwrap(), 26);
        assert_eq!(parse_int("0X1a").unwrap(), 26);
    }

    #[test]
    fn test_build_tx_packet_ping() {
        let pkt = build_tx_packet(CMD_PING, &[]);
        assert_eq!(pkt[0], HEADER_TX);
        assert_eq!(pkt[1], CMD_PING);
        assert_eq!(pkt[2], 0x00); // LEN_H
        assert_eq!(pkt[3], 0x00); // LEN_L
        let expected_crc = crc8(&[CMD_PING, 0x00, 0x00]);
        assert_eq!(pkt[4], expected_crc);
    }
}
