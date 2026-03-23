//! Rename a GPT partition on real eMMC
//! Usage: rename_partition [port] [old_name] [new_name]

use programmer_fpga::FpgaUartProgrammer;
use programmer_hal::traits::*;

struct NP;
impl ProgressReporter for NP {
    fn report(&self, _c: u64, _t: u64, _d: &str) {}
    fn is_cancelled(&self) -> bool { false }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let port = args.get(1).map(|s| s.as_str()).unwrap_or("/dev/ttyUSB1");
    let old_name = args.get(2).map(|s| s.as_str()).unwrap_or("dos");
    let new_name = args.get(3).map(|s| s.as_str()).unwrap_or("tos");

    println!("=== GPT Partition Rename ===");
    println!("Port: {}", port);
    println!("Rename: \"{}\" → \"{}\"\n", old_name, new_name);

    if new_name.len() > 36 {
        eprintln!("ERROR: new name too long (max 36 chars for GPT)");
        std::process::exit(1);
    }

    let mut prog = FpgaUartProgrammer::connect(port, 3_000_000)
        .expect("Connect failed");
    prog.connection().ping().expect("Ping failed");

    let info = prog.identify().unwrap().unwrap();
    let total_sectors = info.capacity_bytes / 512;
    println!("Chip: {} {} ({:.1} GB, {} sectors)\n",
        info.manufacturer, info.product_name,
        info.capacity_bytes as f64 / (1024.0 * 1024.0 * 1024.0),
        total_sectors);

    // === Read primary GPT (LBA 0-33) ===
    let mut gpt_data = prog.read(0, 34 * 512, &NP).expect("Read primary GPT failed");
    assert_eq!(gpt_data.len(), 34 * 512);

    // Verify MBR + GPT
    assert_eq!(gpt_data[510], 0x55, "No MBR");
    assert_eq!(gpt_data[511], 0xAA, "No MBR");
    assert_eq!(&gpt_data[512..520], b"EFI PART", "No GPT");

    let num_entries = u32::from_le_bytes(gpt_data[512+80..512+84].try_into().unwrap()) as usize;
    let entry_size = u32::from_le_bytes(gpt_data[512+84..512+88].try_into().unwrap()) as usize;
    let backup_lba = u64::from_le_bytes(gpt_data[512+32..512+40].try_into().unwrap());

    println!("GPT: {} entries × {} bytes, backup at LBA {}", num_entries, entry_size, backup_lba);

    // === Find the partition ===
    let mut found_idx = None;
    for i in 0..num_entries {
        let offset = 1024 + i * entry_size;
        if offset + 128 > gpt_data.len() { break; }
        let entry = &gpt_data[offset..offset + 128];
        if entry[0..16] == [0u8; 16] { continue; }

        let name = gpt_name(&entry[56..128]);
        if name == old_name {
            found_idx = Some(i);
            let start = u64::from_le_bytes(entry[32..40].try_into().unwrap());
            let end = u64::from_le_bytes(entry[40..48].try_into().unwrap());
            println!("\nFound \"{}\" at entry {} (LBA {} - {})", old_name, i, start, end);
            break;
        }
    }

    let entry_idx = match found_idx {
        Some(i) => i,
        None => {
            eprintln!("ERROR: partition \"{}\" not found", old_name);
            // List all partition names for reference
            println!("\nAvailable partitions:");
            for i in 0..num_entries {
                let offset = 1024 + i * entry_size;
                if offset + 128 > gpt_data.len() { break; }
                let entry = &gpt_data[offset..offset + 128];
                if entry[0..16] == [0u8; 16] { continue; }
                println!("  {}: {}", i + 1, gpt_name(&entry[56..128]));
            }
            std::process::exit(1);
        }
    };

    // === Modify name ===
    let name_offset = 1024 + entry_idx * entry_size + 56;
    // Clear name field (72 bytes = 36 UTF-16LE chars)
    for b in &mut gpt_data[name_offset..name_offset + 72] {
        *b = 0;
    }
    // Write new name as UTF-16LE
    for (i, ch) in new_name.encode_utf16().enumerate() {
        let off = name_offset + i * 2;
        gpt_data[off] = (ch & 0xFF) as u8;
        gpt_data[off + 1] = (ch >> 8) as u8;
    }

    // Verify the change
    let new_parsed = gpt_name(&gpt_data[name_offset..name_offset + 72]);
    println!("Changed name: \"{}\" → \"{}\"", old_name, new_parsed);

    // === Recalculate CRC32 of partition entries ===
    let entries_start = 1024;
    let entries_len = num_entries * entry_size;
    let entries_crc = crc32(&gpt_data[entries_start..entries_start + entries_len]);
    println!("Entries CRC32: 0x{:08X}", entries_crc);

