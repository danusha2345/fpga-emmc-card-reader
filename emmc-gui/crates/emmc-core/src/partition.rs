use crate::card_info::format_size;
use crate::protocol::{EmmcConnection, SECTOR_SIZE};
use anyhow::{bail, Result};

/// Well-known GPT partition type GUIDs
fn gpt_type_name(guid: &str) -> &str {
    match guid {
        "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" => "EFI System",
        "0fc63daf-8483-4772-8e79-3d69d8477de4" => "Linux",
        "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7" => "FAT/NTFS",
        "e3c9e316-0b5c-4db8-817d-f92df00215ae" => "MS Reserved",
        "de94bba4-06d1-4d40-a16a-bfd50179d6ac" => "Windows Recovery",
        "024dee41-33e7-11d3-9d69-0008c781f39f" => "MBR Partition",
        _ => "",
    }
}

/// MBR partition type names
fn mbr_type_name(type_id: u8) -> &'static str {
    match type_id {
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

#[derive(Debug, Clone, PartialEq)]
pub enum PartitionTableType {
    MBR,
    GPT,
    Unknown,
    None,
}

#[derive(Debug, Clone)]
pub struct PartitionEntry {
    pub index: u32,
    pub name: String,
    pub type_name: String,
    pub fs_type: String,
    pub start_lba: u64,
    pub end_lba: u64,
    pub size_sectors: u64,
    pub bootable: bool,
}

impl PartitionEntry {
    pub fn size_human(&self) -> String {
        format_size(self.size_sectors * SECTOR_SIZE as u64)
    }
}

#[derive(Debug, Clone)]
pub struct PartitionTable {
    pub table_type: PartitionTableType,
    pub partitions: Vec<PartitionEntry>,
    pub raw_mbr: Vec<u8>,
    pub raw_gpt_header: Vec<u8>,
}

/// Read and parse partition table from eMMC
pub fn read_partition_table(conn: &mut EmmcConnection) -> Result<PartitionTable> {
    // Read MBR (LBA 0)
    let mbr = conn.read_sectors(0, 1)?;
    if mbr.len() < 512 || mbr[510] != 0x55 || mbr[511] != 0xAA {
        return Ok(PartitionTable {
            table_type: PartitionTableType::None,
            partitions: Vec::new(),
            raw_mbr: mbr,
            raw_gpt_header: Vec::new(),
        });
    }

    // Parse MBR entries
    let mbr_entries = parse_mbr(&mbr);

    // Check for GPT protective MBR
    let is_gpt = mbr_entries.iter().any(|e| e.type_name == "GPT Protective");
    if is_gpt {
        let (mut gpt_entries, gpt_header) = read_gpt(conn)?;
        detect_fs_types(conn, &mut gpt_entries);
        return Ok(PartitionTable {
            table_type: PartitionTableType::GPT,
            partitions: gpt_entries,
            raw_mbr: mbr,
            raw_gpt_header: gpt_header,
        });
    }

    let mut mbr_entries = mbr_entries;
    detect_fs_types(conn, &mut mbr_entries);

    Ok(PartitionTable {
        table_type: PartitionTableType::MBR,
        partitions: mbr_entries,
        raw_mbr: mbr,
        raw_gpt_header: Vec::new(),
    })
}

/// Detect filesystem types by reading first few sectors of each partition
fn detect_fs_types(conn: &mut EmmcConnection, partitions: &mut [PartitionEntry]) {
    for part in partitions.iter_mut() {
        // Read 4 sectors (2048 bytes) from partition start — enough for ext4 superblock at 0x438
        let data = match conn.read_sectors(part.start_lba as u32, 4) {
            Ok(d) => d,
            Err(_) => continue,
        };
        part.fs_type = detect_fs_from_data(&data);
    }
}

/// Detect filesystem type from first bytes of partition data
pub fn detect_fs_from_data(data: &[u8]) -> String {
    // ext4/ext2/ext3: magic 0xEF53 at offset 0x438
    if data.len() > 0x439 {
        let magic = u16::from_le_bytes([data[0x438], data[0x439]]);
        if magic == 0xEF53 {
            return "ext4".to_string();
        }
    }

    // squashfs: magic "hsqs" at offset 0
    if data.len() >= 4 && &data[0..4] == b"hsqs" {
        return "sqfs".to_string();
    }

    // UNR0
    if data.len() >= 4 && &data[0..4] == b"UNR0" {
        return "UNR0".to_string();
    }

    // IM*H containers (IMAH, IMBH, etc)
    if data.len() >= 4 && data[0] == b'I' && data[1] == b'M' && data[3] == b'H' {
        return String::from_utf8_lossy(&data[0..4]).to_string();
    }

    "raw".to_string()
}

fn parse_mbr(mbr: &[u8]) -> Vec<PartitionEntry> {
    let mut partitions = Vec::new();
    let mut num = 0u32;
    for i in 0..4 {
        let offset = 446 + i * 16;
        let entry = &mbr[offset..offset + 16];
        let part_type = entry[4];
        if part_type == 0x00 {
            continue;
        }
        num += 1;
        let start_lba = u32::from_le_bytes([entry[8], entry[9], entry[10], entry[11]]) as u64;
        let size_sectors = u32::from_le_bytes([entry[12], entry[13], entry[14], entry[15]]) as u64;
        partitions.push(PartitionEntry {
            index: num,
            name: String::new(),
            type_name: mbr_type_name(part_type).to_string(),
            fs_type: String::new(),
            start_lba,
            end_lba: start_lba + size_sectors - 1,
            size_sectors,
            bootable: entry[0] == 0x80,
        });
    }
    partitions
}

fn read_gpt(conn: &mut EmmcConnection) -> Result<(Vec<PartitionEntry>, Vec<u8>)> {
    let header = conn.read_sectors(1, 1)?;
    if header.len() < 92 || &header[0..8] != b"EFI PART" {
        bail!("Invalid GPT header signature");
    }

    let entries_start_lba = u64::from_le_bytes(header[72..80].try_into().unwrap());
    let num_entries = u32::from_le_bytes(header[80..84].try_into().unwrap());
    let entry_size = u32::from_le_bytes(header[84..88].try_into().unwrap());

    let entries_bytes = num_entries as usize * entry_size as usize;
    let entries_sectors = (entries_bytes + SECTOR_SIZE - 1) / SECTOR_SIZE;
    let data = conn.read_sectors(entries_start_lba as u32, entries_sectors as u16)?;

    let entries = parse_gpt_entries(&data[..entries_bytes.min(data.len())]);
    Ok((entries, header))
}

fn parse_gpt_entries(data: &[u8]) -> Vec<PartitionEntry> {
    let mut partitions = Vec::new();
    let mut num = 0u32;
    for i in 0..(data.len() / 128) {
        let entry = &data[i * 128..(i + 1) * 128];
        let type_guid_raw = &entry[0..16];
        if type_guid_raw == &[0u8; 16] {
            continue;
        }
        num += 1;
        let type_guid = parse_guid(type_guid_raw);
        let start_lba = u64::from_le_bytes(entry[32..40].try_into().unwrap());
        let end_lba = u64::from_le_bytes(entry[40..48].try_into().unwrap());

        // Name: UTF-16LE at offset 56, 72 bytes
        let name_raw = &entry[56..128];
        let name = String::from_utf16_lossy(
            &name_raw
                .chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect::<Vec<_>>(),
        )
        .trim_end_matches('\0')
        .to_string();

        let known = gpt_type_name(&type_guid);
        let type_name = if known.is_empty() {
            type_guid.clone()
        } else {
            known.to_string()
        };

        partitions.push(PartitionEntry {
            index: num,
            name,
            type_name,
            fs_type: String::new(),
            start_lba,
            end_lba,
            size_sectors: end_lba - start_lba + 1,
            bootable: false,
        });
    }
    partitions
}

fn parse_guid(raw: &[u8]) -> String {
    let p1 = u32::from_le_bytes([raw[0], raw[1], raw[2], raw[3]]);
    let p2 = u16::from_le_bytes([raw[4], raw[5]]);
    let p3 = u16::from_le_bytes([raw[6], raw[7]]);
    format!(
        "{:08x}-{:04x}-{:04x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        p1, p2, p3, raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]
    )
}
