use std::fs;
use std::io::Write;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Result};
use indicatif::{ProgressBar, ProgressStyle};

use crate::emmc::parse_ext_csd;
use crate::protocol::*;
use crate::transport::EmmcTool;

pub fn cmd_ping(tool: &mut EmmcTool) -> Result<()> {
    if tool.ping()? {
        println!("PONG - Connection OK");
    } else {
        println!("PING failed!");
        std::process::exit(1);
    }
    Ok(())
}

pub fn cmd_info(tool: &mut EmmcTool) -> Result<()> {
    let info = tool.get_info()?;
    println!("=== eMMC Card Info ===");
    println!("CID: {}", info.cid_raw);
    println!("CSD: {}", info.csd_raw);
    println!("Manufacturer: 0x{:02X}", info.manufacturer_id);
    println!("Product: {}", info.product_name);
    println!("Revision: {}", info.product_rev);
    println!("Serial: 0x{:08X}", info.serial_number);
    println!("Date: {}", info.mfg_date);
    println!("CSD version: {}", info.csd_structure);
    if let Some(cap) = info.capacity_bytes {
        if cap >= 1024 * 1024 * 1024 {
            println!("Capacity: {:.1} GB", cap as f64 / (1024.0 * 1024.0 * 1024.0));
        } else if cap >= 1024 * 1024 {
            println!("Capacity: {:.0} MB", cap as f64 / (1024.0 * 1024.0));
        } else {
            println!("Capacity: {} bytes", cap);
        }
    } else if let Some(note) = &info.capacity_note {
        println!("Capacity: {}", note);
    }
    Ok(())
}

pub fn cmd_status(tool: &mut EmmcTool) -> Result<()> {
    let status = tool.get_status()?;
    println!("Controller status: 0x{:02X}", status);
    Ok(())
}

pub fn cmd_hexdump(tool: &mut EmmcTool, lba_str: &str, count_str: &str) -> Result<()> {
    let lba = parse_int(lba_str)? as u32;
    let count = parse_int(count_str)? as u16;
    let data = tool.read_sectors(lba, count)?;

    for i in 0..count as usize {
        println!("LBA {}:", lba as u64 + i as u64);
        let sector = &data[i * SECTOR_SIZE..(i + 1) * SECTOR_SIZE];
        for off in (0..sector.len()).step_by(16) {
            let chunk = &sector[off..std::cmp::min(off + 16, sector.len())];
            let hex_part: String = chunk
                .iter()
                .map(|b| format!("{:02x}", b))
                .collect::<Vec<_>>()
                .join(" ");
            let ascii_part: String = chunk
                .iter()
                .map(|&b| if (32..127).contains(&b) { b as char } else { '.' })
                .collect();
            println!("{:08x}  {:<48}  |{}|", off, hex_part, ascii_part);
        }
        println!();
    }
    Ok(())
}

pub fn cmd_read(tool: &mut EmmcTool, lba_str: &str, count_str: &str, outfile: &str) -> Result<()> {
    let lba = parse_int(lba_str)? as u32;
    let count = parse_int(count_str)? as u32;

    println!("Reading {} sector(s) from LBA {}...", count, lba);

    let chunk = READ_CHUNK_SECTORS as u32;
    let total_bytes = count as u64 * SECTOR_SIZE as u64;
    let pb = ProgressBar::new(total_bytes);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{bar:50}] {bytes}/{total_bytes} ({bytes_per_sec}, {eta})")?
            .progress_chars("##-"),
    );

    let mut file = fs::File::create(outfile)?;
    let mut total_read = 0u32;

    let mut start = 0u32;
    while start < count {
        let n = std::cmp::min(chunk, count - start) as u16;
        let current_lba = lba + start;
        let data = tool.read_sectors(current_lba, n)?;
        file.write_all(&data)?;
        total_read += n as u32;
        pb.set_position(total_read as u64 * SECTOR_SIZE as u64);
        start += chunk;
    }

    pb.finish_and_clear();
    println!(
        "Done. Read {} bytes to {}",
        total_read as u64 * SECTOR_SIZE as u64,
        outfile
    );
    Ok(())
}

