use std::fs;
use std::io::Write;

use anyhow::Result;
use indicatif::{ProgressBar, ProgressStyle};

use crate::protocol::parse_int;
use crate::rpmb;
use crate::transport::EmmcTool;

pub fn cmd_rpmb_counter(tool: &mut EmmcTool) -> Result<()> {
    println!("Reading RPMB write counter...");
    let (counter, mac_ok) = tool.rpmb_read_counter()?;
    println!("Write counter: {}", counter);
    println!("MAC verify: {}", if mac_ok { "OK (test key)" } else { "FAILED (key mismatch)" });
    Ok(())
}

pub fn cmd_rpmb_read(tool: &mut EmmcTool, addr_str: &str, hex: bool) -> Result<()> {
    let address = parse_int(addr_str)? as u16;
    println!("RPMB authenticated read at address {}...", address);

    let resp = tool.rpmb_read_data(address)?;

    println!("Address: {}", resp.address);
    println!("Result: {} (0x{:04X})", rpmb::rpmb_result_name(resp.result), resp.result);

    if hex {
        println!("\nData (256 bytes):");
        for off in (0..256).step_by(16) {
            let chunk = &resp.data[off..off + 16];
            let hex_str: String = chunk.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
            let ascii: String = chunk.iter().map(|&b| if (32..127).contains(&b) { b as char } else { '.' }).collect();
            println!("{:04x}  {:<48}  |{}|", off, hex_str, ascii);
        }
    } else {
        let non_zero = resp.data.iter().filter(|&&b| b != 0).count();
        println!("Data: {} non-zero bytes of 256", non_zero);
    }
    Ok(())
}

pub fn cmd_rpmb_dump(tool: &mut EmmcTool, outfile: &str) -> Result<()> {
    // Get RPMB size from ExtCSD
    let ext_csd = tool.get_ext_csd()?;
    let rpmb_size_mult = ext_csd[168] as u64;
    let rpmb_bytes = rpmb_size_mult * 128 * 1024;
    let total_blocks = (rpmb_bytes / 256) as u16; // RPMB uses 256-byte half-sectors

    println!("RPMB size: {} KB ({} half-sector blocks)", rpmb_bytes / 1024, total_blocks);
    println!("Dumping to {}...", outfile);

    let mut file = fs::File::create(outfile)?;

    let pb = ProgressBar::new(total_blocks as u64);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{bar:50}] {pos}/{len} blocks ({eta})")?
            .progress_chars("##-"),
    );

    let mut errors = 0u32;
    for addr in 0..total_blocks {
        match tool.rpmb_read_data(addr) {
            Ok(resp) => {
                file.write_all(&resp.data)?;
            }
            Err(e) => {
                errors += 1;
                pb.println(format!("Error at block {}: {}", addr, e));
                file.write_all(&[0u8; 256])?;
            }
        }
        pb.inc(1);
    }

    pb.finish_and_clear();
    println!("Done. {} blocks dumped, {} errors.", total_blocks, errors);
    Ok(())
}
