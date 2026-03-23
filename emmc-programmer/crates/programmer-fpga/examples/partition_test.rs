//! Tests partition table parsing and filesystem detection on real eMMC
//! Requires FPGA + eMMC with GPT

use programmer_fpga::FpgaUartProgrammer;
use programmer_hal::traits::*;

struct NP;
impl ProgressReporter for NP {
    fn report(&self, _c: u64, _t: u64, _d: &str) {}
    fn is_cancelled(&self) -> bool { false }
}

fn main() {
    let port = std::env::args().nth(1).unwrap_or_else(|| "/dev/ttyUSB1".to_string());

    println!("=== Partition & Filesystem Test ===\n");

    let mut prog = FpgaUartProgrammer::connect(&port, 3_000_000)
        .expect("Connect failed");
    prog.connection().ping().expect("Ping failed");

    let info = prog.identify().unwrap().unwrap();
    println!("Chip: {} {} ({:.1} GB)\n",
        info.manufacturer, info.product_name,
        info.capacity_bytes as f64 / (1024.0 * 1024.0 * 1024.0));

    // Read first 34 sectors (MBR + GPT header + GPT entries)
    let data = prog.read(0, 34 * 512, &NP).expect("Read failed");

    // === MBR Check ===
    let has_mbr = data[510] == 0x55 && data[511] == 0xAA;
    println!("[MBR] Signature: {} (0x{:02X}{:02X})",
        if has_mbr { "VALID" } else { "MISSING" },
        data[510], data[511]);
    if has_mbr {
        // Check protective MBR type
        let mbr_type = data[446 + 4];
        println!("[MBR] Type: 0x{:02X} ({})", mbr_type,
            if mbr_type == 0xEE { "GPT Protective" } else { "other" });
    }

    // === GPT Header ===
    let has_gpt = &data[512..520] == b"EFI PART";
    println!("\n[GPT] Signature: {} ({})",
        if has_gpt { "VALID" } else { "MISSING" },
        String::from_utf8_lossy(&data[512..520]));

    if !has_gpt {
        println!("\nNo GPT found, skipping partition tests.");
        return;
    }

    let revision = u32::from_le_bytes(data[520..524].try_into().unwrap());
    let header_size = u32::from_le_bytes(data[524..528].try_into().unwrap());
    let num_entries = u32::from_le_bytes(data[512+80..512+84].try_into().unwrap());
    let entry_size = u32::from_le_bytes(data[512+84..512+88].try_into().unwrap());
    let first_usable = u64::from_le_bytes(data[512+40..512+48].try_into().unwrap());
    let last_usable = u64::from_le_bytes(data[512+48..512+56].try_into().unwrap());

    println!("[GPT] Revision: {}.{}", revision >> 16, revision & 0xFFFF);
    println!("[GPT] Header size: {} bytes", header_size);
    println!("[GPT] Entries: {} × {} bytes", num_entries, entry_size);
    println!("[GPT] First usable LBA: {}", first_usable);
    println!("[GPT] Last usable LBA: {} ({:.1} GB)",
        last_usable, last_usable as f64 * 512.0 / (1024.0 * 1024.0 * 1024.0));

    // === Parse GPT Entries ===
    println!("\n{:>3}  {:20} {:>12} {:>12} {:>10}  FS",
        "#", "Name", "Start LBA", "End LBA", "Size");
    println!("{}", "-".repeat(80));

    let mut partitions = Vec::new();
    for i in 0..num_entries as usize {
        let offset = 1024 + i * entry_size as usize;
        if offset + 128 > data.len() {
            break;
        }
        let entry = &data[offset..offset + 128];
        let type_guid = &entry[0..16];
        if type_guid == [0u8; 16] {
            continue;
        }
        let start_lba = u64::from_le_bytes(entry[32..40].try_into().unwrap());
        let end_lba = u64::from_le_bytes(entry[40..48].try_into().unwrap());
        let name_raw = &entry[56..128];
        let name = String::from_utf16_lossy(
            &name_raw.chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect::<Vec<_>>()
        ).trim_end_matches('\0').to_string();

        let size_sectors = end_lba - start_lba + 1;
        let size_bytes = size_sectors * 512;
        let size_str = if size_bytes >= 1024 * 1024 * 1024 {
            format!("{:.1} GB", size_bytes as f64 / (1024.0 * 1024.0 * 1024.0))
        } else {
            format!("{} MB", size_bytes / (1024 * 1024))
        };

        partitions.push((i + 1, name, start_lba, end_lba, size_str));
    }

    // === Read first sector of each partition to detect filesystem ===
    for (idx, name, start_lba, end_lba, size_str) in &partitions {
        let fs_type = detect_filesystem(&mut prog, *start_lba);
        println!("{:3}  {:20} {:>12} {:>12} {:>10}  {}",
            idx, name, start_lba, end_lba, size_str, fs_type);
    }

    // === Read ext4 superblock of a known ext4 partition ===
    println!("\n=== ext4 Superblock Analysis ===");
    for (_, name, start_lba, _, _) in &partitions {
        if name == "system" || name == "userdata" || name == "blackbox" {
            println!("\nPartition: {} (LBA {})", name, start_lba);
            analyze_ext4(&mut prog, *start_lba);
        }
    }

    println!("\n=== {} partitions found, all parsed OK ===", partitions.len());
}

