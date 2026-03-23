use crate::logging::AppLog;
use crate::state::{OperationProgress, SpeedProfile};
use anyhow;
use crossbeam_channel::Sender;
use emmc_core::card_info::{CidInfo, CsdInfo, ExtCsdInfo};
use emmc_core::ext4::{Ext4DirEntry, Ext4Info};
use emmc_core::partition::PartitionTable;
use emmc_core::protocol::{self, ControllerStatus, EmmcConnection};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Messages sent from worker threads back to UI
pub enum WorkerMessage {
    // Connection
    PortsScanned(Vec<String>),
    FifoDevicesScanned {
        available: bool,
        info: Option<String>,
    },
    Connected,
    ConnectedWithSpeed {
        actual_baud: u32,
        actual_emmc_freq: u32,
        baud_preset: u8,
        clk_preset: u8,
    },

    // Card info
    CardInfo {
        cid: CidInfo,
        csd: CsdInfo,
    },
    ExtCsd(ExtCsdInfo),

    // Sector ops
    SectorsRead {
        lba: u64,
        data: Vec<u8>,
    },
    SectorsWritten {
        lba: u64,
        count: u64,
    },

    // Partitions
    PartitionsRead(PartitionTable),

    // ext4
    Ext4Loaded(Ext4Info),
    Ext4DirListing {
        path: String,
        entries: Vec<Ext4DirEntry>,
    },
    Ext4FileContent {
        path: String,
        data: Vec<u8>,
    },
    Ext4Written {
        path: String,
    },
    Ext4Created {
        path: String,
    },

    // RPMB
    RpmbCounterRead {
        counter: u32,
        mac_valid: bool,
        result_code: u16,
    },
    RpmbDataRead {
        address: u16,
        data: Vec<u8>,
        mac_valid: bool,
        result_code: u16,
    },

    // Card Status
    CardStatus(u32),

    // Controller debug status (GET_STATUS, 12 bytes)
    ControllerStatusReceived(ControllerStatus),

    // Re-initialization
    Reinitialized,

    // Clock speed
    ClkSpeedSet(u8),

    // Bus width
    BusWidthSet(u8),

    // UART baud
    BaudPresetSet {
        preset: u8,
        baud: u32,
    },

    // Raw CMD
    RawCmdResponse {
        status: u8,
        data: Vec<u8>,
    },

    // Erase / Verify / ExtCSD
    SectorsErased {
        lba: u64,
        count: u64,
    },
    SectorsSecureErased {
        lba: u64,
        count: u64,
    },
    SectorsVerified(String),
    ExtCsdWritten {
        index: u8,
        value: u8,
    },
    CacheFlushed,

    // Verify readback results
    WriteVerified {
        mismatches: Vec<u64>,
        total_sectors: u64,
    },
    DumpVerified {
        mismatches: Vec<u64>,
        total_sectors: u64,
    },

    // General
    Progress(OperationProgress),
    DumpCompleted {
        bytes: u64,
        path: String,
    },
    RestoreCompleted {
        bytes: u64,
        path: String,
    },
    Completed(String),
    Error(String),
    /// Silent keepalive acknowledgement — does NOT change operation status
    KeepaliveOk,
}

/// Scan serial ports
pub fn scan_ports(tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        let ports = emmc_core::protocol::list_serial_ports();
        log.info(format!("Found {} serial port(s)", ports.len()));
        for p in &ports {
            log.debug(format!("  {}", p));
        }
        let _ = tx.send(WorkerMessage::PortsScanned(ports));
    });
}

/// Scan for FT245 FIFO devices (FT232H)
pub fn scan_fifo_devices(tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        #[cfg(feature = "fifo")]
        {
            let devices = emmc_core::transport_fifo::find_fifo_devices();
            if let Some(dev) = devices.first() {
                let info = format!(
                    "{} (SN: {})",
                    dev.description,
                    if dev.serial.is_empty() {
                        "unknown"
                    } else {
                        &dev.serial
                    }
                );
                log.info(format!("FT232H found: {}", info));
                let _ = tx.send(WorkerMessage::FifoDevicesScanned {
                    available: true,
                    info: Some(info),
                });
            } else {
                log.debug("No FIFO devices found");
                let _ = tx.send(WorkerMessage::FifoDevicesScanned {
                    available: false,
                    info: None,
                });
            }
        }
        #[cfg(not(feature = "fifo"))]
        {
            let _ = &log;
            let _ = tx.send(WorkerMessage::FifoDevicesScanned {
                available: false,
                info: None,
            });
        }
    });
}

