//! Comprehensive HW integration test for FpgaUartProgrammer
//! Requires FPGA + eMMC connected on /dev/ttyUSB1

use programmer_fpga::FpgaUartProgrammer;
use programmer_hal::traits::*;

struct NP;
impl ProgressReporter for NP {
    fn report(&self, _c: u64, _t: u64, _d: &str) {}
    fn is_cancelled(&self) -> bool {
        false
    }
}

struct CancelImmediately;
impl ProgressReporter for CancelImmediately {
    fn report(&self, _c: u64, _t: u64, _d: &str) {}
    fn is_cancelled(&self) -> bool {
        true
    }
}

fn main() {
    let port = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "/dev/ttyUSB1".to_string());
    let mut pass = 0u32;
    let mut fail = 0u32;
    let mut tests = Vec::new();

    println!("=== Full HW Integration Test ===\n");

    let mut prog = match FpgaUartProgrammer::connect(&port, 3_000_000) {
        Ok(p) => p,
        Err(e) => {
            println!("FATAL: Connect failed: {}", e);
            std::process::exit(1);
        }
    };
    println!("Connected to {}\n", prog.port_name());

    // === 1. Basic connectivity ===
    println!("[1] Basic Connectivity");
    run(&mut tests, &mut pass, &mut fail, "Ping", || {
        prog.connection().ping()?;
        Ok("OK".into())
    });
    run(&mut tests, &mut pass, &mut fail, "Backend name", || {
        let name = prog.backend_name();
        assert_eq!(name, "FPGA UART");
        Ok(format!("\"{}\"", name))
    });
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Supported chip types",
        || {
            let types = prog.supported_chip_types();
            assert_eq!(types, &[ChipType::Emmc]);
            Ok(format!("{:?}", types))
        },
    );

    // === 2. Chip identification ===
    println!("\n[2] Chip Identification");
    run(&mut tests, &mut pass, &mut fail, "Identify", || {
        let info = prog.identify()?.ok_or("No chip")?;
        assert!(!info.manufacturer.is_empty());
        assert!(!info.product_name.is_empty());
        assert!(info.capacity_bytes > 0);
        Ok(format!(
            "{} {} {:.1}GB",
            info.manufacturer,
            info.product_name,
            info.capacity_bytes as f64 / (1024.0 * 1024.0 * 1024.0)
        ))
    });

    // === 3. Extensions ===
    println!("\n[3] ProgrammerExt");
    run(&mut tests, &mut pass, &mut fail, "Has extensions", || {
        assert!(prog.extensions().is_some());
        Ok("yes".into())
    });
    run(&mut tests, &mut pass, &mut fail, "Read ExtCSD", || {
        let data = prog.extensions().unwrap().read_ext_csd()?;
        assert_eq!(data.len(), 512);
        let sc = u32::from_le_bytes([data[212], data[213], data[214], data[215]]);
        assert!(sc > 0);
        Ok(format!("512B, SEC_COUNT={}", sc))
    });
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Set partition user(0)",
        || {
            prog.extensions().unwrap().set_partition(0)?;
            Ok("".into())
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Set partition boot0(1)",
        || {
            prog.extensions().unwrap().set_partition(1)?;
            Ok("".into())
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Back to user(0)",
        || {
            prog.extensions().unwrap().set_partition(0)?;
            Ok("".into())
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Raw CMD13 (SEND_STATUS)",
        || {
            let resp = prog
                .extensions()
                .unwrap()
                .send_raw_command(13, 0x0001_0000, 0x01)?;
            assert!(!resp.is_empty());
            Ok(format!(
                "{}B: {:02X?}",
                resp.len(),
                &resp[..resp.len().min(6)]
            ))
        },
    );

    // === 4. Read operations ===
    println!("\n[4] Read Operations");
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Read 1 sector (LBA 0)",
        || {
            let data = prog.read(0, 512, &NP)?;
            assert_eq!(data.len(), 512);
            let sig = if data[510] == 0x55 && data[511] == 0xAA {
                "MBR"
            } else {
                "no MBR"
            };
            Ok(format!("512B ({})", sig))
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Read 2 sectors (GPT check)",
        || {
            let data = prog.read(0, 1024, &NP)?;
            assert_eq!(data.len(), 1024);
            let gpt = &data[512..520] == b"EFI PART";
            Ok(format!("1024B (GPT={})", gpt))
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Read 64 sectors (CMD18)",
        || {
            let data = prog.read(0, 64 * 512, &NP)?;
            assert_eq!(data.len(), 64 * 512);
            Ok(format!("{}B", data.len()))
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Read 128 sectors (2 chunks)",
        || {
            let data = prog.read(0, 128 * 512, &NP)?;
            assert_eq!(data.len(), 128 * 512);
            Ok(format!("{}B", data.len()))
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Read consistency",
        || {
            let a = prog.read(0, 512, &NP)?;
            let b = prog.read(0, 512, &NP)?;
            assert_eq!(a, b, "two reads of same sector differ");
            Ok("2 reads match".into())
        },
    );

    // === 5. Verify / BlankCheck ===
    println!("\n[5] Verify / BlankCheck");
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Verify LBA 0 (readback)",
        || {
            let original = prog.read(0, 512, &NP)?;
            let result = prog.verify(0, &original, &NP)?;
            assert_eq!(result.total_bytes, 512);
            assert!(result.mismatches.is_empty());
            Ok(format!("{}B, 0 mismatches", result.total_bytes))
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Verify LBA 0-3 (4 sectors)",
        || {
            let original = prog.read(0, 4 * 512, &NP)?;
            let result = prog.verify(0, &original, &NP)?;
            assert!(result.mismatches.is_empty());
            Ok(format!("{}B, 0 mismatches", result.total_bytes))
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "BlankCheck LBA 0 (not blank)",
        || {
            let result = prog.blank_check(0, 512, &NP)?;
            assert!(!result.is_blank);
            assert!(result.first_non_blank.is_some());
            Ok(format!("first@0x{:X}", result.first_non_blank.unwrap()))
        },
    );

    // === 6. Speed control ===
    println!("\n[6] Speed Control");
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Set CLK preset 0 (2MHz)",
        || {
            prog.extensions().unwrap().set_speed(0)?;
            Ok("".into())
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Set CLK preset 2 (6MHz)",
        || {
            prog.extensions().unwrap().set_speed(2)?;
            Ok("".into())
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Read after speed change",
        || {
            let data = prog.read(0, 512, &NP)?;
            assert_eq!(data.len(), 512);
            Ok("512B".into())
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Set CLK preset 3 (10MHz)",
        || {
            prog.extensions().unwrap().set_speed(3)?;
            Ok("".into())
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Read at 10MHz",
        || {
            let data = prog.read(0, 64 * 512, &NP)?;
            assert_eq!(data.len(), 64 * 512);
            Ok(format!("{}B", data.len()))
        },
    );
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Reset CLK to preset 0",
        || {
            prog.extensions().unwrap().set_speed(0)?;
            Ok("".into())
        },
    );

    // === 7. Reinit ===
    println!("\n[7] Reinit");
    run(&mut tests, &mut pass, &mut fail, "Reinit", || {
        prog.extensions().unwrap().reinit()?;
        Ok("".into())
    });
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Read after reinit",
        || {
            let data = prog.read(0, 512, &NP)?;
            assert_eq!(data.len(), 512);
            Ok("512B".into())
        },
    );

    // === 8. Cancellation ===
    println!("\n[8] Cancellation");
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Cancel mid-read",
        || match prog.read(0, 1000 * 512, &CancelImmediately) {
            Err(e) => Ok(format!("cancelled: {}", e)),
            Ok(_) => Err("should have cancelled".into()),
        },
    );

    // === 9. Partition table check ===
    println!("\n[9] Partition Table");
    run(
        &mut tests,
        &mut pass,
        &mut fail,
        "Read 34 sectors for PT",
        || {
            let data = prog.read(0, 34 * 512, &NP)?;
            assert_eq!(data.len(), 34 * 512);
            let has_mbr = data[510] == 0x55 && data[511] == 0xAA;
            let has_gpt = data.len() >= 520 && &data[512..520] == b"EFI PART";
            if has_gpt {
                let n = u32::from_le_bytes(data[512 + 80..512 + 84].try_into().unwrap());
                let entry = &data[1024..1024 + 128];
                let name_raw = &entry[56..128];
                let name = String::from_utf16_lossy(
                    &name_raw
                        .chunks_exact(2)
                        .map(|c| u16::from_le_bytes([c[0], c[1]]))
                        .collect::<Vec<_>>(),
                );
                Ok(format!("GPT, {} entries, first=\"{}\"", n, name.trim_end_matches('\0')))
            } else if has_mbr {
                Ok("MBR (no GPT)".into())
            } else {
                Ok(format!(
                    "no PT (LBA0: {:02X}{:02X}..{:02X}{:02X})",
                    data[0], data[1], data[510], data[511]
                ))
            }
        },
    );

    // === Summary ===
    println!("\n{}", "=".repeat(50));
    println!(
        "\n  Results: {} PASS, {} FAIL (total {})\n",
        pass,
        fail,
        pass + fail
    );
    if fail > 0 {
        println!("FAILED tests:");
        for (name, err) in &tests {
            if let Some(e) = err {
                println!("  - {}: {}", name, e);
            }
        }
        std::process::exit(1);
    }
    println!("=== ALL {} TESTS PASSED ===", pass);
}

fn run(
    tests: &mut Vec<(String, Option<String>)>,
    pass: &mut u32,
    fail: &mut u32,
    name: &str,
    f: impl FnOnce() -> Result<String, Box<dyn std::error::Error>>,
) {
    print!("  {:30} ", name);
    match f() {
        Ok(msg) => {
            println!("PASS  {}", msg);
            *pass += 1;
            tests.push((name.to_string(), None));
        }
        Err(e) => {
            println!("FAIL  {}", e);
            *fail += 1;
            tests.push((name.to_string(), Some(e.to_string())));
        }
    }
}
