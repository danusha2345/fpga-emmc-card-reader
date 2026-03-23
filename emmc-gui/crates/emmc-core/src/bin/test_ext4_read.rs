//! Test: read json directory (inode 525) from system partition and parse entries.
//! Compares multi-sector vs single-sector reads to detect UART corruption.

use emmc_core::ext4::Ext4Fs;
use emmc_core::protocol::EmmcConnection;

fn main() {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .with_target(false)
        .init();

    let port = "/dev/ttyUSB1";
    let baud = 3_000_000u32;
    let system_lba: u64 = 720896;

    println!("=== Test ext4 read: json dir (inode 525) ===");
    println!("Connecting to {} @ {}...", port, baud);

    let mut conn = EmmcConnection::connect(port, baud).expect("connect");
    conn.ping().expect("ping");
    println!("Connected OK");

    // Test 1: read block 44735 via multi-sector (8 at once) vs single-sector (1 at a time)
    let sector = system_lba as u32 + (44735u64 * 4096 / 512) as u32;
    println!(
        "\n--- Test 1: Compare multi vs single read for block 44735 (sector {}) ---",
        sector
    );

    let multi = conn.read_sectors(sector, 8).expect("multi read");
    println!("Multi-sector read: {} bytes", multi.len());

    let mut single = Vec::with_capacity(4096);
    for i in 0..8u32 {
        let s = conn.read_sectors(sector + i, 1).expect("single read");
        single.extend_from_slice(&s);
    }
    println!("Single-sector read: {} bytes", single.len());

    let mut diffs = 0;
    for i in 0..4096 {
        if multi[i] != single[i] {
            if diffs < 10 {
                println!(
                    "  DIFF at offset {}: multi=0x{:02x} single=0x{:02x}",
                    i, multi[i], single[i]
                );
            }
            diffs += 1;
        }
    }
    println!("Total diffs: {}", diffs);

    // Test 2: parse dir entries from both reads
    println!("\n--- Test 2: Parse dir entries ---");
    let entries_multi = emmc_core::ext4::directory::parse_dir_entries(&multi, 4096);
    let entries_single = emmc_core::ext4::directory::parse_dir_entries(&single, 4096);
    println!("Multi-sector: {} entries", entries_multi.len());
    println!("Single-sector: {} entries", entries_single.len());

    let has_cali = entries_single
        .iter()
        .any(|e| e.name.contains("calibration_module"));
    println!(
        "calibration_module_paras.json found in single: {}",
        has_cali
    );
    let has_cali_multi = entries_multi
        .iter()
        .any(|e| e.name.contains("calibration_module"));
    println!(
        "calibration_module_paras.json found in multi: {}",
        has_cali_multi
    );

    // Test 3: repeat multi read 5 times and check consistency
    println!("\n--- Test 3: Repeat multi read 5 times ---");
    for attempt in 0..5 {
        let data = conn.read_sectors(sector, 8).expect("read");
        let entries = emmc_core::ext4::directory::parse_dir_entries(&data, 4096);
        let crc = simple_crc(&data);
        println!(
            "  Attempt {}: {} entries, crc32=0x{:08x}, bytes[472..480]={:02x?}",
            attempt,
            entries.len(),
            crc,
            &data[472..480]
        );
    }

    // Test 4: Full ext4 lookup
    println!("\n--- Test 4: Full ext4 lookup via Ext4Fs ---");
    let mut fs = Ext4Fs::open(&mut conn, system_lba).expect("ext4 open");
    println!("Ext4 opened: block_size={}", fs.sb.block_size);

    match fs.lookup("/etc/perception/json/calibration_module_paras.json") {
        Ok(inode) => {
            println!("FOUND! inode={} size={}", inode.ino, inode.i_size);
        }
        Err(e) => {
            println!("NOT FOUND: {}", e);

            // Debug: list json dir
            println!("\nListing /etc/perception/json/:");
            match fs.ls("/etc/perception/json") {
                Ok(entries) => {
                    for (i, e) in entries.iter().enumerate() {
                        if i < 20 || e.name.contains("calibration") {
                            println!("  [{:3}] ino={:4} name='{}'", i, e.inode, e.name);
                        }
                    }
                    println!("  ... total {} entries", entries.len());
                }
                Err(e2) => println!("ls failed: {}", e2),
            }
        }
    }
}

fn simple_crc(data: &[u8]) -> u32 {
    let mut crc = 0xFFFFFFFFu32;
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