/// Connect to eMMC reader with speed profile.
/// Switches eMMC CLK first (on safe baud), then UART baud, reconnects at target baud.
/// Keepalive thread prevents FPGA baud watchdog from resetting.
/// In FIFO mode: port="fifo://", skips baud switching entirely.
pub fn connect(
    port: String,
    initial_baud: u32,
    profile: SpeedProfile,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        let is_fifo = port == "fifo://";

        if is_fifo {
            log.info("Connecting via FT245 FIFO...".to_string());
        } else {
            log.info(format!(
                "Connecting to {} at {} baud (profile: {})...",
                port,
                initial_baud,
                profile.label()
            ));
        }

        // FIFO fast path: no baud switching needed
        if is_fifo {
            let mut conn = match EmmcConnection::connect("fifo://", 0) {
                Ok(c) => c,
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!(
                        "FIFO connection failed: {}",
                        e
                    )));
                    return;
                }
            };
            if let Err(e) = conn.ping() {
                let _ = tx.send(WorkerMessage::Error(format!("FIFO ping failed: {}", e)));
                return;
            }
            log.info("FIFO Ping OK");
            read_card_info_and_report(&mut conn, &tx, &log);

            // Set eMMC clock (separate from transport)
            let clk_preset = profile.clk_preset();
            if clk_preset > 0 {
                if let Err(e) = conn.set_clk_speed(clk_preset) {
                    log.warn(format!("Set eMMC clock failed: {}", e));
                } else {
                    let clk_names = [
                        "2 MHz", "3.75 MHz", "6 MHz", "10 MHz", "15 MHz", "15 MHz", "30 MHz",
                    ];
                    let name = clk_names.get(clk_preset as usize).unwrap_or(&"?");
                    log.info(format!("eMMC clock set to {}", name));
                }
            }
            let emmc_freq = protocol::EMMC_CLK_FREQS
                .get(clk_preset as usize)
                .copied()
                .unwrap_or(2_000_000);
            let _ = tx.send(WorkerMessage::ConnectedWithSpeed {
                actual_baud: 0,
                actual_emmc_freq: emmc_freq,
                baud_preset: 0,
                clk_preset,
            });
            return;
        }

        // UART path: baud switching logic
        // Step 1: Connect at initial baud
        let target_baud = profile.target_baud();
        let mut conn = match EmmcConnection::connect(&port, initial_baud) {
            Ok(c) => c,
            Err(e) => {
                // Maybe FPGA is already at target baud from previous session
                if target_baud != initial_baud {
                    log.info(format!(
                        "Initial connect failed, trying target baud {}...",
                        target_baud
                    ));
                    match EmmcConnection::connect(&port, target_baud) {
                        Ok(c) => c,
                        Err(e2) => {
                            let _ = tx.send(WorkerMessage::Error(format!(
                                "Connection failed: {} (also tried {}: {})",
                                e, target_baud, e2
                            )));
                            return;
                        }
                    }
                } else {
                    let _ = tx.send(WorkerMessage::Error(format!("Connection failed: {}", e)));
                    return;
                }
            }
        };

        // Step 2: Ping (try initial baud, fallback to target baud)
        if let Err(_e) = conn.ping() {
            if target_baud != initial_baud {
                log.info("Ping failed at initial baud, trying target baud...");
                drop(conn);
                std::thread::sleep(std::time::Duration::from_millis(50));
                conn = match EmmcConnection::connect(&port, target_baud) {
                    Ok(c) => c,
                    Err(e2) => {
                        let _ = tx.send(WorkerMessage::Error(format!(
                            "Connection failed at target baud: {}",
                            e2
                        )));
                        return;
                    }
                };
                if let Err(e2) = conn.ping() {
                    let _ = tx.send(WorkerMessage::Error(format!(
                        "Ping failed at both bauds: {}",
                        e2
                    )));
                    return;
                }
                // Already at target baud — skip baud switch
                log.info(format!("Connected at target baud {}", target_baud));
                let clk_preset = profile.clk_preset();
                let emmc_freq = protocol::EMMC_CLK_FREQS
                    .get(clk_preset as usize)
                    .copied()
                    .unwrap_or(2_000_000);

                // Read card info
                read_card_info_and_report(&mut conn, &tx, &log);

                let _ = tx.send(WorkerMessage::ConnectedWithSpeed {
                    actual_baud: target_baud,
                    actual_emmc_freq: emmc_freq,
                    baud_preset: profile.baud_preset(),
                    clk_preset,
                });
                return;
            } else {
                let _ = tx.send(WorkerMessage::Error(format!("Ping failed: {}", _e)));
                return;
            }
        }
        log.info("Ping OK");

        // Step 3: Read card info (on reliable initial baud)
        read_card_info_and_report(&mut conn, &tx, &log);

        // Step 4: Set eMMC clock FIRST (on reliable initial baud)
        let clk_preset = profile.clk_preset();
        if clk_preset > 0 {
            if let Err(e) = conn.set_clk_speed(clk_preset) {
                log.warn(format!(
                    "Set eMMC clock failed: {}, continuing at default",
                    e
                ));
            } else {
                let clk_names = [
                    "2 MHz", "3.75 MHz", "6 MHz", "10 MHz", "15 MHz", "15 MHz", "30 MHz",
                ];
                let name = clk_names.get(clk_preset as usize).unwrap_or(&"?");
                log.info(format!("eMMC clock set to {}", name));
            }
        }

        // Step 5: Switch UART baud (if not Safe profile)
        let baud_preset = profile.baud_preset();
        if baud_preset > 0 && target_baud != initial_baud {
            log.info(format!("Switching UART to {} baud...", target_baud));
            if let Err(e) = conn.set_baud(baud_preset) {
                log.warn(format!("Set baud failed: {}", e));
                // Continue at initial baud
                let emmc_freq = protocol::EMMC_CLK_FREQS
                    .get(clk_preset as usize)
                    .copied()
                    .unwrap_or(2_000_000);
                let _ = tx.send(WorkerMessage::ConnectedWithSpeed {
                    actual_baud: initial_baud,
                    actual_emmc_freq: emmc_freq,
                    baud_preset: 0,
                    clk_preset,
                });
                return;
            }

            // Drop connection, wait, reconnect at new baud
            drop(conn);
            std::thread::sleep(std::time::Duration::from_millis(50));

            match EmmcConnection::connect(&port, target_baud) {
                Ok(mut new_conn) => {
                    match new_conn.ping() {
                        Ok(_) => {
                            log.info(format!(
                                "Speed switch OK: UART {} baud, eMMC preset {}",
                                target_baud, clk_preset
                            ));
                        }
                        Err(e) => {
                            // Watchdog may have reset — wait and fallback
                            log.warn(format!(
                                "Ping at {} failed: {}, waiting for watchdog...",
                                target_baud, e
                            ));
                            drop(new_conn);
                            std::thread::sleep(std::time::Duration::from_millis(700));
                            if let Ok(mut fallback) = EmmcConnection::connect(&port, initial_baud) {
                                if fallback.ping().is_ok() {
                                    log.warn("Fallback to initial baud OK");
                                    let emmc_freq = protocol::EMMC_CLK_FREQS
                                        .get(clk_preset as usize)
                                        .copied()
                                        .unwrap_or(2_000_000);
                                    let _ = tx.send(WorkerMessage::ConnectedWithSpeed {
                                        actual_baud: initial_baud,
                                        actual_emmc_freq: emmc_freq,
                                        baud_preset: 0,
                                        clk_preset,
                                    });
                                    return;
                                }
                            }
                            let _ = tx.send(WorkerMessage::Error(
                                "Speed switch failed, FPGA unresponsive".to_string(),
                            ));
                            return;
                        }
                    }
                }
                Err(e) => {
                    log.warn(format!("Reconnect at {} failed: {}", target_baud, e));
                    let emmc_freq = protocol::EMMC_CLK_FREQS
                        .get(clk_preset as usize)
                        .copied()
                        .unwrap_or(2_000_000);
                    let _ = tx.send(WorkerMessage::ConnectedWithSpeed {
                        actual_baud: initial_baud,
                        actual_emmc_freq: emmc_freq,
                        baud_preset: 0,
                        clk_preset,
                    });
                    return;
                }
            }
        }

        let actual_baud = if baud_preset > 0 {
            target_baud
        } else {
            initial_baud
        };
        let emmc_freq = protocol::EMMC_CLK_FREQS
            .get(clk_preset as usize)
            .copied()
            .unwrap_or(2_000_000);
        let _ = tx.send(WorkerMessage::ConnectedWithSpeed {
            actual_baud,
            actual_emmc_freq: emmc_freq,
            baud_preset,
            clk_preset,
        });
    });
}

