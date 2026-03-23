use std::collections::HashMap;

use anyhow::{bail, Result};

use crate::protocol::SECTOR_SIZE;
use crate::transport::EmmcTool;

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct PartitionInfo {
    pub num: usize,
    pub type_name: String,
    pub start_lba: u64,
    pub size_sectors: u64,
    pub name: String,
    pub type_id: Option<u8>,
    pub type_guid: Option<String>,
    pub end_lba: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PartitionScheme {
    Mbr,
    Gpt,
}

impl std::fmt::Display for PartitionScheme {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PartitionScheme::Mbr => write!(f, "MBR"),
            PartitionScheme::Gpt => write!(f, "GPT"),
        }
    }
}

fn gpt_type_names() -> HashMap<&'static str, &'static str> {
    HashMap::from([
        ("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", "EFI System"),
        ("0fc63daf-8483-4772-8e79-3d69d8477de4", "Linux"),
        ("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7", "FAT/NTFS"),
        ("e3c9e316-0b5c-4db8-817d-f92df00215ae", "MS Reserved"),
        ("de94bba4-06d1-4d40-a16a-bfd50179d6ac", "Windows Recovery"),
        ("024dee41-33e7-11d3-9d69-0008c781f39f", "MBR Partition"),
    ])
}

fn mbr_type_name(id: u8) -> &'static str {
    match id {
        0x00 => "Empty",
        0x01 => "FAT12",
        0x04 => "FAT16 <32M",
        0x05 => "Extended",
        0x06 => "FAT16",
        0x07 => "NTFS/exFAT",
        0x0B => "FAT32",
        0x0C => "FAT32 LBA",
        0x0E => "FAT16 LBA",
        0x0F => "Extended LBA",
        0x82 => "Linux swap",
        0x83 => "Linux",
        0xEE => "GPT Protective",
        _ => "Unknown",
    }
}

fn parse_guid(raw: &[u8]) -> String {
    let p1 = u32::from_le_bytes(raw[0..4].try_into().unwrap());
    let p2 = u16::from_le_bytes(raw[4..6].try_into().unwrap());
    let p3 = u16::from_le_bytes(raw[6..8].try_into().unwrap());
    let p4 = &raw[8..16];
    format!(
        "{:08x}-{:04x}-{:04x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        p1, p2, p3, p4[0], p4[1], p4[2], p4[3], p4[4], p4[5], p4[6], p4[7]
    )
}

pub fn parse_mbr(mbr: &[u8]) -> Result<Vec<PartitionInfo>> {
    if mbr.len() < 512 || mbr[510] != 0x55 || mbr[511] != 0xAA {
        bail!("Invalid MBR signature");
    }

    let mut partitions = Vec::new();
    for i in 0..4 {
        let offset = 446 + i * 16;
        let entry = &mbr[offset..offset + 16];
        let part_type = entry[4];
        if part_type == 0x00 {
            continue;
        }
        let start_lba = u32::from_le_bytes(entry[8..12].try_into().unwrap());
        let size_sectors = u32::from_le_bytes(entry[12..16].try_into().unwrap());
        partitions.push(PartitionInfo {
            num: i + 1,
            type_name: mbr_type_name(part_type).to_string(),
            start_lba: start_lba as u64,
            size_sectors: size_sectors as u64,
            name: String::new(),
            type_id: Some(part_type),
            type_guid: None,
            end_lba: None,
        });
    }
    Ok(partitions)
}

fn parse_gpt_entries(data: &[u8]) -> Vec<PartitionInfo> {
    let type_names = gpt_type_names();
    let mut partitions = Vec::new();
    let mut num = 0usize;

    for i in 0..(data.len() / 128) {
        let entry = &data[i * 128..(i + 1) * 128];
        let type_guid_raw = &entry[0..16];

        // Skip empty entries
        if type_guid_raw.iter().all(|&b| b == 0) {
            continue;
        }
        num += 1;

        let type_guid = parse_guid(type_guid_raw);
        let start_lba = u64::from_le_bytes(entry[32..40].try_into().unwrap());
        let end_lba = u64::from_le_bytes(entry[40..48].try_into().unwrap());

        // Name is UTF-16LE at offset 56, 72 bytes (36 chars)
        let name_bytes = &entry[56..128];
        let u16_chars: Vec<u16> = name_bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        let name = String::from_utf16_lossy(&u16_chars)
            .trim_end_matches('\0')
            .to_string();

        let type_name = type_names
            .get(type_guid.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| type_guid.clone());

        partitions.push(PartitionInfo {
            num,
            type_name,
            start_lba,
            size_sectors: end_lba - start_lba + 1,
            name,
            type_id: None,
            type_guid: Some(type_guid),
            end_lba: Some(end_lba),
        });
    }
    partitions
}

pub fn read_gpt(tool: &mut EmmcTool) -> Result<Vec<PartitionInfo>> {
    let header = tool.read_sectors(1, 1)?;
    if &header[0..8] != b"EFI PART" {
        bail!("Invalid GPT header signature");
    }

    let entries_start_lba = u64::from_le_bytes(header[72..80].try_into().unwrap());
    let num_entries = u32::from_le_bytes(header[80..84].try_into().unwrap());
    let entry_size = u32::from_le_bytes(header[84..88].try_into().unwrap());

    let entries_bytes = num_entries as usize * entry_size as usize;
    let entries_sectors = (entries_bytes + SECTOR_SIZE - 1) / SECTOR_SIZE;
    let data = tool.read_sectors(entries_start_lba as u32, entries_sectors as u16)?;

    Ok(parse_gpt_entries(&data[..entries_bytes]))
}

pub fn get_partitions(tool: &mut EmmcTool) -> Result<(PartitionScheme, Vec<PartitionInfo>)> {
    let mbr = tool.read_sectors(0, 1)?;
    let entries = parse_mbr(&mbr)?;

    let is_gpt = entries.iter().any(|e| e.type_id == Some(0xEE));
    if is_gpt {
        Ok((PartitionScheme::Gpt, read_gpt(tool)?))
    } else {
        Ok((PartitionScheme::Mbr, entries))
    }
}

pub fn format_size(sectors: u64) -> String {
    let size_bytes = sectors * SECTOR_SIZE as u64;
    if size_bytes >= 1024 * 1024 * 1024 {
        format!("{:.1} GB", size_bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    } else if size_bytes >= 1024 * 1024 {
        format!("{:.0} MB", size_bytes as f64 / (1024.0 * 1024.0))
    } else if size_bytes >= 1024 {
        format!("{:.0} KB", size_bytes as f64 / 1024.0)
    } else {
        format!("{} B", size_bytes)
    }
}
