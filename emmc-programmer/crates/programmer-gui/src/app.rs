use crossbeam_channel::{unbounded, Receiver, Sender};
use eframe::egui;
use emmc_core::ext4::Ext4Fs;
use programmer_engine::command::Command;
use programmer_engine::operations::{self, WorkerMessage};
use programmer_engine::state::{
    ActiveTab, AppState, Ext4Entry, Ext4FsInfo, Ext4SearchResult, OperationStatus,
};
use programmer_fpga::FpgaUartProgrammer;
use programmer_hal::traits::*;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use crate::panels;
use crate::theme;

fn convert_ext4_info(info: &emmc_core::ext4::Ext4Info) -> Ext4FsInfo {
    Ext4FsInfo {
        volume_name: info.volume_name.clone(),
        uuid: info.uuid.clone(),
        block_size: info.block_size,
        block_count: info.block_count,
        free_blocks: info.free_blocks,
        inode_count: info.inode_count,
        free_inodes: info.free_inodes,
        is_64bit: info.is_64bit,
        has_extents: info.has_extents,
        metadata_csum: info.metadata_csum,
    }
}

fn convert_ext4_entries(entries: &[emmc_core::ext4::Ext4DirEntry]) -> Vec<Ext4Entry> {
    entries
        .iter()
        .map(|e| Ext4Entry {
            inode: e.inode,
            name: e.name.clone(),
            file_type: e.file_type,
        })
        .collect()
}

pub struct ProgrammerApp {
    pub state: AppState,
    pub worker_tx: Sender<WorkerMessage>,
    pub worker_rx: Receiver<WorkerMessage>,
    pub programmer: Option<Arc<Mutex<FpgaUartProgrammer>>>,
    pub last_activity: std::time::Instant,
}

impl ProgrammerApp {
    pub fn new(_cc: &eframe::CreationContext<'_>) -> Self {
        let (tx, rx) = unbounded();
        let state = AppState::new();
        state.log.info("Flash Programmer started");

        operations::scan_ports(tx.clone(), state.log.clone());
        operations::scan_fifo_devices(tx.clone(), state.log.clone());

        Self {
            state,
            worker_tx: tx,
            worker_rx: rx,
            programmer: None,
            last_activity: std::time::Instant::now(),
        }
    }