pub fn cmd_write(tool: &mut EmmcTool, lba_str: &str, infile: &str) -> Result<()> {
    let lba = parse_int(lba_str)? as u32;
    let data = fs::read(infile)?;

    let count = (data.len() + SECTOR_SIZE - 1) / SECTOR_SIZE;
    println!("Writing {} sector(s) to LBA {}...", count, lba);

    let chunk = WRITE_CHUNK_SECTORS as usize;
    let mut total_written = 0usize;
    let mut offset = 0usize;
    let mut remaining = count;
    let mut current_lba = lba;

    let pb = ProgressBar::new((count * SECTOR_SIZE) as u64);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{bar:50}] {bytes}/{total_bytes} ({bytes_per_sec}, {eta})")?
            .progress_chars("##-"),
    );

    while remaining > 0 {
        let n = std::cmp::min(remaining, chunk);
        let end = std::cmp::min(offset + n * SECTOR_SIZE, data.len());
        let chunk_data = &data[offset..end];
        tool.write_sectors(current_lba, chunk_data)?;
        total_written += n;
        remaining -= n;
        current_lba += n as u32;
        offset += n * SECTOR_SIZE;
        pb.set_position(total_written as u64 * SECTOR_SIZE as u64);
    }

    pb.finish_and_clear();
    println!(
        "Done. Wrote {} bytes from {}",
        total_written * SECTOR_SIZE,
        infile
    );
    Ok(())
}

pub fn cmd_dump(tool: &mut EmmcTool, outfile: &str) -> Result<()> {
    let info = tool.get_info()?;
    println!(
        "Card: {}, Serial: 0x{:08X}",
        info.product_name, info.serial_number
    );

    let total_sectors: u64 = if let Some(cap) = info.capacity_bytes {
        cap / SECTOR_SIZE as u64
    } else {
        16_777_216 // 8GB default
    };

    let total_bytes = total_sectors * SECTOR_SIZE as u64;
    println!(
        "Dumping {} sectors ({:.1} GB)...",
        total_sectors,
        total_bytes as f64 / (1024.0 * 1024.0 * 1024.0)
    );

    let chunk = READ_CHUNK_SECTORS as u64;
    let mut total_read = 0u64;
    let mut errors = 0u64;
    let start_time = Instant::now();

    let pb = ProgressBar::new(total_bytes);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{bar:50}] {bytes}/{total_bytes} ({bytes_per_sec}, {eta})")?
            .progress_chars("##-"),
    );

    let mut file = fs::File::create(outfile)?;
    let mut current_lba = 0u64;
    let mut remaining = total_sectors;

    while remaining > 0 {
        let n = std::cmp::min(remaining, chunk) as u16;
        match tool.read_sectors(current_lba as u32, n) {
            Ok(data) => {
                file.write_all(&data)?;
            }
            Err(e) => {
                errors += 1;
                pb.println(format!("Error at LBA {}: {}", current_lba, e));
                let zeros = vec![0u8; n as usize * SECTOR_SIZE];
                file.write_all(&zeros)?;
            }
        }

        let bytes_read = n as u64 * SECTOR_SIZE as u64;
        total_read += n as u64;
        remaining -= n as u64;
        current_lba += n as u64;
        pb.inc(bytes_read);
    }

    pb.finish_and_clear();

    let elapsed = start_time.elapsed().as_secs_f64();
    let speed_avg = if elapsed > 0.0 {
        (total_read * SECTOR_SIZE as u64) as f64 / elapsed / 1024.0
    } else {
        0.0
    };
    println!(
        "Done. {:.2} GB in {:.0}s ({:.0} KB/s)",
        total_read as f64 * SECTOR_SIZE as f64 / (1024.0 * 1024.0 * 1024.0),
        elapsed,
        speed_avg
    );
    if errors > 0 {
        println!("WARNING: {} read errors (sectors filled with zeros)", errors);
    }
    Ok(())
}