/// Helper: read CID/CSD and send to UI
fn read_card_info_and_report(conn: &mut EmmcConnection, tx: &Sender<WorkerMessage>, log: &AppLog) {
    match conn.get_info() {
        Ok((cid_raw, csd_raw)) => {
            let cid = CidInfo::parse(&cid_raw);
            let csd = CsdInfo::parse(&csd_raw);
            log.info(format!("Card: {}", cid));
            let _ = tx.send(WorkerMessage::CardInfo { cid, csd });
        }
        Err(e) => {
            log.warn(format!("GET_INFO failed: {}", e));
        }
    }
}

/// Keepalive ping: spawns a quick worker to ping FPGA, preventing baud watchdog reset.
/// Called from UI update() loop when idle — race-free since only one op at a time.
pub fn keepalive_ping(port: String, baud: u32, tx: Sender<WorkerMessage>, _log: AppLog) {
    std::thread::spawn(move || match EmmcConnection::connect(&port, baud) {
        Ok(mut conn) => {
            let _ = conn.ping();
            let _ = tx.send(WorkerMessage::KeepaliveOk);
        }
        Err(_) => {
            let _ = tx.send(WorkerMessage::KeepaliveOk);
        }
    });
}

/// Internal: read back written sectors and compare with reference data.
/// Returns list of mismatched LBAs (relative to start_lba).
fn verify_readback_impl(
    conn: &mut EmmcConnection,
    start_lba: u32,
    reference: &[u8],
    emmc_freq: u32,
    tx: &Sender<WorkerMessage>,
    log: &AppLog,
) -> anyhow::Result<Vec<u64>> {
    let total_sectors = (reference.len() / 512) as u32;
    let chunk_size = protocol::safe_read_chunk(3_000_000, emmc_freq); // conservative baud for verify
    let mut mismatches: Vec<u64> = Vec::new();
    let mut offset = 0u32;

    while offset < total_sectors {
        let count = chunk_size.min((total_sectors - offset) as u16);
        let lba = start_lba + offset;

        let readback = protocol::with_retry(3, || conn.read_sectors(lba, count))?;

        let ref_start = (offset as usize) * 512;
        let ref_end = ref_start + readback.len();
        let ref_slice = &reference[ref_start..ref_end.min(reference.len())];

        for i in 0..(count as usize) {
            let sector_ref = &ref_slice[i * 512..((i + 1) * 512).min(ref_slice.len())];
            let sector_rb = &readback[i * 512..((i + 1) * 512).min(readback.len())];
            if sector_ref != sector_rb {
                mismatches.push((offset + i as u32) as u64);
            }
        }

        offset += count as u32;
        let _ = tx.send(WorkerMessage::Progress(OperationProgress {
            current: offset as u64,
            total: total_sectors as u64,
            description: format!("Verifying LBA {}/{}", offset, total_sectors),
        }));
    }

    if mismatches.is_empty() {
        log.info(format!("Verify OK: {} sectors match", total_sectors));
    } else {
        log.warn(format!(
            "Verify: {} mismatch(es) in {} sectors",
            mismatches.len(),
            total_sectors
        ));
    }
    Ok(mismatches)
}

/// Internal: verify readback comparing against a file (chunked, no full load).
fn verify_readback_file(
    conn: &mut EmmcConnection,
    start_lba: u32,
    file_path: &str,
    emmc_freq: u32,
    tx: &Sender<WorkerMessage>,
    log: &AppLog,
) -> anyhow::Result<Vec<u64>> {
    use std::io::Read as IoRead;

    let file_size = std::fs::metadata(file_path)?.len();
    let total_sectors = (file_size / 512) as u32;
    let chunk_size = protocol::safe_read_chunk(3_000_000, emmc_freq);
    let mut mismatches: Vec<u64> = Vec::new();
    let mut offset = 0u32;
    let mut file = std::fs::File::open(file_path)?;

    while offset < total_sectors {
        let count = chunk_size.min((total_sectors - offset) as u16);
        let lba = start_lba + offset;

        let readback = protocol::with_retry(3, || conn.read_sectors(lba, count))?;

        let mut ref_buf = vec![0u8; readback.len()];
        file.read_exact(&mut ref_buf)?;

        for i in 0..(count as usize) {
            let sector_ref = &ref_buf[i * 512..(i + 1) * 512];
            let sector_rb = &readback[i * 512..(i + 1) * 512];
            if sector_ref != sector_rb {
                mismatches.push((offset + i as u32) as u64);
            }
        }

        offset += count as u32;
        let _ = tx.send(WorkerMessage::Progress(OperationProgress {
            current: offset as u64,
            total: total_sectors as u64,
            description: format!("Verifying LBA {}/{}", offset, total_sectors),
        }));
    }

    if mismatches.is_empty() {
        log.info(format!("Verify OK: {} sectors match", total_sectors));
    } else {
        log.warn(format!(
            "Verify: {} mismatch(es) in {} sectors",
            mismatches.len(),
            total_sectors
        ));
    }
    Ok(mismatches)
}