    fn process_messages(&mut self) {
        while let Ok(msg) = self.worker_rx.try_recv() {
            self.last_activity = std::time::Instant::now();
            match msg {
                WorkerMessage::PortsScanned(ports) => {
                    if !ports.is_empty() && self.state.selected_port.is_empty() {
                        self.state.selected_port = ports[0].clone();
                    }
                    self.state.available_ports = ports;
                }
                WorkerMessage::FifoDevicesScanned { available, info } => {
                    self.state.fifo_available = available;
                    self.state.fifo_device_info = info;
                    if available && self.state.selected_port.is_empty() {
                        self.state.use_fifo = true;
                    }
                }
                WorkerMessage::Connected => {
                    self.state.connected = true;
                    self.state.set_completed("Connected");
                }
                WorkerMessage::ConnectedWithSpeed {
                    actual_baud,
                    baud_preset,
                    clk_preset,
                } => {
                    self.state.connected = true;
                    self.state.selected_baud = actual_baud;
                    self.state.current_baud = actual_baud;
                    self.state.selected_baud_preset = baud_preset as usize;
                    self.state.selected_clk_preset = clk_preset as usize;
                    let clk_names = ["2 MHz", "3.75 MHz", "6 MHz", "10 MHz", "15 MHz", "15 MHz", "30 MHz"];
                    let clk_name = clk_names.get(clk_preset as usize).unwrap_or(&"?");
                    let transport = if self.state.use_fifo { "FIFO" } else { "UART" };
                    self.state.log.info(format!(
                        "Connected: transport={}, clock={}, baud={}",
                        transport, clk_name, actual_baud
                    ));
                    self.state
                        .set_completed(format!("Connected (baud: {})", actual_baud));
                }
                WorkerMessage::ChipIdentified(info) => {
                    self.state.log.info(format!("Chip: {}", info));
                    self.state.chip_info = Some(info);
                    self.state.set_completed("Chip identified");
                }
                WorkerMessage::ExtCsdRead(data) => {
                    // Parse ExtCSD into structured data
                    if data.len() >= 512 {
                        use emmc_core::card_info::ExtCsdInfo;
                        let info = ExtCsdInfo::parse(&data);
                        self.state.ext_csd_parsed = Some(programmer_engine::state::ExtCsdData {
                            capacity_bytes: info.capacity_bytes,
                            fw_version: info.fw_version,
                            boot_partition_size: info.boot_partition_size,
                            rpmb_size: info.rpmb_size,
                            boot_ack: info.boot_ack,
                            boot_partition: info.boot_partition,
                            partition_access: info.partition_access,
                            hs_support: info.hs_support,
                            hs52_support: info.hs52_support,
                            ddr_support: info.ddr_support,
                            life_time_est_a: info.life_time_est_a,
                            life_time_est_b: info.life_time_est_b,
                            pre_eol_info: info.pre_eol_info,
                        });
                    }
                    self.state.ext_csd_raw = Some(data);
                    self.state.set_completed("ExtCSD read");
                }
                WorkerMessage::SectorsRead { lba, data } => {
                    let len = data.len();
                    self.state.hex_data = data;
                    self.state.hex_source_lba = Some(lba as u64);
                    self.state.hex_modified.clear();
                    self.state.hex_undo_stack.clear();
                    self.state.hex_redo_stack.clear();
                    self.state.hex_cursor = 0;
                    self.state
                        .set_completed(format!("Read {} bytes at LBA {}", len, lba));
                }
                WorkerMessage::SectorsWritten { lba, count } => {
                    self.state
                        .log
                        .info(format!("Written {} sector(s) at LBA {}", count, lba));
                    self.state.set_completed("Write complete");
                }
                WorkerMessage::SectorsErased { lba, count } => {
                    self.state
                        .log
                        .info(format!("Erased {} sector(s) at LBA {}", count, lba));
                    self.state.set_completed("Erase complete");
                }
                WorkerMessage::SecureErased { lba, count } => {
                    self.state
                        .log
                        .info(format!("Secure erased {} sector(s) at LBA {}", count, lba));
                    self.state.set_completed("Secure erase complete");
                }
                WorkerMessage::CardStatusRead(status) => {
                    self.state.card_status_raw = Some(status);
                    self.state
                        .log
                        .info(format!("Card status: 0x{:08X}", status));
                    self.state.set_completed("Card status read");
                }
                WorkerMessage::ControllerStatusRead(status) => {
                    self.state.controller_status = Some(status);
                    self.state.set_completed("Controller status read");
                }
                WorkerMessage::VerifyComplete {
                    total_bytes,
                    mismatches,
                } => {
                    if mismatches == 0 {
                        self.state
                            .set_completed(format!("Verify OK: {} bytes", total_bytes));
                    } else {
                        self.state
                            .set_failed(format!("Verify FAILED: {} mismatches", mismatches));
                    }
                }
                WorkerMessage::BlankCheckComplete {
                    is_blank,
                    first_non_blank,
                } => {
                    if is_blank {
                        self.state.set_completed("Blank check: BLANK");
                    } else {
                        self.state.set_completed(format!(
                            "NOT blank (first at 0x{:X})",
                            first_non_blank.unwrap_or(0)
                        ));
                    }
                }
                WorkerMessage::PartitionSet(id) => {
                    self.state.active_partition = id;
                    let names = ["user", "boot0", "boot1", "RPMB"];
                    let name = names.get(id as usize).unwrap_or(&"?");
                    self.state.set_completed(format!("Partition: {}", name));
                }
                WorkerMessage::ExtCsdWritten { index, value } => {
                    self.state
                        .log
                        .info(format!("ExtCSD[{}] = 0x{:02X}", index, value));
                    self.state.set_completed("ExtCSD written");
                }
                WorkerMessage::RawCmdResponse { data } => {
                    let hex: Vec<String> =
                        data.iter().map(|b| format!("{:02X}", b)).collect();
                    self.state
                        .log
                        .info(format!("Raw CMD response: {}", hex.join(" ")));
                    self.state.set_completed("Raw command done");
                }
                WorkerMessage::SpeedSet(preset) => {
                    self.state.selected_clk_preset = preset as usize;
                    self.state.set_completed(format!("Speed preset: {}", preset));
                }
                WorkerMessage::BusWidthSet(width) => {
                    self.state.bus_width = width;
                    let name = if width == 4 { "4-bit" } else { "1-bit" };
                    self.state.set_completed(format!("Bus width: {}", name));
                }
                WorkerMessage::BaudSet { preset, baud } => {
                    self.state.selected_baud_preset = preset as usize;
                    self.state.selected_baud = baud;
                    self.state.current_baud = baud;
                    self.state
                        .set_completed(format!("Baud: {} (preset {})", baud, preset));
                }
                WorkerMessage::Reinitialized => {
                    self.state.set_completed("Re-initialized");
                }
                WorkerMessage::DumpCompleted { bytes, path } => {
                    self.state
                        .log
                        .info(format!("Dump: {} bytes -> {}", bytes, path));
                    self.state.set_completed(format!("Dump: {} bytes", bytes));
                }
                WorkerMessage::RestoreCompleted { bytes, path } => {
                    self.state
                        .log
                        .info(format!("Restore: {} bytes from {}", bytes, path));
                    self.state
                        .set_completed(format!("Restore: {} bytes", bytes));
                }
                WorkerMessage::Ext4Loaded(info) => {
                    self.state.ext4_info = Some(info);
                    self.state.set_completed("ext4 loaded");
                }
                WorkerMessage::Ext4DirListing { path, entries } => {
                    self.state.ext4_current_path = path;
                    self.state.ext4_entries = entries;
                    self.state.ext4_file_content = None;
                    self.state.ext4_file_path = None;
                    self.state.set_completed("Directory listed");
                }
                WorkerMessage::Ext4FileContent { path, data } => {
                    let len = data.len();
                    self.state.ext4_file_path = Some(path.clone());
                    self.state.ext4_file_content = Some(data);
                    self.state
                        .set_completed(format!("Read {} ({} bytes)", path, len));
                }
                WorkerMessage::Ext4FileWritten { path } => {
                    self.state
                        .log
                        .info(format!("Overwritten: {}", path));
                    self.state.set_completed("File overwritten");
                }
                WorkerMessage::Ext4FileCreated { path } => {
                    self.state
                        .log
                        .info(format!("Created: {}", path));
                    self.state.set_completed("File created");
                }
                WorkerMessage::Ext4SearchDone { query, results } => {
                    let count = results.len();
                    self.state.ext4_search_results = results;
                    self.state.set_completed(format!(
                        "Search '{}': {} results",
                        query, count
                    ));
                }
                WorkerMessage::Progress(progress) => {
                    self.state.operation_progress = Some(progress);
                }
                WorkerMessage::Completed(msg) => {
                    self.state.set_completed(msg);
                }
                WorkerMessage::Error(msg) => {
                    // If connection failed before Connected message, clean up
                    if !self.state.connected {
                        self.programmer = None;
                    }
                    self.state.set_failed(msg);
                }
            }
        }
    }

