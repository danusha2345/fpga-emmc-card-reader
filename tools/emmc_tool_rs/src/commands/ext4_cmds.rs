use std::fs;

use anyhow::{bail, Result};

use crate::ext4::Ext4Fs;
use crate::partition::{read_gpt, PartitionInfo};
use crate::transport::EmmcTool;

/// Find partition by name or number
fn find_partition(parts: &[PartitionInfo], spec: &str) -> Option<PartitionInfo> {
    // Try by number
    if let Ok(n) = spec.parse::<usize>() {
        return parts.iter().find(|p| p.num == n).cloned();
    }
    // Try by name
    parts.iter().find(|p| p.name.eq_ignore_ascii_case(spec)).cloned()
}

/// Find the data partition (default for ext4 commands)
fn find_data_partition(parts: &[PartitionInfo]) -> Option<PartitionInfo> {
    // Priority: "data" > "userdata" > first ext4-looking partition
    let names = ["data", "userdata", "system", "system_a"];
    for name in &names {
        if let Some(p) = parts.iter().find(|p| p.name.eq_ignore_ascii_case(name)) {
            return Some(p.clone());
        }
    }
    None
}

fn open_ext4<'a>(tool: &'a mut EmmcTool, partition_spec: Option<&str>) -> Result<(Ext4Fs<'a>, String)> {
    let parts = read_gpt(tool)?;

    let part = if let Some(spec) = partition_spec {
        find_partition(&parts, spec)
            .ok_or_else(|| anyhow::anyhow!("Partition '{}' not found", spec))?
    } else {
        find_data_partition(&parts)
            .ok_or_else(|| anyhow::anyhow!("No data partition found. Use -P to specify."))?
    };

    let name = part.name.clone();
    let start_lba = part.start_lba;

    let fs = Ext4Fs::open(tool, start_lba)?;
    Ok((fs, name))
}

pub fn cmd_ext4_info(tool: &mut EmmcTool, partition: Option<&str>) -> Result<()> {
    let (fs, part_name) = open_ext4(tool, partition)?;
    let info = fs.info();

    println!("=== ext4 Filesystem Info ({}) ===", part_name);
    println!("Volume name:   {}", if info.volume_name.is_empty() { "(none)" } else { &info.volume_name });
    println!("UUID:          {}", info.uuid);
    println!("Block size:    {} bytes", info.block_size);
    println!("Block count:   {}", info.block_count);
    println!("Free blocks:   {} ({:.1}%)", info.free_blocks,
        info.free_blocks as f64 / info.block_count as f64 * 100.0);
    println!("Inode count:   {}", info.inode_count);
    println!("Free inodes:   {}", info.free_inodes);
    println!("Inode size:    {} bytes", info.inode_size);
    println!("Groups:        {}", info.num_groups);
    println!("64-bit:        {}", info.is_64bit);
    println!("Extents:       {}", info.has_extents);
    println!("Metadata csum: {}", info.metadata_csum);

    let total_bytes = info.block_count as u64 * info.block_size as u64;
    let free_bytes = info.free_blocks as u64 * info.block_size as u64;
    let used_bytes = total_bytes - free_bytes;
    println!("\nTotal:  {:.1} MB", total_bytes as f64 / (1024.0 * 1024.0));
    println!("Used:   {:.1} MB", used_bytes as f64 / (1024.0 * 1024.0));
    println!("Free:   {:.1} MB", free_bytes as f64 / (1024.0 * 1024.0));
    Ok(())
}

pub fn cmd_ext4_ls(tool: &mut EmmcTool, path: &str, partition: Option<&str>) -> Result<()> {
    let (mut fs, part_name) = open_ext4(tool, partition)?;

    println!("{}:{}", part_name, path);
    let entries = fs.ls(path)?;

    for entry in &entries {
        let inode = fs.read_inode(entry.inode)?;
        let size_str = if inode.i_size >= 1024 * 1024 {
            format!("{:.1}M", inode.i_size as f64 / (1024.0 * 1024.0))
        } else if inode.i_size >= 1024 {
            format!("{:.1}K", inode.i_size as f64 / 1024.0)
        } else {
            format!("{}", inode.i_size)
        };

        println!("  {} {:>8}  {}", inode.mode_string(), size_str, entry.name);
    }

    println!("\n{} entries", entries.len());
    Ok(())
}

pub fn cmd_ext4_cat(tool: &mut EmmcTool, path: &str, output: Option<&str>, partition: Option<&str>) -> Result<()> {
    let (mut fs, _) = open_ext4(tool, partition)?;
    let data = fs.cat(path)?;

    if let Some(outfile) = output {
        fs::write(outfile, &data)?;
        println!("Written {} bytes to {}", data.len(), outfile);
    } else {
        // Try as text
        if let Ok(text) = std::str::from_utf8(&data) {
            if text.chars().take(200).all(|c| c.is_ascii_graphic() || c.is_ascii_whitespace()) {
                print!("{}", text);
                return Ok(());
            }
        }
        // Hex dump
        for off in (0..data.len()).step_by(16) {
            let chunk = &data[off..std::cmp::min(off + 16, data.len())];
            let hex: String = chunk.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
            let ascii: String = chunk.iter().map(|&b| if (32..127).contains(&b) { b as char } else { '.' }).collect();
            println!("{:08x}  {:<48}  |{}|", off, hex, ascii);
        }
    }
    Ok(())
}

pub fn cmd_ext4_write(
    tool: &mut EmmcTool,
    path: &str,
    data_hex: Option<&str>,
    infile: Option<&str>,
    confirm: bool,
    partition: Option<&str>,
) -> Result<()> {
    let data = if let Some(hex) = data_hex {
        hex_decode(hex)?
    } else if let Some(file) = infile {
        fs::read(file)?
    } else {
        bail!("Specify --data-hex or --infile");
    };

    println!("Writing {} bytes to ext4:{}", data.len(), path);
    if !confirm {
        println!("DRY RUN - use --confirm to actually write");
        return Ok(());
    }

    let (mut fs, _) = open_ext4(tool, partition)?;
    let inode = fs.lookup(path)?;
    fs.overwrite_file_data(&inode, &data)?;
    println!("Written {} bytes to {}", data.len(), path);
    Ok(())
}

pub fn cmd_ext4_create(
    tool: &mut EmmcTool,
    parent: &str,
    name: &str,
    data_hex: Option<&str>,
    confirm: bool,
    partition: Option<&str>,
) -> Result<()> {
    let data = if let Some(hex) = data_hex {
        hex_decode(hex)?
    } else {
        Vec::new()
    };

    println!("Creating ext4:{}/{} ({} bytes)", parent, name, data.len());
    if !confirm {
        println!("DRY RUN - use --confirm to actually create");
        return Ok(());
    }

    let (mut fs, _) = open_ext4(tool, partition)?;
    let ino = fs.create_file(parent, name, &data)?;
    println!("Created inode {} at {}/{}", ino, parent, name);
    Ok(())
}

fn hex_decode(hex: &str) -> Result<Vec<u8>> {
    let hex = hex.replace(' ', "");
    if hex.len() % 2 != 0 {
        bail!("Hex string must have even length");
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).map_err(|e| anyhow::anyhow!("Invalid hex: {}", e)))
        .collect()
}
