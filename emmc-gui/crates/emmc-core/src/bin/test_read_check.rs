//! Quick check: ping + info + read sector 0 — compare with Python tool output.

use emmc_core::protocol::EmmcConnection;

fn main() {
    tracing_subscriber::fmt()
        .with_max_level(tracing::Level::DEBUG)
        .with_target(false)
        .init();

    let port = std::env::args().nth(1).unwrap_or("/dev/ttyUSB1".into());
    let baud = 3_000_000u32;

    println!("=== Rust eMMC read check ===");
    println!("Port: {} @ {}", port, baud);

    let mut conn = EmmcConnection::connect(&port, baud).expect("connect");

    // 1. Ping
    conn.ping().expect("ping failed");
    println!("[OK] Ping");

    // 2. Info (CID + CSD)
    let (cid, csd) = conn.get_info().expect("get_info failed");
    println!("[OK] CID: {}", hex(&cid));
    println!("[OK] CSD: {}", hex(&csd));

    // 3. ExtCSD
    let ext = conn.get_ext_csd().expect("get_ext_csd failed");
    let sec_count = u32::from_le_bytes([ext[212], ext[213], ext[214], ext[215]]);
    let capacity_mb = sec_count as u64 * 512 / 1024 / 1024;
    println!("[OK] ExtCSD SEC_COUNT={} ({} MB)", sec_count, capacity_mb);

    // 4. Read sectors 0, 1, 100
    for lba in [0u32, 1, 100] {
        match conn.read_sectors(lba, 1) {
            Ok(data) => {
                println!(
                    "[OK] LBA {:>5}: {} bytes, first 16 = {:02x?}  ({})",
                    lba,
                    data.len(),
                    &data[..data.len().min(16)],
                    ascii_preview(&data[..data.len().min(4)])
                );
            }
            Err(e) => {
                println!("[ERR] LBA {:>5}: {}", lba, e);
            }
        }
    }

    // 5. Multi-sector read (stress test for FIFO buffering)
    let count = 16u16;
    match conn.read_sectors(0, count) {
        Ok(data) => {
            println!(
                "[OK] Multi-read LBA 0..{}: {} bytes ({} sectors)",
                count,
                data.len(),
                data.len() / 512
            );
            // Verify GPT signature at sector 1
            if data.len() >= 1024 + 8 {
                let sig = &data[512..520];
                println!("     Sector 1 signature: {:02x?} ({})", sig, ascii_preview(sig));
            }
        }
        Err(e) => {
            println!("[ERR] Multi-read: {}", e);
        }
    }

    println!("\nDone.");
}

fn hex(data: &[u8]) -> String {
    data.iter().map(|b| format!("{:02x}", b)).collect()
}

fn ascii_preview(data: &[u8]) -> String {
    data.iter()
        .map(|&b| if b.is_ascii_graphic() { b as char } else { '.' })
        .collect()
}