/// Read sectors in worker thread
pub fn read_sectors(
    port: String,
    baud: u32,
    lba: u32,
    count: u16,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.info(format!("Reading {} sector(s) from LBA {}...", count, lba));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.read_sectors(lba, count) {
                Ok(data) => {
                    log.info(format!("Read {} bytes", data.len()));
                    let _ = tx.send(WorkerMessage::SectorsRead {
                        lba: lba as u64,
                        data,
                    });
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Read failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Write sectors in worker thread
pub fn write_sectors(
    port: String,
    baud: u32,
    lba: u32,
    data: Vec<u8>,
    verify: bool,
    emmc_freq: u32,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        let count = data.len() / 512;
        log.warn(format!("Writing {} sector(s) to LBA {}...", count, lba));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.write_sectors(lba, &data) {
                Ok(()) => {
                    log.info(format!("Written {} sector(s)", count));
                    if verify {
                        log.info("Verifying write...");
                        match verify_readback_impl(&mut conn, lba, &data, emmc_freq, &tx, &log) {
                            Ok(mismatches) => {
                                let total = count as u64;
                                let _ = tx.send(WorkerMessage::WriteVerified {
                                    mismatches,
                                    total_sectors: total,
                                });
                            }
                            Err(e) => {
                                let _ =
                                    tx.send(WorkerMessage::Error(format!("Verify failed: {}", e)));
                            }
                        }
                    } else {
                        let _ = tx.send(WorkerMessage::SectorsWritten {
                            lba: lba as u64,
                            count: count as u64,
                        });
                    }
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Write failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Read partition table in worker thread
pub fn read_partitions(port: String, baud: u32, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        log.info("Reading partition table...");
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match emmc_core::partition::read_partition_table(&mut conn) {
                Ok(pt) => {
                    log.info(format!(
                        "Partition table: {:?}, {} partition(s)",
                        pt.table_type,
                        pt.partitions.len()
                    ));
                    let _ = tx.send(WorkerMessage::PartitionsRead(pt));
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!(
                        "Partition read failed: {}",
                        e
                    )));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Read Extended CSD in worker thread
pub fn read_ext_csd(port: String, baud: u32, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        log.info("Reading Extended CSD...");
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.get_ext_csd() {
                Ok(data) => {
                    let info = ExtCsdInfo::parse(&data);
                    log.info(format!(
                        "ExtCSD: {} sectors, {}",
                        info.sec_count,
                        info.capacity_human()
                    ));
                    let _ = tx.send(WorkerMessage::ExtCsd(info));
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("ExtCSD read failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Set partition in worker thread
pub fn set_partition(
    port: String,
    baud: u32,
    partition: u8,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        let name = match partition {
            0 => "User",
            1 => "Boot0",
            2 => "Boot1",
            3 => "RPMB",
            _ => "?",
        };
        log.info(format!("Switching to partition {}...", name));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.set_partition(partition) {
                Ok(()) => {
                    log.info(format!("Switched to {}", name));
                    let _ = tx.send(WorkerMessage::Completed(format!("Partition: {}", name)));
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Set partition failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Dump eMMC to file in worker thread
pub fn dump_to_file(
    port: String,
    baud: u32,
    emmc_freq: u32,
    start_lba: u32,
    sector_count: u32,
    output_path: String,
    verify: bool,
    cancel: Arc<AtomicBool>,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        let chunk_size = protocol::safe_read_chunk(baud, emmc_freq);
        log.info(format!(
            "Dumping {} sectors from LBA {} to {} (chunk={})...",
            sector_count, start_lba, output_path, chunk_size
        ));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => {
                let mut file = match std::fs::File::create(&output_path) {
                    Ok(f) => f,
                    Err(e) => {
                        let _ = tx.send(WorkerMessage::Error(format!("Create file failed: {}", e)));
                        return;
                    }
                };

                let mut offset = 0u32;
                let mut total_bytes = 0u64;

                while offset < sector_count {
                    if cancel.load(Ordering::Relaxed) {
                        log.warn("Dump cancelled");
                        let _ = tx.send(WorkerMessage::Error("Cancelled".into()));
                        return;
                    }

                    let remaining = sector_count - offset;
                    let count = chunk_size.min(remaining as u16);
                    let lba = start_lba + offset;

                    match protocol::with_retry(3, || conn.read_sectors(lba, count)) {
                        Ok(data) => {
                            use std::io::Write;
                            if let Err(e) = file.write_all(&data) {
                                let _ = tx.send(WorkerMessage::Error(format!(
                                    "Write file failed: {}",
                                    e
                                )));
                                return;
                            }
                            total_bytes += data.len() as u64;
                            offset += count as u32;

                            let _ = tx.send(WorkerMessage::Progress(OperationProgress {
                                current: offset as u64,
                                total: sector_count as u64,
                                description: format!("Dumping LBA {}/{}", offset, sector_count),
                            }));
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(format!(
                                "Read error at LBA {} (after retries): {}",
                                lba, e
                            )));
                            return;
                        }
                    }
                }

                log.info(format!("Dump complete: {} bytes", total_bytes));
                let _ = tx.send(WorkerMessage::DumpCompleted {
                    bytes: total_bytes,
                    path: output_path.clone(),
                });

                if verify {
                    log.info("Verifying dump...");
                    match verify_readback_file(
                        &mut conn,
                        start_lba,
                        &output_path,
                        emmc_freq,
                        &tx,
                        &log,
                    ) {
                        Ok(mismatches) => {
                            let _ = tx.send(WorkerMessage::DumpVerified {
                                mismatches,
                                total_sectors: sector_count as u64,
                            });
                        }
                        Err(e) => {
                            log.warn(format!("Dump verify failed: {}", e));
                        }
                    }
                }
            }
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Restore from file to eMMC in worker thread
pub fn restore_from_file(
    port: String,
    baud: u32,
    start_lba: u32,
    input_path: String,
    verify: bool,
    emmc_freq: u32,
    cancel: Arc<AtomicBool>,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.warn(format!(
            "Restoring from {} to LBA {}...",
            input_path, start_lba
        ));

        let file_size = match std::fs::metadata(&input_path) {
            Ok(m) => m.len(),
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Read file failed: {}", e)));
                return;
            }
        };

        let file_sectors = ((file_size + 511) / 512) as usize;
        let file_offset = start_lba as usize * 512;
        if file_offset >= file_size as usize {
            let _ = tx.send(WorkerMessage::Error(format!(
                "Start LBA {} beyond file size ({} sectors)",
                start_lba, file_sectors
            )));
            return;
        }
        let sector_count = file_sectors - start_lba as usize;

        let file_data = match std::fs::read(&input_path) {
            Ok(d) => d,
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Read file failed: {}", e)));
                return;
            }
        };

        const CHUNK: usize = 16; // sectors per CMD25 packet (FPGA 16-bank FIFO limit)

        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => {
                // Enable write cache for faster writes
                match conn.enable_cache() {
                    Ok(true) => log.info("Write cache enabled"),
                    Ok(false) => log.info("Card does not support write cache"),
                    Err(e) => log.warn(format!("Failed to enable cache: {}", e)),
                }

                // Pipelined write: send batch N+1 right after recv batch N
                // to overlap serial TX with eMMC flash programming
                let mut written = 0usize;
                let mut pending_lba: Option<u32> = None;
                let mut pending_n = 0usize;

                while written < sector_count {
                    if cancel.load(Ordering::Relaxed) {
                        // Drain pending response before cancel
                        if let Some(plba) = pending_lba {
                            let _ = conn.recv_write_response(plba);
                        }
                        log.warn("Restore cancelled");
                        let _ = conn.flush_cache();
                        let _ = tx.send(WorkerMessage::Error("Cancelled".into()));
                        return;
                    }

                    let n = CHUNK.min(sector_count - written);
                    let start = file_offset + written * 512;
                    let end = (start + n * 512).min(file_data.len());
                    let mut chunk = vec![0u8; n * 512];
                    let copy_len = end - start;
                    chunk[..copy_len].copy_from_slice(&file_data[start..end]);

                    // Receive response from previous batch (if any)
                    if let Some(plba) = pending_lba {
                        if let Err(e) = conn.recv_write_response(plba) {
                            let _ = conn.flush_cache();
                            let _ = tx.send(WorkerMessage::Error(format!(
                                "Write error at LBA {} (pipelined): {}",
                                plba, e
                            )));
                            return;
                        }
                        let done = written; // sectors confirmed written
                        let _ = tx.send(WorkerMessage::Progress(OperationProgress {
                            current: done as u64,
                            total: sector_count as u64,
                            description: format!("Restoring LBA {}/{}", done, sector_count),
                        }));
                    }

                    // Send this batch (non-blocking)
                    let lba = start_lba + written as u32;
                    if let Err(e) = conn.send_write_command(lba, &chunk) {
                        let _ = conn.flush_cache();
                        let _ = tx.send(WorkerMessage::Error(format!(
                            "Send error at LBA {}: {}",
                            lba, e
                        )));
                        return;
                    }
                    pending_lba = Some(lba);
                    pending_n = n;
                    written += n;
                }

                // Receive final batch response
                if let Some(plba) = pending_lba {
                    if let Err(e) = conn.recv_write_response(plba) {
                        let _ = conn.flush_cache();
                        let _ = tx.send(WorkerMessage::Error(format!(
                            "Write error at LBA {} (final): {}",
                            plba, e
                        )));
                        return;
                    }
                }
                let _ = tx.send(WorkerMessage::Progress(OperationProgress {
                    current: sector_count as u64,
                    total: sector_count as u64,
                    description: format!("Restoring LBA {}/{}", sector_count, sector_count),
                }));
                let _ = pending_n;

                // Flush cache to flash
                if let Err(e) = conn.flush_cache() {
                    log.warn(format!("Cache flush failed: {}", e));
                }

                let bytes_written = sector_count * 512;
                log.info(format!("Restore complete: {} bytes", bytes_written));
                let _ = tx.send(WorkerMessage::RestoreCompleted {
                    bytes: bytes_written as u64,
                    path: input_path.clone(),
                });

                if verify {
                    log.info("Verifying restore...");
                    match verify_readback_file(
                        &mut conn,
                        start_lba,
                        &input_path,
                        emmc_freq,
                        &tx,
                        &log,
                    ) {
                        Ok(mismatches) => {
                            let _ = tx.send(WorkerMessage::WriteVerified {
                                mismatches,
                                total_sectors: sector_count as u64,
                            });
                        }
                        Err(e) => {
                            log.warn(format!("Restore verify failed: {}", e));
                        }
                    }
                }
            }
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Read ext4 filesystem info
pub fn ext4_load(
    port: String,
    baud: u32,
    partition_start_lba: u64,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.info(format!(
            "ext4: Loading partition at LBA {} (port={}, baud={})",
            partition_start_lba, port, baud
        ));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => {
                log.info("ext4: Opening filesystem (reading superblock + group descriptors)...");
                match emmc_core::ext4::Ext4Fs::open(&mut conn, partition_start_lba) {
                    Ok(mut fs) => {
                        let info = fs.info();
                        log.info(format!(
                            "ext4: Opened '{}', block_size={}, blocks={}, inodes={}",
                            info.volume_name, info.block_size, info.block_count, info.inode_count
                        ));
                        // Also list root directory
                        let entries = fs.ls("/").ok();
                        let _ = tx.send(WorkerMessage::Ext4Loaded(info));
                        if let Some(entries) = entries {
                            log.info(format!("ext4: Root directory: {} entries", entries.len()));
                            let _ = tx.send(WorkerMessage::Ext4DirListing {
                                path: "/".to_string(),
                                entries,
                            });
                        }
                    }
                    Err(e) => {
                        log.error(format!(
                            "ext4: Failed to open at LBA {}: {}",
                            partition_start_lba, e
                        ));
                        let _ =
                            tx.send(WorkerMessage::Error(format!("ext4 load failed: {}", e)));
                    }
                }
            }
            Err(e) => {
                log.error(format!("ext4: Connect failed: {}", e));
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// List ext4 directory
pub fn ext4_ls(
    port: String,
    baud: u32,
    partition_start_lba: u64,
    path: String,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.info(format!("ext4: Navigate to '{}'", path));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match emmc_core::ext4::Ext4Fs::open(&mut conn, partition_start_lba) {
                Ok(mut fs) => match fs.ls(&path) {
                    Ok(entries) => {
                        log.info(format!("ext4: ls '{}': {} entries", path, entries.len()));
                        let _ = tx.send(WorkerMessage::Ext4DirListing {
                            path: path.clone(),
                            entries,
                        });
                    }
                    Err(e) => {
                        log.error(format!("ext4: ls '{}' failed: {}", path, e));
                        let _ = tx.send(WorkerMessage::Error(format!("ls failed: {}", e)));
                    }
                },
                Err(e) => {
                    log.error(format!(
                        "ext4: re-open failed at LBA {}: {}",
                        partition_start_lba, e
                    ));
                    let _ =
                        tx.send(WorkerMessage::Error(format!("ext4 open failed: {}", e)));
                }
            },
            Err(e) => {
                log.error(format!("ext4: Connect failed: {}", e));
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Read ext4 file
pub fn ext4_cat(
    port: String,
    baud: u32,
    partition_start_lba: u64,
    path: String,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.info(format!("ext4: Reading file '{}'", path));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match emmc_core::ext4::Ext4Fs::open(&mut conn, partition_start_lba) {
                Ok(mut fs) => match fs.cat(&path) {
                    Ok(data) => {
                        log.info(format!("ext4: Read '{}' ({} bytes)", path, data.len()));
                        let _ = tx.send(WorkerMessage::Ext4FileContent {
                            path: path.clone(),
                            data,
                        });
                    }
                    Err(e) => {
                        log.error(format!("ext4: cat '{}' failed: {}", path, e));
                        let _ = tx.send(WorkerMessage::Error(format!("cat failed: {}", e)));
                    }
                },
                Err(e) => {
                    log.error(format!("ext4: re-open failed: {}", e));
                    let _ =
                        tx.send(WorkerMessage::Error(format!("ext4 open failed: {}", e)));
                }
            },
            Err(e) => {
                log.error(format!("ext4: Connect failed: {}", e));
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Erase sectors in worker thread
pub fn erase_sectors(
    port: String,
    baud: u32,
    lba: u32,
    count: u16,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.warn(format!("Erasing {} sector(s) from LBA {}...", count, lba));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.erase(lba, count) {
                Ok(()) => {
                    log.info(format!("Erased {} sector(s)", count));
                    let _ = tx.send(WorkerMessage::SectorsErased {
                        lba: lba as u64,
                        count: count as u64,
                    });
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Erase failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Secure erase sectors (physical overwrite guaranteed)
pub fn secure_erase_sectors(
    port: String,
    baud: u32,
    lba: u32,
    count: u16,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.warn(format!(
            "Secure erasing {} sector(s) from LBA {}...",
            count, lba
        ));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.secure_erase(lba, count) {
                Ok(()) => {
                    log.info(format!("Secure erased {} sector(s)", count));
                    let _ = tx.send(WorkerMessage::SectorsSecureErased {
                        lba: lba as u64,
                        count: count as u64,
                    });
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Secure erase failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Verify sectors against file
pub fn verify_sectors(
    port: String,
    baud: u32,
    emmc_freq: u32,
    lba: u32,
    file_path: String,
    cancel: Arc<AtomicBool>,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        let chunk_size = protocol::safe_read_chunk(baud, emmc_freq);
        log.info(format!(
            "Verifying sectors from LBA {} against {} (chunk={})...",
            lba, file_path, chunk_size
        ));

        let file_data = match std::fs::read(&file_path) {
            Ok(d) => d,
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Read file failed: {}", e)));
                return;
            }
        };

        let sector_count = (file_data.len() + 511) / 512;
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => {
                let mut offset = 0usize;
                let mut mismatches = Vec::new();

                while offset < sector_count {
                    if cancel.load(Ordering::Relaxed) {
                        let _ = tx.send(WorkerMessage::Error("Cancelled".into()));
                        return;
                    }

                    let remaining = sector_count - offset;
                    let count = chunk_size.min(remaining as u16);
                    let read_lba = lba + offset as u32;

                    match protocol::with_retry(3, || conn.read_sectors(read_lba, count)) {
                        Ok(emmc_data) => {
                            for i in 0..count as usize {
                                let emmc_start = i * 512;
                                let file_start = (offset + i) * 512;
                                let file_end = (file_start + 512).min(file_data.len());

                                if file_start >= file_data.len() {
                                    break;
                                }

                                let emmc_sector = &emmc_data[emmc_start..emmc_start + 512];
                                let mut file_sector = [0u8; 512];
                                file_sector[..file_end - file_start]
                                    .copy_from_slice(&file_data[file_start..file_end]);

                                if emmc_sector != &file_sector[..] {
                                    mismatches.push(lba as u64 + offset as u64 + i as u64);
                                }
                            }

                            offset += count as usize;
                            let _ = tx.send(WorkerMessage::Progress(OperationProgress {
                                current: offset as u64,
                                total: sector_count as u64,
                                description: format!("Verifying LBA {}/{}", offset, sector_count),
                            }));
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(format!(
                                "Read error at LBA {} (after retries): {}",
                                read_lba, e
                            )));
                            return;
                        }
                    }
                }

                let report = if mismatches.is_empty() {
                    format!(
                        "MATCH: All {} sectors verified OK (LBA {} - {})",
                        sector_count,
                        lba,
                        lba as usize + sector_count - 1
                    )
                } else {
                    let mut r = format!(
                        "MISMATCH: {} of {} sectors differ\n",
                        mismatches.len(),
                        sector_count
                    );
                    for (i, &m) in mismatches.iter().enumerate().take(50) {
                        r.push_str(&format!("  LBA {}\n", m));
                        if i == 49 && mismatches.len() > 50 {
                            r.push_str(&format!("  ... and {} more\n", mismatches.len() - 50));
                        }
                    }
                    r
                };

                log.info(&report);
                let _ = tx.send(WorkerMessage::SectorsVerified(report));
            }
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// ext4 overwrite file
pub fn ext4_write(
    port: String,
    baud: u32,
    partition_lba: u64,
    path: String,
    data: Vec<u8>,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.warn(format!("ext4 overwrite {} ({} bytes)...", path, data.len()));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match emmc_core::ext4::Ext4Fs::open(&mut conn, partition_lba) {
                Ok(mut fs) => match fs.lookup(&path) {
                    Ok(inode) => match fs.overwrite_file_data(&inode, &data) {
                        Ok(()) => {
                            log.info(format!("Written {} bytes to {}", data.len(), path));
                            let _ = tx.send(WorkerMessage::Ext4Written { path: path.clone() });
                        }
                        Err(e) => {
                            let _ =
                                tx.send(WorkerMessage::Error(format!("Overwrite failed: {}", e)));
                        }
                    },
                    Err(e) => {
                        let _ = tx.send(WorkerMessage::Error(format!("Lookup failed: {}", e)));
                    }
                },
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("ext4 open failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// ext4 create file
pub fn ext4_create(
    port: String,
    baud: u32,
    partition_lba: u64,
    parent_path: String,
    name: String,
    data: Vec<u8>,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.warn(format!(
            "ext4 create {}/{} ({} bytes)...",
            parent_path,
            name,
            data.len()
        ));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match emmc_core::ext4::Ext4Fs::open(&mut conn, partition_lba) {
                Ok(mut fs) => match fs.create_file(&parent_path, &name, &data) {
                    Ok(ino) => {
                        let full_path = if parent_path == "/" {
                            format!("/{}", name)
                        } else {
                            format!("{}/{}", parent_path, name)
                        };
                        log.info(format!("Created {} (inode {})", full_path, ino));
                        let _ = tx.send(WorkerMessage::Ext4Created { path: full_path });
                    }
                    Err(e) => {
                        let _ = tx.send(WorkerMessage::Error(format!("Create file failed: {}", e)));
                    }
                },
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("ext4 open failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Write ExtCSD byte in worker thread
pub fn write_ext_csd(
    port: String,
    baud: u32,
    index: u8,
    value: u8,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.info(format!("Writing ExtCSD[{}] = 0x{:02X}...", index, value));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.write_ext_csd(index, value) {
                Ok(()) => {
                    log.info(format!("ExtCSD[{}] = 0x{:02X} written OK", index, value));
                    let _ = tx.send(WorkerMessage::ExtCsdWritten { index, value });
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Write ExtCSD failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Enable cache and flush in worker thread
pub fn cache_flush(port: String, baud: u32, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        log.info("Enabling eMMC cache and flushing...".to_string());
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => {
                if let Err(e) = conn.write_ext_csd(33, 1) {
                    let _ = tx.send(WorkerMessage::Error(format!("Cache enable failed: {}", e)));
                    return;
                }
                if let Err(e) = conn.write_ext_csd(32, 1) {
                    let _ = tx.send(WorkerMessage::Error(format!("Cache flush failed: {}", e)));
                    return;
                }
                log.info("Cache flushed OK".to_string());
                let _ = tx.send(WorkerMessage::CacheFlushed);
            }
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Read Card Status Register (CMD13) in worker thread
pub fn get_card_status(port: String, baud: u32, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        log.info("Reading Card Status (CMD13)...".to_string());
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.get_card_status() {
                Ok(status) => {
                    let state = (status >> 9) & 0xF;
                    let state_name = match state {
                        0 => "idle",
                        1 => "ready",
                        2 => "ident",
                        3 => "stby",
                        4 => "tran",
                        5 => "data",
                        6 => "rcv",
                        7 => "prg",
                        8 => "dis",
                        9 => "btst",
                        10 => "slp",
                        _ => "unknown",
                    };
                    log.info(format!(
                        "Card Status: 0x{:08X} (state={}, ready={})",
                        status,
                        state_name,
                        (status >> 8) & 1
                    ));
                    let _ = tx.send(WorkerMessage::CardStatus(status));
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Card Status failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Read controller debug status (GET_STATUS, 12-byte response)
pub fn get_controller_status(port: String, baud: u32, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        log.info("Reading controller status...".to_string());
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.get_status() {
                Ok(cs) => {
                    log.info(format!(
                        "init={}({}) mc={}({}) info_valid={} cmd_ready={} fast_clk={} errs: timeout={} crc={} rd={} wr={} retries={}",
                        cs.init_state, cs.init_state_name(),
                        cs.mc_state, cs.mc_state_name(),
                        cs.info_valid as u8, cs.cmd_ready as u8,
                        cs.use_fast_clk as u8,
                        cs.cmd_timeout_cnt, cs.cmd_crc_err_cnt,
                        cs.dat_rd_err_cnt, cs.dat_wr_err_cnt,
                        cs.init_retry_cnt,
                    ));
                    let _ = tx.send(WorkerMessage::ControllerStatusReceived(cs));
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!(
                        "Controller status failed: {}",
                        e
                    )));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Full re-initialization (CMD0 + init sequence) in worker thread
pub fn reinit(port: String, baud: u32, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        log.info("Re-initializing eMMC card...".to_string());
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.reinit() {
                Ok(()) => {
                    log.info("Re-initialization complete".to_string());
                    let _ = tx.send(WorkerMessage::Reinitialized);
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Re-init failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Set eMMC clock speed by preset index (0-6) in worker thread
pub fn set_clk_speed(port: String, baud: u32, preset: u8, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        let names = [
            "2 MHz", "3.75 MHz", "6 MHz", "10 MHz", "15 MHz", "15 MHz", "30 MHz",
        ];
        let name = names.get(preset as usize).unwrap_or(&"?");
        log.info(format!("Setting eMMC clock to {}...", name));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.set_clk_speed(preset) {
                Ok(()) => {
                    log.info(format!("eMMC clock set to {}", name));
                    let _ = tx.send(WorkerMessage::ClkSpeedSet(preset));
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Set clock failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Set eMMC bus width (1 or 4) via CMD6 SWITCH ExtCSD[183]
pub fn set_bus_width(port: String, baud: u32, width: u8, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        let name = if width == 4 { "4-bit" } else { "1-bit" };
        log.info(format!("Setting bus width to {}...", name));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match conn.set_bus_width(width) {
                Ok(()) => {
                    log.info(format!("Bus width set to {}", name));
                    let _ = tx.send(WorkerMessage::BusWidthSet(width));
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!("Set bus width failed: {}", e)));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Set UART baud rate by preset (0-3) in worker thread.
/// Pattern: connect(old_baud) → send CMD → drop → sleep → connect(new_baud) → ping.
pub fn set_baud(port: String, baud: u32, preset: u8, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        let baud_rates: [u32; 4] = [3_000_000, 6_000_000, 7_500_000, 12_000_000];
        let names = ["3 Mbaud", "6 Mbaud", "7.5 Mbaud", "12 Mbaud"];
        if preset > 3 {
            let _ = tx.send(WorkerMessage::Error("Invalid baud preset (0-3)".into()));
            return;
        }
        let new_baud = baud_rates[preset as usize];
        let name = names[preset as usize];
        log.info(format!("Switching UART to {}...", name));

        // 1. Send SET_BAUD on current baud
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => {
                if let Err(e) = conn.set_baud(preset) {
                    let _ = tx.send(WorkerMessage::Error(format!("SET_BAUD failed: {}", e)));
                    return;
                }
            }
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
                return;
            }
        }
        // Connection dropped — FPGA switches baud after TX complete

        // 2. Wait for FPGA to apply new baud
        std::thread::sleep(std::time::Duration::from_millis(70));

        // 3. Verify at new baud
        match EmmcConnection::connect(&port, new_baud) {
            Ok(mut conn) => match conn.ping() {
                Ok(()) => {
                    log.info(format!("UART switched to {}", name));
                    let _ = tx.send(WorkerMessage::BaudPresetSet {
                        preset,
                        baud: new_baud,
                    });
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!(
                        "Ping failed at {} — baud switch may have failed: {}",
                        name, e
                    )));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!(
                    "Reconnect at {} failed: {}",
                    name, e
                )));
            }
        }
    });
}

/// Send raw eMMC command in worker thread
pub fn send_raw_cmd(
    port: String,
    baud: u32,
    cmd_index: u8,
    argument: u32,
    resp_expected: bool,
    resp_long: bool,
    check_busy: bool,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.info(format!(
            "Sending CMD{} arg=0x{:08X} flags=[resp={},long={},busy={}]",
            cmd_index, argument, resp_expected, resp_long, check_busy
        ));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => {
                match conn.send_raw_cmd(cmd_index, argument, resp_expected, resp_long, check_busy) {
                    Ok((status, data)) => {
                        let _ = tx.send(WorkerMessage::RawCmdResponse { status, data });
                    }
                    Err(e) => {
                        let _ = tx.send(WorkerMessage::Error(format!("Raw CMD failed: {}", e)));
                    }
                }
            }
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// Format a hex dump string
pub fn hex_dump(data: &[u8], max_bytes: usize) -> String {
    let mut output = String::new();
    let show = data.len().min(max_bytes);

    for (i, chunk) in data[..show].chunks(16).enumerate() {
        let offset = i * 16;
        output.push_str(&format!("{:08X}  ", offset));

        for (j, &byte) in chunk.iter().enumerate() {
            output.push_str(&format!("{:02X} ", byte));
            if j == 7 {
                output.push(' ');
            }
        }

        let padding = 16 - chunk.len();
        for j in 0..padding {
            output.push_str("   ");
            if chunk.len() + j == 7 {
                output.push(' ');
            }
        }

        output.push_str(" |");
        for &byte in chunk {
            if byte.is_ascii_graphic() || byte == b' ' {
                output.push(byte as char);
            } else {
                output.push('.');
            }
        }
        output.push_str("|\n");
    }

    if show < data.len() {
        output.push_str(&format!("... ({} more bytes)\n", data.len() - show));
    }

    output
}

// ─── RPMB ───

/// Read RPMB write counter
pub fn rpmb_read_counter(port: String, baud: u32, tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        log.info("Reading RPMB write counter...");
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match emmc_core::rpmb::read_counter(&mut conn) {
                Ok((frame, mac_valid)) => {
                    log.info(format!(
                        "RPMB counter: {}, result: {}, MAC: {}",
                        frame.write_counter,
                        emmc_core::rpmb::result_name(frame.result),
                        if mac_valid { "valid" } else { "INVALID" }
                    ));
                    let _ = tx.send(WorkerMessage::RpmbCounterRead {
                        counter: frame.write_counter,
                        mac_valid,
                        result_code: frame.result,
                    });
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!(
                        "RPMB read counter failed: {}",
                        e
                    )));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}

/// RPMB authenticated read at address
pub fn rpmb_read_data(
    port: String,
    baud: u32,
    address: u16,
    tx: Sender<WorkerMessage>,
    log: AppLog,
) {
    std::thread::spawn(move || {
        log.info(format!("RPMB read data at address {}...", address));
        match EmmcConnection::connect(&port, baud) {
            Ok(mut conn) => match emmc_core::rpmb::read_data(&mut conn, address) {
                Ok((frame, mac_valid)) => {
                    log.info(format!(
                        "RPMB read addr {}: result={}, MAC={}",
                        address,
                        emmc_core::rpmb::result_name(frame.result),
                        if mac_valid { "valid" } else { "INVALID" }
                    ));
                    let _ = tx.send(WorkerMessage::RpmbDataRead {
                        address,
                        data: frame.data.to_vec(),
                        mac_valid,
                        result_code: frame.result,
                    });
                }
                Err(e) => {
                    let _ = tx.send(WorkerMessage::Error(format!(
                        "RPMB read data failed: {}",
                        e
                    )));
                }
            },
            Err(e) => {
                let _ = tx.send(WorkerMessage::Error(format!("Connect failed: {}", e)));
            }
        }
    });
}