pub fn cmd_verify(tool: &mut EmmcTool, lba_str: &str, infile: &str) -> Result<()> {
    let lba = parse_int(lba_str)? as u32;
    let file_data_raw = fs::read(infile)?;

    let count = (file_data_raw.len() + SECTOR_SIZE - 1) / SECTOR_SIZE;
    let mut file_data = file_data_raw;
    if file_data.len() % SECTOR_SIZE != 0 {
        file_data.resize(count * SECTOR_SIZE, 0);
    }

    println!("Verifying {} sectors from LBA {}...", count, lba);

    let chunk = READ_CHUNK_SECTORS as usize;
    let mut mismatches = 0usize;
    let mut total_read = 0usize;
    let mut current_lba = lba;
    let mut remaining = count;

    let pb = ProgressBar::new((count * SECTOR_SIZE) as u64);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{bar:50}] {bytes}/{total_bytes}")?
            .progress_chars("##-"),
    );

    while remaining > 0 {
        let n = std::cmp::min(remaining, chunk);
        let emmc_data = tool.read_sectors(current_lba, n as u16)?;
        let offset = total_read * SECTOR_SIZE;
        let file_chunk = &file_data[offset..offset + n * SECTOR_SIZE];

        for j in 0..n {
            let s_off = j * SECTOR_SIZE;
            if emmc_data[s_off..s_off + SECTOR_SIZE] != file_chunk[s_off..s_off + SECTOR_SIZE] {
                pb.println(format!("  MISMATCH at LBA {}", current_lba as u64 + j as u64));
                mismatches += 1;
            }
        }

        total_read += n;
        remaining -= n;
        current_lba += n as u32;
        pb.set_position(total_read as u64 * SECTOR_SIZE as u64);
    }

    pb.finish_and_clear();

    if mismatches == 0 {
        println!("OK: all sectors match");
    } else {
        println!("FAIL: {} sector(s) differ", mismatches);
        std::process::exit(1);
    }
    Ok(())
}

pub fn cmd_extcsd(tool: &mut EmmcTool, raw: bool) -> Result<()> {
    println!("Reading Extended CSD...");
    let ext_csd = tool.get_ext_csd()?;
    let info = parse_ext_csd(&ext_csd);

    println!("=== Extended CSD Info ===");

    if info.capacity_bytes >= 1024 * 1024 * 1024 {
        println!(
            "Capacity: {:.2} GB ({} sectors)",
            info.capacity_bytes as f64 / (1024.0 * 1024.0 * 1024.0),
            info.sec_count
        );
    } else {
        println!(
            "Capacity: {:.0} MB ({} sectors)",
            info.capacity_bytes as f64 / (1024.0 * 1024.0),
            info.sec_count
        );
    }

    let boot_mb = info.boot_partition_size as f64 / (1024.0 * 1024.0);
    let rpmb_kb = info.rpmb_size as f64 / 1024.0;
    println!("Boot partition size: {:.0} MB each (boot0/boot1)", boot_mb);
    println!("RPMB size: {:.0} KB", rpmb_kb);

    let part_name = match info.partition_access {
        0 => "user",
        1 => "boot0",
        2 => "boot1",
        3 => "RPMB",
        _ => "unknown",
    };
    println!("Current partition: {}", part_name);

    let life_name = |v: u8| -> &str {
        match v {
            0 => "Not defined",
            1 => "0-10%",
            2 => "10-20%",
            3 => "20-30%",
            4 => "30-40%",
            5 => "40-50%",
            6 => "50-60%",
            7 => "60-70%",
            8 => "70-80%",
            9 => "80-90%",
            10 => "90-100%",
            11 => "Exceeded",
            _ => "Unknown",
        }
    };
    let eol_name = |v: u8| -> &str {
        match v {
            0 => "Not defined",
            1 => "Normal",
            2 => "Warning",
            3 => "Urgent",
            _ => "Unknown",
        }
    };

    println!("\nDevice Health:");
    println!("  Life time (Type A/SLC): {}", life_name(info.life_time_est_a));
    println!("  Life time (Type B/MLC): {}", life_name(info.life_time_est_b));
    println!("  Pre-EOL info: {}", eol_name(info.pre_eol_info));

    println!("\nSpeed Support:");
    println!("  HS26: {}", if info.hs_support { "Yes" } else { "No" });
    println!("  HS52: {}", if info.hs52_support { "Yes" } else { "No" });
    println!("  DDR: {}", if info.ddr_support { "Yes" } else { "No" });

    println!("\nFirmware version: {}", info.fw_version);

    if raw {
        println!("\nRaw ExtCSD (512 bytes):");
        for i in (0..512).step_by(32) {
            let hex_line: String = ext_csd[i..i + 32]
                .iter()
                .map(|b| format!("{:02x}", b))
                .collect::<Vec<_>>()
                .join(" ");
            println!("  [{:3}] {}", i, hex_line);
        }
    }
    Ok(())
}

