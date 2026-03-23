use crossbeam_channel::{unbounded, Receiver, Sender};
use eframe::egui;
use emmc_app::operations::{self, WorkerMessage};
use emmc_app::state::{ActiveTab, AppState, OperationStatus};

use crate::theme;

use crate::panels;

pub struct EmmcApp {
    pub state: AppState,
    pub worker_tx: Sender<WorkerMessage>,
    pub worker_rx: Receiver<WorkerMessage>,
    /// Tracks last activity time for UI-driven keepalive
    pub last_activity: std::time::Instant,
    /// True while a keepalive ping is in-flight (prevents double-fire)
    pub keepalive_pending: bool,
}

impl EmmcApp {
    pub fn new(_cc: &eframe::CreationContext<'_>) -> Self {
        let (tx, rx) = unbounded();
        let state = AppState::new();
        state.log.info("eMMC Card Reader started");

        // Auto-scan ports and FIFO devices
        emmc_app::operations::scan_ports(tx.clone(), state.log.clone());
        emmc_app::operations::scan_fifo_devices(tx.clone(), state.log.clone());

        Self {
            state,
            worker_tx: tx,
            worker_rx: rx,
            last_activity: std::time::Instant::now(),
            keepalive_pending: false,
        }
    }

    fn process_messages(&mut self) {
        while let Ok(msg) = self.worker_rx.try_recv() {
            // Any message means activity on the port — reset keepalive timer
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
                    // Auto-select FIFO if available and no port selected
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
                    actual_emmc_freq,
                    baud_preset,
                    clk_preset,
                } => {
                    self.state.connected = true;
                    self.state.selected_baud = actual_baud;
                    self.state.current_baud = actual_baud;
                    self.state.current_emmc_freq = actual_emmc_freq;
                    self.state.selected_baud_preset = baud_preset as usize;
                    self.state.selected_clk_preset = clk_preset as usize;
                    let clk_name = emmc_core::protocol::EMMC_CLK_FREQS
                        .get(clk_preset as usize)
                        .map(|f| format!("{} MHz", f / 1_000_000))
                        .unwrap_or_else(|| "2 MHz".to_string());
                    self.last_activity = std::time::Instant::now();
                    let transport = if self.state.use_fifo { "FIFO" } else { "UART" };
                    self.state.log.info(format!(
                        "Connected: transport={}, clock={}, baud={}",
                        transport, clk_name, actual_baud
                    ));
                    if self.state.use_fifo {
                        self.state.set_completed(format!(
                            "Connected (FIFO, eMMC: {})",
                            clk_name
                        ));
                    } else {
                        let baud_name = match actual_baud {
                            12_000_000 => "12M",
                            6_000_000 => "6M",
                            _ => "3M",
                        };
                        self.state.set_completed(format!(
                            "Connected (UART: {}, eMMC: {})",
                            baud_name, clk_name
                        ));
                    }
                }
                WorkerMessage::CardInfo { cid, csd } => {
                    self.state.cid_info = Some(cid);
                    self.state.csd_info = Some(csd);
                }
                WorkerMessage::ExtCsd(info) => {
                    self.state.ext_csd_info = Some(info);
                    self.state.set_completed("ExtCSD read");
                }
                WorkerMessage::SectorsRead { lba, data } => {
                    self.state.sector_data = data;
                    self.state.sector_source_lba = lba;
                    self.state.set_completed("Sectors read");
                }
                WorkerMessage::SectorsWritten { lba, count } => {
                    self.state
                        .log
                        .info(format!("Written {} sector(s) at LBA {}", count, lba));
                    self.state.set_completed("Sectors written");
                }
                WorkerMessage::SectorsErased { lba, count } => {
                    self.state
                        .log
                        .info(format!("Erased {} sector(s) at LBA {}", count, lba));
                    self.state.set_completed("Sectors erased");
                }
                WorkerMessage::SectorsSecureErased { lba, count } => {
                    self.state
                        .log
                        .info(format!("Secure erased {} sector(s) at LBA {}", count, lba));
                    self.state.set_completed("Sectors secure erased");
                }
                WorkerMessage::SectorsVerified(report) => {
                    self.state.verify_result = Some(report);
                    self.state.set_completed("Verify complete");
                }
                WorkerMessage::ExtCsdWritten { index, value } => {
                    self.state
                        .log
                        .info(format!("ExtCSD[{}] = 0x{:02X} written", index, value));
                    self.state.set_completed("ExtCSD written");
                }
                WorkerMessage::CacheFlushed => {
                    self.state.log.info("Cache flushed".to_string());
                    self.state.set_completed("Cache flushed");
                }
                WorkerMessage::Reinitialized => {
                    self.state.set_completed("Re-initialized");
                }
                WorkerMessage::BusWidthSet(width) => {
                    self.state.bus_width = width;
                    let name = if width == 4 { "4-bit" } else { "1-bit" };
                    self.state.set_completed(format!("Bus width: {}", name));
                }
                WorkerMessage::ClkSpeedSet(preset) => {
                    self.state.selected_clk_preset = preset as usize;
                    if let Some(&freq) = emmc_core::protocol::EMMC_CLK_FREQS.get(preset as usize) {
                        self.state.current_emmc_freq = freq;
                    }
                    let names = [
                        "2 MHz", "3.75 MHz", "6 MHz", "10 MHz", "15 MHz", "15 MHz", "30 MHz",
                    ];
                    let name = names.get(preset as usize).unwrap_or(&"?");
                    self.state.set_completed(format!("Clock: {}", name));
                }
                WorkerMessage::BaudPresetSet { preset, baud } => {
                    self.state.selected_baud_preset = preset as usize;
                    self.state.selected_baud = baud;
                    self.state.current_baud = baud;
                    let names = ["3 Mbaud", "6 Mbaud", "7.5 Mbaud", "12 Mbaud"];
                    let name = names.get(preset as usize).unwrap_or(&"?");
                    self.state.set_completed(format!("UART: {}", name));
                }
                WorkerMessage::RawCmdResponse { status, data } => {
                    let status_str = emmc_core::protocol::status_name(status);
                    let hex = data
                        .iter()
                        .map(|b| format!("{:02X}", b))
                        .collect::<Vec<_>>()
                        .join(" ");
                    let result = format!(
                        "Status: {} (0x{:02X})\nData ({} bytes): {}",
                        status_str,
                        status,
                        data.len(),
                        hex
                    );
                    self.state.raw_cmd_result = Some(result.clone());
                    self.state.log.info(format!("Raw CMD: {}", result));
                    self.state.set_completed("Raw command done");
                }
                WorkerMessage::ControllerStatusReceived(cs) => {
                    // Sync UI presets from FPGA actual state
                    self.state.selected_clk_preset = cs.clk_preset as usize;
                    self.state.selected_baud_preset = cs.baud_preset as usize;
                    if let Some(&freq) =
                        emmc_core::protocol::EMMC_CLK_FREQS.get(cs.clk_preset as usize)
                    {
                        self.state.current_emmc_freq = freq;
                    }
                    if let Some(&baud) =
                        emmc_core::protocol::UART_BAUD_RATES.get(cs.baud_preset as usize)
                    {
                        self.state.current_baud = baud;
                    }
                    self.state.controller_status = Some(cs);
                    self.state.set_completed("Controller status read");
                }
                WorkerMessage::CardStatus(cs) => {
                    let state = (cs >> 9) & 0xF;
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
                        _ => "?",
                    };
                    self.state.log.info(format!(
                        "Card Status: 0x{:08X} state={} ready={}",
                        cs,
                        state_name,
                        (cs >> 8) & 1
                    ));
                    self.state.set_completed("Card status read");
                }
                WorkerMessage::PartitionsRead(pt) => {
                    self.state
                        .log
                        .info(format!("{} partition(s)", pt.partitions.len()));
                    self.state.partition_table = Some(pt);
                    self.state.set_completed("Partitions loaded");
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
                    self.state.ext4_file_path = Some(path);
                    self.state.ext4_file_content = Some(data);
                    self.state.set_completed("File read");
                }
                WorkerMessage::Ext4Written { path } => {
                    self.state.log.info(format!("Written: {}", path));
                    self.state.set_completed("File written");
                }
                WorkerMessage::Ext4Created { path } => {
                    self.state.log.info(format!("Created: {}", path));
                    self.state.set_completed("File created");
                }
                WorkerMessage::RpmbCounterRead {
                    counter,
                    mac_valid,
                    result_code,
                } => {
                    self.state.rpmb_counter_result = Some(format!(
                        "Counter: {}\nResult: {} (0x{:04X})\nMAC: {}",
                        counter,
                        emmc_core::rpmb::result_name(result_code),
                        result_code,
                        if mac_valid { "VALID" } else { "INVALID" }
                    ));
                    self.state.set_completed("RPMB counter read");
                }
                WorkerMessage::RpmbDataRead {
                    address,
                    data,
                    mac_valid,
                    result_code,
                } => {
                    self.state.rpmb_data_result = Some(format!(
                        "Address: {}\nResult: {} (0x{:04X})\nMAC: {}\nData: {} bytes",
                        address,
                        emmc_core::rpmb::result_name(result_code),
                        result_code,
                        if mac_valid { "VALID" } else { "INVALID" },
                        data.len()
                    ));
                    self.state.rpmb_data_bytes = Some(data);
                    self.state.set_completed("RPMB data read");
                }
                WorkerMessage::Progress(progress) => {
                    self.state.operation_progress = Some(progress);
                }
                WorkerMessage::DumpCompleted { bytes, path } => {
                    self.state
                        .log
                        .info(format!("Dump complete: {} bytes -> {}", bytes, path));
                    self.state.set_completed(format!("Dump: {} bytes", bytes));
                }
                WorkerMessage::RestoreCompleted { bytes, path } => {
                    self.state
                        .log
                        .info(format!("Restore complete: {} bytes from {}", bytes, path));
                    self.state
                        .set_completed(format!("Restore: {} bytes", bytes));
                }
                WorkerMessage::WriteVerified {
                    mismatches,
                    total_sectors,
                } => {
                    if mismatches.is_empty() {
                        self.state
                            .log
                            .info(format!("Verify OK: all {} sectors match", total_sectors));
                        self.state.set_completed("Write verify OK");
                    } else {
                        let lba_list: Vec<String> =
                            mismatches.iter().map(|lba| lba.to_string()).collect();
                        self.state.log.error(format!(
                            "Verify FAILED: {} mismatch(es) at LBAs: {}",
                            mismatches.len(),
                            lba_list.join(", ")
                        ));
                        self.state.set_failed(format!(
                            "Verify failed: {} sector(s) differ",
                            mismatches.len()
                        ));
                    }
                }
                WorkerMessage::DumpVerified {
                    mismatches,
                    total_sectors,
                } => {
                    if mismatches.is_empty() {
                        self.state.log.info(format!(
                            "Dump verify OK: all {} sectors match",
                            total_sectors
                        ));
                        self.state.set_completed("Dump verify OK");
                    } else {
                        let lba_list: Vec<String> =
                            mismatches.iter().map(|lba| lba.to_string()).collect();
                        self.state.log.warn(format!(
                            "Dump verify: {} mismatch(es) at LBAs: {} (may be breadboard noise)",
                            mismatches.len(),
                            lba_list.join(", ")
                        ));
                        self.state.set_completed(format!(
                            "Dump done ({} sector(s) differ)",
                            mismatches.len()
                        ));
                    }
                }
                WorkerMessage::Completed(msg) => {
                    self.state.set_completed(msg);
                }
                WorkerMessage::Error(msg) => {
                    self.state.set_failed(msg);
                }
                WorkerMessage::KeepaliveOk => {
                    self.keepalive_pending = false;
                }
            }
        }
    }

    fn dispatch_pending_action(&mut self) {
        let action = match self.state.pending_action.take() {
            Some(a) => a,
            None => return,
        };

        let port = self.state.effective_port();
        let baud = self.state.selected_baud;
        let tx = self.worker_tx.clone();
        let log = self.state.log.clone();

        if action.starts_with("write_sectors:") {
            let parts: Vec<&str> = action.splitn(3, ':').collect();
            if parts.len() == 3 {
                if let Ok(lba) = parts[1].parse::<u32>() {
                    let path = parts[2];
                    match std::fs::read(path) {
                        Ok(data) => {
                            self.state.set_running("Writing sectors...");
                            self.state.log.info(format!(
                                "Writing {} bytes to LBA {}...",
                                data.len(),
                                lba
                            ));
                            let verify = self.state.verify_after_write;
                            let emmc_freq = self.state.current_emmc_freq;
                            operations::write_sectors(
                                port, baud, lba, data, verify, emmc_freq, tx, log,
                            );
                        }
                        Err(e) => {
                            self.state.set_failed(format!("Read file failed: {}", e));
                        }
                    }
                }
            }
        } else if action.starts_with("restore:") {
            let path = &action[8..];
            self.state.set_running("Restoring...");
            self.state.log.info(format!("Restoring from {}...", path));
            let verify = self.state.verify_after_write;
            let emmc_freq = self.state.current_emmc_freq;
            operations::restore_from_file(
                port,
                baud,
                0,
                path.to_string(),
                verify,
                emmc_freq,
                self.state.cancel_flag.clone(),
                tx,
                log,
            );
        } else if action.starts_with("hex_write_back:") {
            if let Ok(lba) = action[15..].parse::<u32>() {
                let data = self.state.hex_data.clone();
                self.state.set_running("Writing back...");
                self.state.log.info(format!(
                    "Writing back {} bytes to LBA {}...",
                    data.len(),
                    lba
                ));
                let verify = self.state.verify_after_write;
                let emmc_freq = self.state.current_emmc_freq;
                operations::write_sectors(port, baud, lba, data, verify, emmc_freq, tx, log);
            }
        } else if action.starts_with("secure_erase:") {
            let parts: Vec<&str> = action.splitn(3, ':').collect();
            if parts.len() == 3 {
                if let (Ok(lba), Ok(count)) = (parts[1].parse::<u32>(), parts[2].parse::<u16>()) {
                    self.state.set_running("Secure erasing...");
                    operations::secure_erase_sectors(port, baud, lba, count, tx, log);
                }
            }
        } else if action.starts_with("erase:") {
            let parts: Vec<&str> = action.splitn(3, ':').collect();
            if parts.len() == 3 {
                if let (Ok(lba), Ok(count)) = (parts[1].parse::<u32>(), parts[2].parse::<u16>()) {
                    self.state.set_running("Erasing sectors...");
                    operations::erase_sectors(port, baud, lba, count, tx, log);
                }
            }
        } else if action.starts_with("write_extcsd:") {
            let parts: Vec<&str> = action.splitn(3, ':').collect();
            if parts.len() == 3 {
                if let (Ok(index), Ok(value)) = (parts[1].parse::<u8>(), parts[2].parse::<u8>()) {
                    self.state.set_running("Writing ExtCSD...");
                    operations::write_ext_csd(port, baud, index, value, tx, log);
                }
            }
        } else if action == "cache_flush" {
            self.state.set_running("Flushing cache...");
            operations::cache_flush(port, baud, tx, log);
        } else if action == "card_status" {
            self.state.set_running("Reading card status...");
            operations::get_card_status(port, baud, tx, log);
        } else if action == "controller_status" {
            self.state.set_running("Reading controller status...");
            operations::get_controller_status(port, baud, tx, log);
        } else if action == "reinit" {
            self.state.set_running("Re-initializing...");
            operations::reinit(port, baud, tx, log);
        } else if let Some(preset_str) = action.strip_prefix("set_clock:") {
            if let Ok(preset) = preset_str.parse::<u8>() {
                self.state.set_running("Setting clock speed...");
                operations::set_clk_speed(port, baud, preset, tx, log);
            }
        } else if let Some(preset_str) = action.strip_prefix("set_baud:") {
            if let Ok(preset) = preset_str.parse::<u8>() {
                self.state.set_running("Switching UART baud...");
                operations::set_baud(port, baud, preset, tx, log);
            }
        } else if let Some(width_str) = action.strip_prefix("set_bus_width:") {
            if let Ok(width) = width_str.parse::<u8>() {
                self.state.set_running("Setting bus width...");
                operations::set_bus_width(port, baud, width, tx, log);
            }
        } else if action.starts_with("ext4_write:") {
            // ext4_write:{part_lba}:{path}:{local_path}
            let parts: Vec<&str> = action.splitn(4, ':').collect();
            if parts.len() == 4 {
                if let Ok(part_lba) = parts[1].parse::<u64>() {
                    let ext4_path = parts[2].to_string();
                    let local_path = parts[3];
                    match std::fs::read(local_path) {
                        Ok(data) => {
                            self.state.set_running("Writing ext4 file...");
                            operations::ext4_write(port, baud, part_lba, ext4_path, data, tx, log);
                        }
                        Err(e) => {
                            self.state.set_failed(format!("Read file failed: {}", e));
                        }
                    }
                }
            }
        } else if action.starts_with("ext4_write_hex:") {
            // ext4_write_hex:{part_lba}:{path}
            let parts: Vec<&str> = action.splitn(3, ':').collect();
            if parts.len() == 3 {
                if let Ok(part_lba) = parts[1].parse::<u64>() {
                    let ext4_path = parts[2].to_string();
                    let data = self.state.hex_data.clone();
                    self.state.set_running("Writing ext4 file...");
                    operations::ext4_write(port, baud, part_lba, ext4_path, data, tx, log);
                }
            }
        } else if action == "set_partition_rpmb" {
            self.state.active_partition = emmc_app::state::EmmcPartition::RPMB;
            self.state.set_running("Switching to RPMB...");
            self.state
                .log
                .warn("RPMB: plain CMD17/CMD24 is a JEDEC protocol violation!");
            operations::set_partition(port, baud, 3, tx, log);
        }
    }

    fn handle_hotkeys(&mut self, ctx: &egui::Context) {
        ctx.input(|i| {
            if i.modifiers.ctrl {
                if i.key_pressed(egui::Key::Num1) {
                    self.state.active_tab = ActiveTab::EmmcInfo;
                } else if i.key_pressed(egui::Key::Num2) {
                    self.state.active_tab = ActiveTab::Sectors;
                } else if i.key_pressed(egui::Key::Num3) {
                    self.state.active_tab = ActiveTab::Partitions;
                } else if i.key_pressed(egui::Key::Num4) {
                    self.state.active_tab = ActiveTab::Ext4Browser;
                } else if i.key_pressed(egui::Key::Num5) {
                    self.state.active_tab = ActiveTab::HexEditor;
                } else if i.key_pressed(egui::Key::L) {
                    self.state.show_log = !self.state.show_log;
                }
            }
            if i.key_pressed(egui::Key::Escape) && self.state.is_busy() {
                self.state.cancel_operation();
            }
        });
    }
}