fn detect_filesystem(prog: &mut FpgaUartProgrammer, start_lba: u64) -> &'static str {
    // Read first 4 sectors (2048 bytes — ext4 superblock at offset 1024)
    let data = match prog.read(start_lba * 512, 2048, &NP) {
        Ok(d) => d,
        Err(_) => return "read error",
    };

    // ext4/ext2/ext3: magic at offset 0x438 (1080) = 0xEF53
    if data.len() >= 1082 && data[1080] == 0x53 && data[1081] == 0xEF {
        return "ext4";
    }

    // squashfs: magic at offset 0 = "hsqs" (0x73717368)
    if data.len() >= 4 && &data[0..4] == b"hsqs" {
        return "squashfs";
    }

    // FAT: check for FAT signatures
    if data.len() >= 512 {
        if &data[0x36..0x3B] == b"FAT16" || &data[0x36..0x3E] == b"FAT16   " {
            return "FAT16";
        }
        if &data[0x52..0x57] == b"FAT32" || &data[0x52..0x5A] == b"FAT32   " {
            return "FAT32";
        }
    }

    // UNR0 container
    if data.len() >= 4 && &data[0..4] == b"UNR0" {
        return "UNR0";
    }

    // IM*H container (encrypted)
    if data.len() >= 4 && data[0] == b'I' && data[1] == b'M' && data[3] == b'H' {
        return "IM*H";
    }

    // Android sparse image
    if data.len() >= 4 && data[0] == 0x3A && data[1] == 0xFF && data[2] == 0x26 && data[3] == 0xED {
        return "sparse";
    }

    // Check if all zeros
    if data.iter().all(|&b| b == 0x00) {
        return "empty";
    }
    if data.iter().all(|&b| b == 0xFF) {
        return "erased";
    }

    "unknown"
}

fn analyze_ext4(prog: &mut FpgaUartProgrammer, start_lba: u64) {
    // ext4 superblock is at byte offset 1024 from partition start
    // That's 2 sectors into the partition
    let data = match prog.read(start_lba * 512, 4 * 512, &NP) {
        Ok(d) => d,
        Err(e) => {
            println!("  Read error: {}", e);
            return;
        }
    };

    if data.len() < 2048 {
        println!("  Too short");
        return;
    }

    // Superblock at offset 1024
    let sb = &data[1024..];
    let magic = u16::from_le_bytes([sb[0x38], sb[0x39]]);
    if magic != 0xEF53 {
        println!("  Not ext4 (magic=0x{:04X})", magic);
        return;
    }

    let inodes_count = u32::from_le_bytes(sb[0..4].try_into().unwrap());
    let blocks_count = u32::from_le_bytes(sb[4..8].try_into().unwrap());
    let free_blocks = u32::from_le_bytes(sb[12..16].try_into().unwrap());
    let free_inodes = u32::from_le_bytes(sb[16..20].try_into().unwrap());
    let block_size = 1024u32 << u32::from_le_bytes(sb[24..28].try_into().unwrap());
    let blocks_per_group = u32::from_le_bytes(sb[32..36].try_into().unwrap());
    let state = u16::from_le_bytes([sb[0x3A], sb[0x3B]]);
    let rev_level = u32::from_le_bytes(sb[0x4C..0x50].try_into().unwrap());

    // Volume name at offset 0x78, 16 bytes
    let vol_name = std::str::from_utf8(&sb[0x78..0x88])
        .unwrap_or("?")
        .trim_end_matches('\0');

    let total_bytes = blocks_count as u64 * block_size as u64;
    let free_bytes = free_blocks as u64 * block_size as u64;

    println!("  Magic: 0x{:04X} ✓", magic);
    println!("  Volume: \"{}\"", vol_name);
    println!("  Block size: {} bytes", block_size);
    println!("  Blocks: {} total, {} free", blocks_count, free_blocks);
    println!("  Inodes: {} total, {} free", inodes_count, free_inodes);
    println!("  Blocks/group: {}", blocks_per_group);
    println!("  Size: {:.1} MB (free: {:.1} MB)",
        total_bytes as f64 / (1024.0 * 1024.0),
        free_bytes as f64 / (1024.0 * 1024.0));
    println!("  State: {} ({})",
        state, if state == 1 { "clean" } else { "dirty" });
    println!("  Revision: {}", rev_level);
}