pub fn cmd_set_partition(tool: &mut EmmcTool, partition_str: &str) -> Result<()> {
    let part_id = match partition_str.to_lowercase().as_str() {
        "user" => 0,
        "boot0" => 1,
        "boot1" => 2,
        "rpmb" => 3,
        s => {
            if let Ok(n) = s.parse::<u8>() {
                n
            } else {
                bail!(
                    "Invalid partition '{}'. Use: user, boot0, boot1, rpmb, or 0-3",
                    partition_str
                );
            }
        }
    };

    println!("Switching to partition: {} (id={})...", partition_str, part_id);
    tool.set_partition(part_id)?;
    println!("Partition switched successfully.");
    println!("Note: Use 'read'/'hexdump' commands to access the new partition.");
    Ok(())
}

// === Phase 2: Simple FPGA commands ===

pub fn cmd_erase(tool: &mut EmmcTool, lba_str: &str, count_str: &str, confirm: bool) -> Result<()> {
    let lba = parse_int(lba_str)? as u32;
    let count = parse_int(count_str)? as u16;

    println!("Erase {} sectors from LBA {}", count, lba);
    if !confirm {
        println!("DRY RUN - use --confirm to actually erase");
        return Ok(());
    }

    tool.erase(lba, count)?;
    println!("Erase complete.");
    Ok(())
}

pub fn cmd_secure_erase(tool: &mut EmmcTool, lba_str: &str, count_str: &str, confirm: bool) -> Result<()> {
    let lba = parse_int(lba_str)? as u32;
    let count = parse_int(count_str)? as u16;

    println!("Secure erase {} sectors from LBA {}", count, lba);
    if !confirm {
        println!("DRY RUN - use --confirm to actually erase");
        return Ok(());
    }

    tool.secure_erase(lba, count)?;
    println!("Secure erase complete.");
    Ok(())
}

pub fn cmd_write_extcsd(tool: &mut EmmcTool, index_str: &str, value_str: &str, confirm: bool) -> Result<()> {
    let index = parse_int(index_str)? as u16;
    let value = parse_int(value_str)? as u16;

    if index > 511 {
        bail!("ExtCSD index must be 0-511, got {}", index);
    }
    if value > 255 {
        bail!("ExtCSD value must be 0-255, got {}", value);
    }

    println!("Write ExtCSD[{}] = 0x{:02X} ({})", index, value, value);
    if !confirm {
        println!("DRY RUN - use --confirm to actually write");
        return Ok(());
    }

    tool.write_ext_csd(index as u8, value as u8)?;
    println!("ExtCSD write complete.");
    Ok(())
}