    // Update entries CRC in GPT header (offset 88 from start of header = 512+88)
    gpt_data[512+88..512+92].copy_from_slice(&entries_crc.to_le_bytes());

    // === Recalculate GPT header CRC32 ===
    let header_size = u32::from_le_bytes(gpt_data[512+12..512+16].try_into().unwrap()) as usize;
    // Zero out header CRC field before calculating
    gpt_data[512+16..512+20].copy_from_slice(&[0, 0, 0, 0]);
    let header_crc = crc32(&gpt_data[512..512 + header_size]);
    gpt_data[512+16..512+20].copy_from_slice(&header_crc.to_le_bytes());
    println!("Header CRC32: 0x{:08X}", header_crc);

    // === Write primary GPT (LBA 1-33, skip MBR at LBA 0) ===
    println!("\nWriting primary GPT (LBA 1-33)...");
    prog.write(512, &gpt_data[512..], &NP).expect("Write primary GPT failed");
    println!("Primary GPT written.");

    // === Update backup GPT ===
    // Backup entries are at LBA (backup_lba - 32) to (backup_lba - 1)
    // Backup header is at backup_lba
    let backup_entries_lba = backup_lba - 32;
    println!("\nReading backup GPT (LBA {}-{})...", backup_entries_lba, backup_lba);

    let mut backup = prog.read(backup_entries_lba * 512, 33 * 512, &NP)
        .expect("Read backup GPT failed");
    assert_eq!(backup.len(), 33 * 512);

    // Verify backup header
    let bh_offset = 32 * 512; // backup header is last sector
    assert_eq!(&backup[bh_offset..bh_offset + 8], b"EFI PART", "Backup GPT signature mismatch");

    // Find and rename in backup entries (same entry_idx)
    let b_name_offset = entry_idx * entry_size + 56;
    for b in &mut backup[b_name_offset..b_name_offset + 72] {
        *b = 0;
    }
    for (i, ch) in new_name.encode_utf16().enumerate() {
        let off = b_name_offset + i * 2;
        backup[off] = (ch & 0xFF) as u8;
        backup[off + 1] = (ch >> 8) as u8;
    }

    // Recalculate backup entries CRC
    let b_entries_crc = crc32(&backup[0..entries_len]);
    backup[bh_offset + 88..bh_offset + 92].copy_from_slice(&b_entries_crc.to_le_bytes());

    // Recalculate backup header CRC
    let b_header_size = u32::from_le_bytes(
        backup[bh_offset + 12..bh_offset + 16].try_into().unwrap()
    ) as usize;
    backup[bh_offset + 16..bh_offset + 20].copy_from_slice(&[0, 0, 0, 0]);
    let b_header_crc = crc32(&backup[bh_offset..bh_offset + b_header_size]);
    backup[bh_offset + 16..bh_offset + 20].copy_from_slice(&b_header_crc.to_le_bytes());

    println!("Writing backup GPT (LBA {}-{})...", backup_entries_lba, backup_lba);
    prog.write(backup_entries_lba * 512, &backup, &NP)
        .expect("Write backup GPT failed");
    println!("Backup GPT written.");

    // === Verify ===
    println!("\nVerifying...");
    let verify_data = prog.read(0, 34 * 512, &NP).expect("Verify read failed");
    let v_name_offset = 1024 + entry_idx * entry_size + 56;
    let verified_name = gpt_name(&verify_data[v_name_offset..v_name_offset + 72]);
    if verified_name == new_name {
        println!("VERIFIED: partition renamed to \"{}\"", verified_name);
    } else {
        eprintln!("VERIFY FAILED: got \"{}\" expected \"{}\"", verified_name, new_name);
        std::process::exit(1);
    }

    // Print updated partition table
    println!("\n=== Updated Partition Table ===");
    for i in 0..num_entries {
        let offset = 1024 + i * entry_size;
        if offset + 128 > verify_data.len() { break; }
        let entry = &verify_data[offset..offset + 128];
        if entry[0..16] == [0u8; 16] { continue; }
        let name = gpt_name(&entry[56..128]);
        let start = u64::from_le_bytes(entry[32..40].try_into().unwrap());
        let end = u64::from_le_bytes(entry[40..48].try_into().unwrap());
        let size_mb = (end - start + 1) * 512 / (1024 * 1024);
        println!("  {:2}  {:20} LBA {:>10} - {:>10}  {:>6} MB", i + 1, name, start, end, size_mb);
    }

    println!("\n=== Done ===");
}

fn gpt_name(raw: &[u8]) -> String {
    String::from_utf16_lossy(
        &raw.chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect::<Vec<_>>()
    ).trim_end_matches('\0').to_string()
}

fn crc32(data: &[u8]) -> u32 {
    // Standard CRC-32 (ISO 3309 / ITU-T V.42)
    let mut crc: u32 = 0xFFFFFFFF;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    !crc
}