    pub fn dispatch_command(&mut self, cmd: Command) {
        if cmd.is_destructive() {
            if let Some(msg) = cmd.confirm_message() {
                self.state.confirm_dialog =
                    Some(programmer_engine::state::ConfirmDialog {
                        title: cmd.label().to_string(),
                        message: msg,
                        command: cmd,
                    });
                return;
            }
        }
        self.execute_command(cmd);
    }

    pub fn execute_command(&mut self, cmd: Command) {
        let programmer = match &self.programmer {
            Some(p) => Arc::clone(p),
            None => {
                self.state.set_failed("Not connected");
                return;
            }
        };
        let tx = self.worker_tx.clone();
        let cancel = self.state.cancel_flag.clone();
        let log = self.state.log.clone();

        self.state.set_running(cmd.label());

        match cmd {
            Command::Identify => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    match prog.identify() {
                        Ok(Some(info)) => {
                            let _ = tx.send(WorkerMessage::ChipIdentified(info));
                        }
                        Ok(None) => {
                            let _ = tx.send(WorkerMessage::Error(
                                "No chip detected".into(),
                            ));
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::ReadSectors { lba, count, path } => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    let progress =
                        operations::ChannelProgress::new(tx.clone(), cancel);
                    let addr = lba as u64 * 512;
                    let len = count as u64 * 512;
                    match prog.read(addr, len, &progress) {
                        Ok(data) => {
                            if let Some(p) = path {
                                if let Err(e) = std::fs::write(&p, &data) {
                                    let _ = tx.send(WorkerMessage::Error(
                                        format!("Save failed: {}", e),
                                    ));
                                    return;
                                }
                                log.info(format!(
                                    "Saved {} bytes to {}",
                                    data.len(),
                                    p.display()
                                ));
                            }
                            let _ = tx.send(WorkerMessage::SectorsRead {
                                lba,
                                data,
                            });
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::WriteSectors { lba, path, verify } => {
                std::thread::spawn(move || {
                    let data = match std::fs::read(&path) {
                        Ok(d) => d,
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("Read file: {}", e),
                            ));
                            return;
                        }
                    };
                    let count = data.len().div_ceil(512) as u32;
                    let mut prog = programmer.lock().unwrap();
                    let progress =
                        operations::ChannelProgress::new(tx.clone(), cancel.clone());
                    let addr = lba as u64 * 512;
                    match prog.write(addr, &data, &progress) {
                        Ok(()) => {
                            let _ = tx.send(WorkerMessage::SectorsWritten {
                                lba,
                                count,
                            });
                            if verify {
                                let progress2 = operations::ChannelProgress::new(
                                    tx.clone(),
                                    cancel,
                                );
                                match prog.verify(addr, &data, &progress2) {
                                    Ok(result) => {
                                        let _ = tx.send(
                                            WorkerMessage::VerifyComplete {
                                                total_bytes: result.total_bytes,
                                                mismatches: result
                                                    .mismatches
                                                    .len(),
                                            },
                                        );
                                    }
                                    Err(e) => {
                                        let _ = tx.send(WorkerMessage::Error(
                                            format!("Verify: {}", e),
                                        ));
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::WriteSectorsData { lba, data, verify } => {
                std::thread::spawn(move || {
                    let count = data.len().div_ceil(512) as u32;
                    let mut prog = programmer.lock().unwrap();
                    let progress =
                        operations::ChannelProgress::new(tx.clone(), cancel.clone());
                    let addr = lba as u64 * 512;
                    match prog.write(addr, &data, &progress) {
                        Ok(()) => {
                            let _ = tx.send(WorkerMessage::SectorsWritten {
                                lba,
                                count,
                            });
                            if verify {
                                let progress2 = operations::ChannelProgress::new(
                                    tx.clone(),
                                    cancel,
                                );
                                match prog.verify(addr, &data, &progress2) {
                                    Ok(result) => {
                                        let _ = tx.send(
                                            WorkerMessage::VerifyComplete {
                                                total_bytes: result.total_bytes,
                                                mismatches: result
                                                    .mismatches
                                                    .len(),
                                            },
                                        );
                                    }
                                    Err(e) => {
                                        let _ = tx.send(WorkerMessage::Error(
                                            format!("Verify: {}", e),
                                        ));
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::Erase { lba, count } => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    let progress =
                        operations::ChannelProgress::new(tx.clone(), cancel);
                    let addr = lba as u64 * 512;
                    let len = count as u64 * 512;
                    match prog.erase(addr, len, &progress) {
                        Ok(()) => {
                            let _ = tx.send(WorkerMessage::SectorsErased {
                                lba,
                                count,
                            });
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::SecureErase { lba, count } => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    if let Some(ext) = prog.extensions() {
                        // CMD35: set erase group start
                        if let Err(e) = ext.send_raw_command(35, lba, 0x01) {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("CMD35: {}", e),
                            ));
                            return;
                        }
                        // CMD36: set erase group end
                        let end_lba = lba.saturating_add(count).saturating_sub(1);
                        if let Err(e) = ext.send_raw_command(36, end_lba, 0x01) {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("CMD36: {}", e),
                            ));
                            return;
                        }
                        // CMD38 with secure erase arg
                        match ext.send_raw_command(38, 0x80000000, 0x05) {
                            Ok(_) => {
                                let _ = tx.send(WorkerMessage::SecureErased {
                                    lba,
                                    count,
                                });
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    format!("CMD38: {}", e),
                                ));
                            }
                        }
                    }
                });
            }
            Command::CardStatus => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    if let Some(ext) = prog.extensions() {
                        // CMD13 with RCA=1 (typical eMMC RCA after init)
                        match ext.send_raw_command(13, 1 << 16, 0x01) {
                            Ok(data) => {
                                let status = if data.len() >= 4 {
                                    u32::from_be_bytes([data[0], data[1], data[2], data[3]])
                                } else {
                                    0
                                };
                                let _ = tx.send(WorkerMessage::CardStatusRead(status));
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    format!("CMD13: {}", e),
                                ));
                            }
                        }
                    }
                });
            }
            Command::Verify { lba, path } => {
                std::thread::spawn(move || {
                    let expected = match std::fs::read(&path) {
                        Ok(d) => d,
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("Read file: {}", e),
                            ));
                            return;
                        }
                    };
                    let mut prog = programmer.lock().unwrap();
                    let progress =
                        operations::ChannelProgress::new(tx.clone(), cancel);
                    let addr = lba as u64 * 512;
                    match prog.verify(addr, &expected, &progress) {
                        Ok(result) => {
                            let _ = tx.send(WorkerMessage::VerifyComplete {
                                total_bytes: result.total_bytes,
                                mismatches: result.mismatches.len(),
                            });
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::BlankCheck { lba, count } => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    let progress =
                        operations::ChannelProgress::new(tx.clone(), cancel);
                    let addr = lba as u64 * 512;
                    let len = count as u64 * 512;
                    match prog.blank_check(addr, len, &progress) {
                        Ok(result) => {
                            let _ = tx.send(WorkerMessage::BlankCheckComplete {
                                is_blank: result.is_blank,
                                first_non_blank: result.first_non_blank,
                            });
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::DumpFull { path, verify } => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    // Get capacity from chip info
                    let capacity = match prog.identify() {
                        Ok(Some(info)) => info.capacity_bytes,
                        _ => {
                            let _ = tx.send(WorkerMessage::Error(
                                "Cannot determine capacity".into(),
                            ));
                            return;
                        }
                    };
                    let progress =
                        operations::ChannelProgress::new(tx.clone(), cancel.clone());
                    match prog.read(0, capacity, &progress) {
                        Ok(data) => {
                            if let Err(e) = std::fs::write(&path, &data) {
                                let _ = tx.send(WorkerMessage::Error(
                                    format!("Save: {}", e),
                                ));
                                return;
                            }
                            let bytes = data.len() as u64;
                            let _ = tx.send(WorkerMessage::DumpCompleted {
                                bytes,
                                path: path.display().to_string(),
                            });
                            if verify {
                                let progress2 = operations::ChannelProgress::new(
                                    tx.clone(),
                                    cancel,
                                );
                                match prog.verify(0, &data, &progress2) {
                                    Ok(result) => {
                                        let _ = tx.send(
                                            WorkerMessage::VerifyComplete {
                                                total_bytes: result.total_bytes,
                                                mismatches: result
                                                    .mismatches
                                                    .len(),
                                            },
                                        );
                                    }
                                    Err(e) => {
                                        log.warn(format!("Dump verify: {}", e));
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::RestoreFull { path, verify } => {
                std::thread::spawn(move || {
                    let data = match std::fs::read(&path) {
                        Ok(d) => d,
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("Read: {}", e),
                            ));
                            return;
                        }
                    };
                    let mut prog = programmer.lock().unwrap();
                    let progress =
                        operations::ChannelProgress::new(tx.clone(), cancel.clone());
                    match prog.write(0, &data, &progress) {
                        Ok(()) => {
                            let bytes = data.len() as u64;
                            let _ = tx.send(WorkerMessage::RestoreCompleted {
                                bytes,
                                path: path.display().to_string(),
                            });
                            if verify {
                                let progress2 = operations::ChannelProgress::new(
                                    tx.clone(),
                                    cancel,
                                );
                                match prog.verify(0, &data, &progress2) {
                                    Ok(result) => {
                                        let _ = tx.send(
                                            WorkerMessage::VerifyComplete {
                                                total_bytes: result.total_bytes,
                                                mismatches: result
                                                    .mismatches
                                                    .len(),
                                            },
                                        );
                                    }
                                    Err(e) => {
                                        log.warn(format!(
                                            "Restore verify: {}",
                                            e
                                        ));
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::SetPartition(id) => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    if let Some(ext) = prog.extensions() {
                        match ext.set_partition(id) {
                            Ok(()) => {
                                let _ =
                                    tx.send(WorkerMessage::PartitionSet(id));
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    e.to_string(),
                                ));
                            }
                        }
                    }
                });
            }
            Command::ReadExtCsd => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    if let Some(ext) = prog.extensions() {
                        match ext.read_ext_csd() {
                            Ok(data) => {
                                let _ =
                                    tx.send(WorkerMessage::ExtCsdRead(data));
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    e.to_string(),
                                ));
                            }
                        }
                    }
                });
            }
            Command::WriteExtCsd { index, value } => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    if let Some(ext) = prog.extensions() {
                        // CMD6 SWITCH: arg = (3 << 24) | (index << 16) | (value << 8)
                        let arg = (3u32 << 24) | ((index as u32) << 16) | ((value as u32) << 8);
                        // flags: has_response=1, busy_wait=4 → 0x05
                        match ext.send_raw_command(6, arg, 0x05) {
                            Ok(_) => {
                                let _ = tx.send(WorkerMessage::ExtCsdWritten {
                                    index,
                                    value,
                                });
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    format!("WriteExtCsd: {}", e),
                                ));
                            }
                        }
                    }
                });
            }
            Command::SendRawCmd { index, arg, flags } => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    if let Some(ext) = prog.extensions() {
                        match ext.send_raw_command(index, arg, flags) {
                            Ok(data) => {
                                let _ = tx.send(WorkerMessage::RawCmdResponse {
                                    data,
                                });
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    e.to_string(),
                                ));
                            }
                        }
                    }
                });
            }
            Command::SetSpeed(preset) => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    if let Some(ext) = prog.extensions() {
                        match ext.set_speed(preset) {
                            Ok(()) => {
                                let _ =
                                    tx.send(WorkerMessage::SpeedSet(preset));
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    e.to_string(),
                                ));
                            }
                        }
                    }
                });
            }
            Command::ControllerStatus => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    match prog.connection().get_status() {
                        Ok(status) => {
                            let _ = tx.send(WorkerMessage::ControllerStatusRead(status));
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("Controller status: {}", e),
                            ));
                        }
                    }
                });
            }
            Command::SetBusWidth(width) => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    if let Some(ext) = prog.extensions() {
                        match ext.set_bus_width(width) {
                            Ok(()) => {
                                let _ =
                                    tx.send(WorkerMessage::BusWidthSet(width));
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    e.to_string(),
                                ));
                            }
                        }
                    }
                });
            }
            Command::SetBaud(preset) => {
                let baud_rates = [3_000_000u32, 6_000_000, 7_500_000, 12_000_000];
                let baud = baud_rates
                    .get(preset as usize)
                    .copied()
                    .unwrap_or(3_000_000);
                std::thread::spawn(move || {
                    let port_name;
                    {
                        let mut prog = programmer.lock().unwrap();
                        port_name = prog.port_name().to_string();
                        if let Some(ext) = prog.extensions() {
                            if let Err(e) = ext.set_baud(preset) {
                                let _ = tx.send(WorkerMessage::Error(
                                    e.to_string(),
                                ));
                                return;
                            }
                        }
                    }
                    // FPGA switched baud — reconnect serial port at new rate
                    std::thread::sleep(std::time::Duration::from_millis(100));
                    match FpgaUartProgrammer::connect(&port_name, baud) {
                        Ok(new_prog) => {
                            *programmer.lock().unwrap() = new_prog;
                            let _ = tx.send(WorkerMessage::BaudSet {
                                preset,
                                baud,
                            });
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("Reconnect at {}: {}", baud, e),
                            ));
                        }
                    }
                });
            }
            Command::Reinit => {
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    if let Some(ext) = prog.extensions() {
                        match ext.reinit() {
                            Ok(()) => {
                                let _ =
                                    tx.send(WorkerMessage::Reinitialized);
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    e.to_string(),
                                ));
                            }
                        }
                    }
                });
            }
            Command::HexWriteBack { lba, data } => {
                std::thread::spawn(move || {
                    let count = data.len().div_ceil(512) as u32;
                    let mut prog = programmer.lock().unwrap();
                    let progress =
                        operations::ChannelProgress::new(tx.clone(), cancel);
                    let addr = lba as u64 * 512;
                    match prog.write(addr, &data, &progress) {
                        Ok(()) => {
                            let _ = tx.send(WorkerMessage::SectorsWritten {
                                lba,
                                count,
                            });
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(e.to_string()));
                        }
                    }
                });
            }
            Command::Ext4Load { partition_lba } => {
                log.info(format!("ext4: Loading partition at LBA {}", partition_lba));
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    let conn = prog.connection();
                    log.info("ext4: Opening filesystem (reading superblock + group descriptors)...");
                    match Ext4Fs::open(conn, partition_lba) {
                        Ok(mut fs) => {
                            let info = convert_ext4_info(&fs.info());
                            log.info(format!(
                                "ext4: Opened '{}', block_size={}, blocks={}, inodes={}",
                                info.volume_name, info.block_size, info.block_count, info.inode_count
                            ));
                            let entries = fs.ls("/").ok().map(|e| convert_ext4_entries(&e));
                            let _ = tx.send(WorkerMessage::Ext4Loaded(info));
                            if let Some(ref entries) = entries {
                                log.info(format!("ext4: Root directory: {} entries", entries.len()));
                                let _ = tx.send(WorkerMessage::Ext4DirListing {
                                    path: "/".into(),
                                    entries: entries.clone(),
                                });
                            }
                        }
                        Err(e) => {
                            log.error(format!("ext4: Failed to open at LBA {}: {}", partition_lba, e));
                            let _ = tx.send(WorkerMessage::Error(
                                format!("ext4 open: {}", e),
                            ));
                        }
                    }
                });
            }
            Command::Ext4Navigate { path } => {
                let partition_lba = self.state.ext4_partition_lba.unwrap_or(0);
                log.info(format!("ext4: Navigate to '{}'", path));
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    let conn = prog.connection();
                    match Ext4Fs::open(conn, partition_lba) {
                        Ok(mut fs) => match fs.ls(&path) {
                            Ok(entries) => {
                                log.info(format!("ext4: ls '{}': {} entries", path, entries.len()));
                                let _ = tx.send(WorkerMessage::Ext4DirListing {
                                    path,
                                    entries: convert_ext4_entries(&entries),
                                });
                            }
                            Err(e) => {
                                log.error(format!("ext4: ls '{}' failed: {}", path, e));
                                let _ = tx.send(WorkerMessage::Error(
                                    format!("ls {}: {}", path, e),
                                ));
                            }
                        },
                        Err(e) => {
                            log.error(format!("ext4: re-open failed at LBA {}: {}", partition_lba, e));
                            let _ = tx.send(WorkerMessage::Error(
                                format!("ext4 open: {}", e),
                            ));
                        }
                    }
                });
            }
            Command::Ext4ReadFile { path } => {
                let partition_lba = self.state.ext4_partition_lba.unwrap_or(0);
                log.info(format!("ext4: Reading file '{}'", path));
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    let conn = prog.connection();
                    match Ext4Fs::open(conn, partition_lba) {
                        Ok(mut fs) => match fs.cat(&path) {
                            Ok(data) => {
                                log.info(format!("ext4: Read '{}' ({} bytes)", path, data.len()));
                                let _ = tx.send(WorkerMessage::Ext4FileContent {
                                    path,
                                    data,
                                });
                            }
                            Err(e) => {
                                log.error(format!("ext4: cat '{}' failed: {}", path, e));
                                let _ = tx.send(WorkerMessage::Error(
                                    format!("cat {}: {}", path, e),
                                ));
                            }
                        },
                        Err(e) => {
                            log.error(format!("ext4: re-open failed: {}", e));
                            let _ = tx.send(WorkerMessage::Error(
                                format!("ext4 open: {}", e),
                            ));
                        }
                    }
                });
            }
            Command::Ext4OverwriteFile { ext4_path, local_path } => {
                let partition_lba = self.state.ext4_partition_lba.unwrap_or(0);
                std::thread::spawn(move || {
                    let new_data = match std::fs::read(&local_path) {
                        Ok(d) => d,
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("Read local file: {}", e),
                            ));
                            return;
                        }
                    };
                    let mut prog = programmer.lock().unwrap();
                    let conn = prog.connection();
                    match Ext4Fs::open(conn, partition_lba) {
                        Ok(mut fs) => {
                            match fs.lookup(&ext4_path) {
                                Ok(inode) => {
                                    match fs.overwrite_file_data(&inode, &new_data) {
                                        Ok(()) => {
                                            let _ = tx.send(
                                                WorkerMessage::Ext4FileWritten {
                                                    path: ext4_path,
                                                },
                                            );
                                        }
                                        Err(e) => {
                                            let _ = tx.send(WorkerMessage::Error(
                                                format!("overwrite {}: {}", ext4_path, e),
                                            ));
                                        }
                                    }
                                }
                                Err(e) => {
                                    let _ = tx.send(WorkerMessage::Error(
                                        format!("lookup {}: {}", ext4_path, e),
                                    ));
                                }
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("ext4 open: {}", e),
                            ));
                        }
                    }
                });
            }
            Command::Ext4CreateFile { parent_path, name, data } => {
                let partition_lba = self.state.ext4_partition_lba.unwrap_or(0);
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    let conn = prog.connection();
                    match Ext4Fs::open(conn, partition_lba) {
                        Ok(mut fs) => {
                            let full_path = if parent_path == "/" {
                                format!("/{}", name)
                            } else {
                                format!("{}/{}", parent_path, name)
                            };
                            match fs.create_file(&parent_path, &name, &data) {
                                Ok(_ino) => {
                                    let _ = tx.send(WorkerMessage::Ext4FileCreated {
                                        path: full_path,
                                    });
                                }
                                Err(e) => {
                                    let _ = tx.send(WorkerMessage::Error(
                                        format!("create {}: {}", full_path, e),
                                    ));
                                }
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("ext4 open: {}", e),
                            ));
                        }
                    }
                });
            }
            Command::Ext4Search { query } => {
                let partition_lba = self.state.ext4_partition_lba.unwrap_or(0);
                std::thread::spawn(move || {
                    let mut prog = programmer.lock().unwrap();
                    let conn = prog.connection();
                    match Ext4Fs::open(conn, partition_lba) {
                        Ok(mut fs) => {
                            let mut results = Vec::new();
                            let query_lower = query.to_lowercase();
                            let mut stack = vec!["/".to_string()];
                            while let Some(dir) = stack.pop() {
                                if cancel.load(Ordering::Relaxed) {
                                    break;
                                }
                                if let Ok(entries) = fs.ls(&dir) {
                                    for entry in &entries {
                                        if entry.name == "." || entry.name == ".." {
                                            continue;
                                        }
                                        let full = if dir == "/" {
                                            format!("/{}", entry.name)
                                        } else {
                                            format!("{}/{}", dir, entry.name)
                                        };
                                        if entry.name.to_lowercase().contains(&query_lower) {
                                            results.push(Ext4SearchResult {
                                                path: full.clone(),
                                                file_type: entry.file_type,
                                            });
                                        }
                                        if entry.file_type == 2 {
                                            stack.push(full);
                                        }
                                    }
                                }
                            }
                            let _ = tx.send(WorkerMessage::Ext4SearchDone {
                                query,
                                results,
                            });
                        }
                        Err(e) => {
                            let _ = tx.send(WorkerMessage::Error(
                                format!("ext4 open: {}", e),
                            ));
                        }
                    }
                });
            }
        }
    }

    fn dispatch_pending_command(&mut self) {
        if let Some(cmd) = self.state.pending_command.take() {
            self.execute_command(cmd);
        }
    }

    fn handle_hotkeys(&mut self, ctx: &egui::Context) {
        ctx.input(|i| {
            if i.modifiers.ctrl {
                if i.key_pressed(egui::Key::Num1) {
                    self.state.active_tab = ActiveTab::ChipInfo;
                } else if i.key_pressed(egui::Key::Num2) {
                    self.state.active_tab = ActiveTab::Operations;
                } else if i.key_pressed(egui::Key::Num3) {
                    self.state.active_tab = ActiveTab::Partitions;
                } else if i.key_pressed(egui::Key::Num4) {
                    self.state.active_tab = ActiveTab::HexEditor;
                } else if i.key_pressed(egui::Key::Num5) {
                    self.state.active_tab = ActiveTab::Filesystem;
                } else if i.key_pressed(egui::Key::Num6) {
                    self.state.active_tab = ActiveTab::ImageManager;
                } else if i.key_pressed(egui::Key::L) {
                    self.state.show_log = !self.state.show_log;
                } else if i.key_pressed(egui::Key::Z) {
                    if self.state.active_tab == ActiveTab::HexEditor {
                        self.state.hex_undo();
                    }
                } else if i.key_pressed(egui::Key::Y)
                    && self.state.active_tab == ActiveTab::HexEditor {
                        self.state.hex_redo();
                    }
            }
            if i.key_pressed(egui::Key::Escape) && self.state.is_busy() {
                self.state.cancel_operation();
            }
        });
    }

    pub fn do_connect(&mut self) {
        let port = if self.state.use_fifo {
            "fifo://".to_string()
        } else {
            self.state.selected_port.clone()
        };
        let is_fifo = self.state.use_fifo;
        let target_baud = self.state.speed_profile.target_baud();
        let baud_preset = self.state.speed_profile.baud_preset();
        let clk_preset = self.state.speed_profile.clk_preset();
        let bus_width = self.state.bus_width;
        let tx = self.worker_tx.clone();
        let log = self.state.log.clone();

        let clk_names = ["2 MHz", "3.75 MHz", "6 MHz", "10 MHz", "15 MHz", "15 MHz", "30 MHz"];
        let clk_name = clk_names.get(clk_preset as usize).unwrap_or(&"?");
        log.info(format!(
            "Connecting: transport={}, target_clock={} (preset {}), baud={} (preset {}), bus_width={}",
            if is_fifo { "FIFO" } else { "UART" },
            clk_name, clk_preset, target_baud, baud_preset, bus_width
        ));

        self.state.set_running("Connecting...");

        // Connect synchronously: FIFO uses "fifo://" sentinel, UART uses 3M baud
        let initial_baud = if is_fifo { 0 } else { 3_000_000 };
        let prog = match FpgaUartProgrammer::connect(&port, initial_baud) {
            Ok(p) => p,
            Err(e) => {
                self.state.set_failed(format!("Connect: {}", e));
                return;
            }
        };

        let programmer = Arc::new(Mutex::new(prog));
        self.programmer = Some(Arc::clone(&programmer));

        // Ping + speed negotiation in background thread
        std::thread::spawn(move || {
            // Ping to verify connection
            {
                let mut p = programmer.lock().unwrap();
                if let Err(e) = p.connection().ping() {
                    let _ = tx.send(WorkerMessage::Error(
                        format!("Ping: {}", e),
                    ));
                    return;
                }
            }

            // Speed negotiation
            if clk_preset > 0 || (!is_fifo && baud_preset > 0) {
                let mut p = programmer.lock().unwrap();
                // Set eMMC clock first
                if clk_preset > 0 {
                    if let Err(e) = p.connection().set_clk_speed(clk_preset) {
                        log.warn(format!("Set clock: {}", e));
                    }
                }
                // Set baud (UART only — FIFO set_baud is a no-op)
                if !is_fifo && baud_preset > 0 {
                    if let Err(e) = p.connection().set_baud(baud_preset) {
                        log.warn(format!("Set baud: {}", e));
                    } else {
                        drop(p);
                        // Wait for FPGA to switch baud
                        std::thread::sleep(std::time::Duration::from_millis(100));
                        // Reconnect serial port at new baud, replace in shared Arc
                        match FpgaUartProgrammer::connect(&port, target_baud) {
                            Ok(new_prog) => {
                                *programmer.lock().unwrap() = new_prog;
                            }
                            Err(e) => {
                                let _ = tx.send(WorkerMessage::Error(
                                    format!("Reconnect at {}: {}", target_baud, e),
                                ));
                                return;
                            }
                        }
                    }
                }
            }

            let actual_baud = if is_fifo {
                0
            } else if baud_preset > 0 {
                target_baud
            } else {
                3_000_000
            };
            let _ = tx.send(WorkerMessage::ConnectedWithSpeed {
                actual_baud,
                baud_preset,
                clk_preset,
            });
        });
    }

    pub fn do_disconnect(&mut self) {
        self.programmer = None;
        self.state.connected = false;
        self.state.chip_info = None;
        self.state.ext_csd_raw = None;
        self.state.ext_csd_parsed = None;
        self.state.card_status_raw = None;
        self.state.controller_status = None;
        self.state.active_partition = 0;
        self.state.partition_data = None;
        self.state.hex_data.clear();
        self.state.hex_source_lba = None;
        self.state.hex_modified.clear();
        self.state.hex_undo_stack.clear();
        self.state.hex_redo_stack.clear();
        self.state.ext4_info = None;
        self.state.ext4_entries.clear();
        self.state.ext4_file_content = None;
        self.state.ext4_file_path = None;
        self.state.ext4_partition_lba = None;
        self.state.ext4_search_results.clear();
        self.state.set_completed("Disconnected");
    }
}