pub fn cmd_card_status(tool: &mut EmmcTool) -> Result<()> {
    let status = tool.get_card_status()?;
    println!("Card Status Register: 0x{:08X}", status);
    println!();

    // Parse status bits per JEDEC standard
    let fields = [
        (31, 31, "ADDRESS_OUT_OF_RANGE"),
        (30, 30, "ADDRESS_MISALIGN"),
        (29, 29, "BLOCK_LEN_ERROR"),
        (28, 28, "ERASE_SEQ_ERROR"),
        (27, 27, "ERASE_PARAM"),
        (26, 26, "WP_VIOLATION"),
        (25, 25, "DEVICE_IS_LOCKED"),
        (24, 24, "LOCK_UNLOCK_FAILED"),
        (23, 23, "COM_CRC_ERROR"),
        (22, 22, "ILLEGAL_COMMAND"),
        (21, 21, "DEVICE_ECC_FAILED"),
        (20, 20, "CC_ERROR"),
        (19, 19, "ERROR"),
        (17, 17, "CSD_OVERWRITE"),
        (16, 16, "WP_ERASE_SKIP"),
        (15, 15, "ERASE_RESET"),
        (12, 9, "CURRENT_STATE"),
        (8, 8, "READY_FOR_DATA"),
        (7, 7, "SWITCH_ERROR"),
        (5, 5, "APP_CMD"),
    ];

    let state_names = [
        "Idle", "Ready", "Ident", "Stby", "Tran", "Data", "Rcv", "Prg",
        "Dis", "Btst", "Slp", "Rsv11", "Rsv12", "Rsv13", "Rsv14", "Rsv15",
    ];

    for &(hi, lo, name) in &fields {
        let mask = ((1u64 << (hi - lo + 1)) - 1) as u32;
        let val = (status >> lo) & mask;
        if name == "CURRENT_STATE" {
            let state_name = state_names.get(val as usize).unwrap_or(&"Unknown");
            println!("  {:25} = {} ({})", name, val, state_name);
        } else if val != 0 {
            println!("  {:25} = {}", name, val);
        }
    }

    // Show error summary
    let error_bits = status & 0xFDF90000;
    if error_bits != 0 {
        println!("\n  WARNING: Error bits set!");
    } else {
        println!("\n  No errors.");
    }
    Ok(())
}

pub fn cmd_reinit(tool: &mut EmmcTool) -> Result<()> {
    println!("Reinitializing eMMC card...");
    tool.reinit()?;
    println!("Reinit complete.");

    let info = tool.get_info()?;
    println!("Card: {}, Serial: 0x{:08X}", info.product_name, info.serial_number);
    Ok(())
}

pub fn cmd_set_clock(tool: &mut EmmcTool, speed_str: &str) -> Result<()> {
    // Try as preset number first
    if let Ok(preset) = speed_str.parse::<u8>() {
        if preset <= 6 {
            let (_, mhz) = CLK_PRESETS[preset as usize];
            if mhz == 0.0 {
                bail!("Preset {} is unused", preset);
            }
            println!("Setting eMMC clock to preset {} ({} MHz)...", preset, mhz);
            tool.set_clk_speed(preset)?;
            println!("Clock set to {} MHz.", mhz);
            return Ok(());
        }
    }

    // Try as MHz value
    let mhz: f64 = speed_str.parse().map_err(|_| {
        anyhow::anyhow!("Invalid speed '{}'. Use preset 0-6 or MHz value (2, 3.75, 6, 10, 15, 30)", speed_str)
    })?;

    let preset = mhz_to_clk_preset(mhz)
        .ok_or_else(|| anyhow::anyhow!("No matching preset for {} MHz", mhz))?;
    let (_, actual_mhz) = CLK_PRESETS[preset as usize];

    println!("Setting eMMC clock to {} MHz (preset {})...", actual_mhz, preset);
    tool.set_clk_speed(preset)?;
    println!("Clock set to {} MHz.", actual_mhz);
    Ok(())
}

pub fn cmd_set_baud(tool: &mut EmmcTool, preset_str: &str) -> Result<()> {
    let preset = parse_int(preset_str)? as u8;

    let baud = BAUD_PRESETS
        .iter()
        .find(|(p, _)| *p == preset)
        .map(|(_, b)| *b)
        .ok_or_else(|| anyhow::anyhow!("Invalid baud preset {}. Use 0=3M, 1=6M, 2=9M, 3=12M", preset))?;

    println!("Setting baud rate to {} (preset {})...", baud, preset);
    tool.set_baud(preset)?;
    println!("Baud rate set to {}.", baud);
    Ok(())
}