impl eframe::App for EmmcApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.process_messages();
        self.dispatch_pending_action();
        self.handle_hotkeys(ctx);

        // UI-driven keepalive: ping FPGA every ~10s when idle at non-default baud
        // to prevent baud watchdog (~18s) from resetting UART speed.
        // Race-free: only fires when !is_busy(), so no port collision with workers.
        // Not needed for FIFO transport (no baud watchdog).
        if self.state.connected
            && !self.state.use_fifo
            && self.state.selected_baud_preset > 0
            && !self.state.is_busy()
            && !self.keepalive_pending
            && self.last_activity.elapsed() > std::time::Duration::from_secs(10)
        {
            self.last_activity = std::time::Instant::now();
            self.keepalive_pending = true;
            operations::keepalive_ping(
                self.state.effective_port(),
                self.state.selected_baud,
                self.worker_tx.clone(),
                self.state.log.clone(),
            );
        }

        if self.state.is_busy()
            || (self.state.connected && !self.state.use_fifo && self.state.selected_baud_preset > 0)
        {
            // Repaint periodically: busy ops need spinner, keepalive needs timer check
            ctx.request_repaint_after(std::time::Duration::from_secs(1));
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
                    ui.checkbox(&mut self.state.show_log, "Show Log");
                });
            });
        });

        // Status bar at bottom
        egui::TopBottomPanel::bottom("status_bar")
            .exact_height(24.0)
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
                            ui.colored_label(theme::COLOR_SUCCESS, format!("OK: {}", msg));
                        }
                        OperationStatus::Failed(msg) => {
                            ui.colored_label(theme::COLOR_ERROR, format!("Error: {}", msg));
                        }
                    }

                    if let Some(progress) = &self.state.operation_progress {
                        ui.separator();
                        ui.add(
                            egui::ProgressBar::new(progress.fraction()).text(&progress.description),
                        );
                    }
                });
            });

        // Log panel (bottom, collapsible)
        if self.state.show_log {
            egui::TopBottomPanel::bottom("log_panel")
                .resizable(true)
                .min_height(80.0)
                .default_height(150.0)
                .show(ctx, |ui| {
                    panels::log::show_log_panel(ui, &mut self.state);
                });
        }

        // Confirm dialog (modal window)
        panels::confirm_dialog::show_confirm_dialog(ctx, &mut self.state);

        // Left sidebar
        egui::SidePanel::left("sidebar")
            .resizable(true)
            .default_width(200.0)
            .min_width(180.0)
            .show(ctx, |ui| {
                panels::connection::show_connection_panel(ui, &mut self.state, &self.worker_tx);
            });

        // Central panel with tabs
        egui::CentralPanel::default().show(ctx, |ui| {
            // Tab bar
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

            // Tab content (scrollable)
            egui::ScrollArea::vertical()
                .auto_shrink([false; 2])
                .show(ui, |ui| match self.state.active_tab {
                    ActiveTab::EmmcInfo => {
                        panels::card_info::show_card_info_panel(
                            ui,
                            &mut self.state,
                            &self.worker_tx,
                        );
                    }
                    ActiveTab::Sectors => {
                        panels::sector::show_sector_panel(ui, &mut self.state, &self.worker_tx);
                    }
                    ActiveTab::Partitions => {
                        panels::partition::show_partition_panel(
                            ui,
                            &mut self.state,
                            &self.worker_tx,
                        );
                    }
                    ActiveTab::Ext4Browser => {
                        panels::ext4_browser::show_ext4_panel(ui, &mut self.state, &self.worker_tx);
                    }
                    ActiveTab::HexEditor => {
                        panels::hex_editor::show_hex_editor_panel(
                            ui,
                            &mut self.state,
                            &self.worker_tx,
                        );
                    }
                });
        });
    }
}
