use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::process::Command;
use std::time::Instant;

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};

use crate::partition::{format_size, get_partitions};
use crate::protocol::SECTOR_SIZE;
use crate::transport::EmmcTool;

const MOUNT_INFO_PATH: &str = "/tmp/emmc_mount_info.json";

#[derive(Serialize, Deserialize)]
struct MountEntry {
    loop_dev: String,
    img_path: String,
}

type MountInfo = HashMap<String, MountEntry>;

fn load_mount_info() -> MountInfo {
    fs::read_to_string(MOUNT_INFO_PATH)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_mount_info(info: &MountInfo) -> Result<()> {
    let json = serde_json::to_string_pretty(info)?;
    fs::write(MOUNT_INFO_PATH, json)?;
    Ok(())
}

pub fn cmd_partitions(tool: &mut EmmcTool) -> Result<()> {
    let (scheme, partitions) = get_partitions(tool)?;
    if partitions.is_empty() {
        println!("No partitions found.");
        return Ok(());
    }

    println!("=== Partition Table ({}) ===", scheme);
    println!(
        " {:>2}  {:<20} {:<16} {:>10}   {:>8}",
        "#", "Name", "Type", "Start LBA", "Size"
    );
    for p in &partitions {
        println!(
            " {:>2}  {:<20} {:<16} {:>10}   {:>8}",
            p.num,
            &p.name,
            &p.type_name,
            p.start_lba,
            format_size(p.size_sectors)
        );
    }
    Ok(())
}

pub fn cmd_mount(tool: &mut EmmcTool, part_num: i32, mountpoint: &str) -> Result<()> {
    if !std::path::Path::new(mountpoint).is_dir() {
        bail!(
            "Mountpoint '{}' does not exist or is not a directory",
            mountpoint
        );
    }

    let (_, partitions) = get_partitions(tool)?;
    let part = partitions
        .iter()
        .find(|p| p.num == part_num as usize)
        .ok_or_else(|| {
            let nums: Vec<_> = partitions.iter().map(|p| p.num).collect();
            anyhow::anyhow!(
                "Partition {} not found. Available: {:?}",
                part_num,
                nums
            )
        })?;

    let start_lba = part.start_lba;
    let size_sectors = part.size_sectors;
    let name = if part.name.is_empty() {
        format!("part{}", part_num)
    } else {
        part.name.clone()
    };
    let img_path = format!("/tmp/emmc_part{}.img", part_num);

    println!(
        "Reading partition {} ({}, {} sectors, {})...",
        part_num,
        name,
        size_sectors,
        format_size(size_sectors)
    );

    let chunk = 64u64;
    let mut total_read = 0u64;
    let start_time = Instant::now();

    let mut file = fs::File::create(&img_path)?;
    let mut current_lba = start_lba;
    let mut remaining = size_sectors;

    while remaining > 0 {
        let n = std::cmp::min(remaining, chunk) as u16;
        let data = tool.read_sectors(current_lba as u32, n)?;
        file.write_all(&data)?;
        total_read += n as u64;
        remaining -= n as u64;
        current_lba += n as u64;

        let pct = total_read * 100 / size_sectors;
        let bar_filled = (pct / 2) as usize;
        let bar_empty = 50 - bar_filled;
        eprint!(
            "\r[{}{}] {}% ({}/{})",
            "#".repeat(bar_filled),
            "-".repeat(bar_empty),
            pct,
            total_read,
            size_sectors
        );
    }

    let elapsed = start_time.elapsed().as_secs_f64();
    let speed = if elapsed > 0.0 {
        (total_read * SECTOR_SIZE as u64) as f64 / elapsed
    } else {
        0.0
    };
    println!(
        "\nDump complete: {} in {:.0}s ({:.0} KB/s)",
        format_size(size_sectors),
        elapsed,
        speed / 1024.0
    );

    // Setup loop device
    let output = Command::new("losetup")
        .args(["-f", "--show", &img_path])
        .output()?;
    if !output.status.success() {
        bail!(
            "losetup failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let loop_dev = String::from_utf8(output.stdout)?.trim().to_string();

    // Mount
    let output = Command::new("mount")
        .args([&loop_dev, mountpoint])
        .output()?;
    if !output.status.success() {
        // Cleanup loop on failure
        let _ = Command::new("losetup").args(["-d", &loop_dev]).output();
        bail!(
            "mount failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    // Save mount info
    let mut info = load_mount_info();
    info.insert(
        mountpoint.to_string(),
        MountEntry {
            loop_dev: loop_dev.clone(),
            img_path: img_path.clone(),
        },
    );
    save_mount_info(&info)?;

    println!("Mounted at {} (loop device: {})", mountpoint, loop_dev);
    println!("Image: {}", img_path);
    Ok(())
}

pub fn cmd_umount(mountpoint: &str) -> Result<()> {
    let mut info = load_mount_info();

    if !info.contains_key(mountpoint) {
        println!("Error: no mount info for '{}'", mountpoint);
        println!("Trying umount anyway...");
        let _ = Command::new("umount").arg(mountpoint).status();
        return Ok(());
    }

    let entry = &info[mountpoint];
    let loop_dev = entry.loop_dev.clone();
    let img_path = entry.img_path.clone();

    // Unmount
    let output = Command::new("umount").arg(mountpoint).output()?;
    if !output.status.success() {
        bail!(
            "umount failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    println!("Unmounted {}", mountpoint);

    // Detach loop device
    let output = Command::new("losetup")
        .args(["-d", &loop_dev])
        .output()?;
    if !output.status.success() {
        eprintln!(
            "Warning: losetup -d failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    } else {
        println!("Detached {}", loop_dev);
    }

    // Remove image file
    if std::path::Path::new(&img_path).exists() {
        fs::remove_file(&img_path)?;
        println!("Removed {}", img_path);
    }

    // Update mount info
    info.remove(mountpoint);
    save_mount_info(&info)?;
    Ok(())
}