pub fn cmd_bus_width(tool: &mut EmmcTool, width_str: &str) -> Result<()> {
    let width: u8 = width_str.parse().map_err(|_| {
        anyhow::anyhow!("Invalid bus width '{}'. Use 1 or 4", width_str)
    })?;

    if width != 1 && width != 4 {
        bail!("Bus width must be 1 or 4, got {}", width);
    }

    println!("Setting bus width to {}-bit...", width);
    tool.set_bus_width(width)?;
    println!("Bus width set to {}-bit.", width);
    Ok(())
}

pub fn cmd_raw_cmd(tool: &mut EmmcTool, index_str: &str, arg_str: &str, flags_str: &str) -> Result<()> {
    let index = parse_int(index_str)? as u8;
    let arg = parse_int(arg_str)? as u32;
    let flags = parse_int(flags_str)? as u8;

    if index > 63 {
        bail!("CMD index must be 0-63, got {}", index);
    }

    println!("Sending CMD{} arg=0x{:08X} flags=0x{:02X}", index, arg, flags);
    println!("  flags: expect_data={} write={} long_response={}",
        flags & 1, (flags >> 1) & 1, (flags >> 2) & 1);

    let response = tool.send_raw_cmd(index, arg, flags)?;
    if response.is_empty() {
        println!("Response: (empty)");
    } else {
        let hex: String = response.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
        println!("Response ({} bytes): {}", response.len(), hex);
    }
    Ok(())
}

pub fn cmd_cache_flush(tool: &mut EmmcTool) -> Result<()> {
    println!("Flushing eMMC cache...");
    // ExtCSD[33] = FLUSH_CACHE, ExtCSD[32] = CACHE_CTRL
    tool.write_ext_csd(33, 1)?;
    println!("Cache flushed.");
    Ok(())
}

pub fn cmd_boot_config(tool: &mut EmmcTool, partition: &str, ack: bool) -> Result<()> {
    let ext_csd = tool.get_ext_csd()?;
    let current = ext_csd[179];
    println!("Current PARTITION_CONFIG: 0x{:02X}", current);
    println!("  Boot ACK:      {}", if (current >> 6) & 1 != 0 { "enabled" } else { "disabled" });
    println!("  Boot partition: {}", match (current >> 3) & 0x07 {
        0 => "not enabled",
        1 => "boot0",
        2 => "boot1",
        7 => "user area",
        n => return Err(anyhow::anyhow!("unknown: {}", n)),
    });

    let boot_bits = match partition.to_lowercase().as_str() {
        "none" | "disable" | "0" => 0u8,
        "boot0" | "1" => 1,
        "boot1" | "2" => 2,
        "user" | "7" => 7,
        _ => bail!("Invalid partition '{}'. Use: none, boot0, boot1, user", partition),
    };

    let ack_bit = if ack { 1u8 << 6 } else { 0 };
    let access = current & 0x07; // preserve current partition access
    let new_val = ack_bit | (boot_bits << 3) | access;

    println!("\nNew PARTITION_CONFIG: 0x{:02X}", new_val);
    println!("  Boot ACK:      {}", if ack { "enabled" } else { "disabled" });
    println!("  Boot partition: {}", partition);

    tool.write_ext_csd(179, new_val)?;
    println!("Boot config updated.");
    Ok(())
}

// === Phase 3: restore + recover ===