impl eframe::App for ProgrammerApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.process_messages();
        self.dispatch_pending_command();
        self.handle_hotkeys(ctx);

        if self.state.is_busy() {
            ctx.request_repaint_after(std::time::Duration::from_millis(100));
        }

        // Top menu bar
        egui::TopBottomPanel::top("menu_bar").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.menu_button("File", |ui| {
                    if ui.button("Quit").clicked() {
                        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                    }
                });
                ui.menu_button("View", |ui| {
                    ui.checkbox(&mut self.state.show_log, "Show Log (Ctrl+L)");
                });
            });
        });

        // Status bar
        egui::TopBottomPanel::bottom("status_bar")
            .exact_height(theme::STATUS_BAR_HEIGHT)
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    match &self.state.operation_status {
                        OperationStatus::Idle => {
                            ui.label("Ready");
                        }
                        OperationStatus::Running(desc) => {
                            ui.spinner();
                            ui.label(desc);
                        }
                        OperationStatus::Completed(msg) => {
                            ui.colored_label(
                                theme::COLOR_SUCCESS,
                                format!("OK: {}", msg),
                            );
                        }
                        OperationStatus::Failed(msg) => {
                            ui.colored_label(
                                theme::COLOR_ERROR,
                                format!("Error: {}", msg),
                            );
                        }
                    }

                    if let Some(progress) = &self.state.operation_progress {
                        ui.separator();
                        ui.add(
                            egui::ProgressBar::new(progress.fraction())
                                .text(&progress.description),
                        );
                        if self.state.is_busy()
                            && ui.small_button("Cancel").clicked()
                        {
                            self.state.cancel_operation();
                        }
                    }
                });
            });

        // Log panel
        if self.state.show_log {
            egui::TopBottomPanel::bottom("log_panel")
                .resizable(true)
                .min_height(theme::LOG_MIN_HEIGHT)
                .default_height(theme::LOG_DEFAULT_HEIGHT)
                .show(ctx, |ui| {
                    panels::log::show_log_panel(ui, &self.state);
                });
        }

        // Confirm dialog
        panels::confirm::show_confirm_dialog(ctx, &mut self.state);

        // Sidebar
        egui::SidePanel::left("sidebar")
            .resizable(true)
            .default_width(theme::SIDEBAR_WIDTH)
            .min_width(theme::SIDEBAR_MIN_WIDTH)
            .show(ctx, |ui| {
                panels::connection::show_connection_panel(ui, self);
            });

        // Central panel with tabs
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.horizontal(|ui| {
                for (i, tab) in ActiveTab::all().iter().enumerate() {
                    let selected = self.state.active_tab == *tab;
                    let resp = ui.selectable_label(selected, tab.label());
                    if resp.clicked() {
                        self.state.active_tab = *tab;
                    }
                    resp.on_hover_text(format!("Ctrl+{}", i + 1));
                }
            });
            ui.separator();

            egui::ScrollArea::vertical()
                .auto_shrink([false; 2])
                .show(ui, |ui| match self.state.active_tab {
                    ActiveTab::ChipInfo => {
                        panels::chip_info::show_chip_info_panel(ui, self);
                    }
                    ActiveTab::Operations => {
                        panels::operations::show_operations_panel(ui, self);
                    }
                    ActiveTab::Partitions => {
                        panels::partitions::show_partitions_panel(ui, self);
                    }
                    ActiveTab::HexEditor => {
                        panels::hex_editor::show_hex_editor_panel(ui, self);
                    }
                    ActiveTab::Filesystem => {
                        panels::filesystem::show_filesystem_panel(ui, self);
                    }
                    ActiveTab::ImageManager => {
                        panels::image_manager::show_image_manager_panel(
                            ui, self,
                        );
                    }
                });
        });
    }
}