pub fn cmd_restore(tool: &mut EmmcTool, infile: &str, verify: bool) -> Result<()> {
    let file_data = fs::read(infile)?;
    let total_sectors = (file_data.len() + SECTOR_SIZE - 1) / SECTOR_SIZE;
    let total_bytes = total_sectors * SECTOR_SIZE;

    println!("Restoring {} sectors ({:.2} GB) from {}...",
        total_sectors,
        total_bytes as f64 / (1024.0 * 1024.0 * 1024.0),
        infile
    );

    // Enable cache if available
    let _ = tool.write_ext_csd(33, 1); // CACHE_CTRL enable (ignore error if unsupported)

    let chunk = WRITE_CHUNK_SECTORS as usize;
    let start_time = Instant::now();

    let pb = ProgressBar::new(total_bytes as u64);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{bar:50}] {bytes}/{total_bytes} ({bytes_per_sec}, {eta})")?
            .progress_chars("##-"),
    );

    let mut current_lba = 0u32;
    let mut offset = 0usize;
    let mut remaining = total_sectors;

    while remaining > 0 {
        let n = std::cmp::min(remaining, chunk);
        let end = std::cmp::min(offset + n * SECTOR_SIZE, file_data.len());
        let chunk_data = &file_data[offset..end];
        tool.write_sectors(current_lba, chunk_data)?;
        remaining -= n;
        current_lba += n as u32;
        offset += n * SECTOR_SIZE;
        pb.set_position(offset as u64);
    }

    pb.finish_and_clear();

    // Flush cache
    let _ = tool.write_ext_csd(33, 1);

    let elapsed = start_time.elapsed().as_secs_f64();
    let speed = total_bytes as f64 / elapsed / 1024.0;
    println!("Restore complete: {:.2} GB in {:.0}s ({:.0} KB/s)",
        total_bytes as f64 / (1024.0 * 1024.0 * 1024.0), elapsed, speed);

    if verify {
        println!("\nVerifying...");
        cmd_verify(tool, "0", infile)?;
    }
    Ok(())
}

pub fn cmd_recover(tool: &mut EmmcTool) -> Result<()> {
    println!("eMMC Recovery Procedure");
    println!("{}", "=".repeat(50));
    println!("Attempting 4 recovery strategies...\n");

    struct RecoveryStep {
        name: &'static str,
        cmd_index: u8,
        arg: u32,
        flags: u8,
        sleep_ms: u64,
    }

    let steps = [
        RecoveryStep { name: "CMD5 SLEEP_AWAKE (wake)", cmd_index: 5, arg: 0x00000000, flags: 0, sleep_ms: 100 },
        RecoveryStep { name: "CMD62 Vendor Debug Mode", cmd_index: 62, arg: 0xEFAC62EC, flags: 0, sleep_ms: 200 },
        RecoveryStep { name: "CMD0 FFU mode (arg=0xFFFFFFFA)", cmd_index: 0, arg: 0xFFFFFFFA, flags: 0, sleep_ms: 100 },
        RecoveryStep { name: "CMD0 GO_PRE_IDLE", cmd_index: 0, arg: 0xF0F0F0F0, flags: 0, sleep_ms: 200 },
    ];

    for (i, step) in steps.iter().enumerate() {
        println!("[{}/{}] {}...", i + 1, steps.len(), step.name);

        match tool.send_raw_cmd(step.cmd_index, step.arg, step.flags) {
            Ok(resp) => {
                let hex: String = resp.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
                println!("  Response: {}", if hex.is_empty() { "(empty)".to_string() } else { hex });
            }
            Err(e) => {
                println!("  Error (expected): {}", e);
            }
        }

        thread::sleep(Duration::from_millis(step.sleep_ms));

        // Try reinit
        println!("  Reinitializing...");
        match tool.reinit() {
            Ok(()) => {
                match tool.get_info() {
                    Ok(info) => {
                        println!("  SUCCESS! Card: {}, MID: 0x{:02X}", info.product_name, info.manufacturer_id);
                        println!("\nRecovery successful after step {}.", i + 1);
                        return Ok(());
                    }
                    Err(e) => println!("  Info failed: {}", e),
                }
            }
            Err(e) => println!("  Reinit failed: {}", e),
        }
    }

    println!("\nAll recovery steps failed.");
    println!("The card may be permanently damaged or require specialized tools.");
    Ok(())
}
