use crossbeam_channel::Sender;
use eframe::egui;
use emmc_app::operations::{self, WorkerMessage};
use emmc_app::state::{ActiveTab, AppState, HexSource};

pub fn show_sector_panel(ui: &mut egui::Ui, state: &mut AppState, tx: &Sender<WorkerMessage>) {
    ui.heading("Sector Operations");

    if !state.connected {
        ui.label("Not connected.");
        return;
    }

    // Read sectors
    ui.group(|ui| {
        ui.label("Read Sectors");
        ui.horizontal(|ui| {
            ui.label("LBA:");
            ui.add(egui::TextEdit::singleline(&mut state.sector_lba_input).desired_width(100.0));
            ui.label("Count:");
            ui.add(egui::TextEdit::singleline(&mut state.sector_count_input).desired_width(60.0));

            if ui
                .add_enabled(!state.is_busy(), egui::Button::new("Read"))
                .clicked()
            {
                if let (Ok(lba), Ok(count)) = (
                    state.sector_lba_input.trim().parse::<u32>(),
                    state.sector_count_input.trim().parse::<u16>(),
                ) {
                    state.set_running(format!("Reading {} sectors from LBA {}...", count, lba));
                    operations::read_sectors(
                        state.effective_port(),
                        state.selected_baud,
                        lba,
                        count,
                        tx.clone(),
                        state.log.clone(),
                    );
                } else {
                    state.log.error("Invalid LBA or count");
                }
            }
        });
    });

    // Show read data
    if !state.sector_data.is_empty() {
        ui.label(format!(
            "Loaded: {} bytes from LBA {} ({} sectors)",
            state.sector_data.len(),
            state.sector_source_lba,
            state.sector_data.len() / 512
        ));

        ui.horizontal(|ui| {
            if ui.button("Open in Hex Editor").clicked() {
                state.hex_data = state.sector_data.clone();
                state.hex_source = HexSource::Sectors {
                    lba: state.sector_source_lba,
                    count: state.sector_data.len() as u64 / 512,
                };
                state.hex_modified.clear();
                state.hex_cursor = 0;
                state.active_tab = ActiveTab::HexEditor;
            }
        });

        // Inline hex dump
        let hex = emmc_app::operations::hex_dump(&state.sector_data, 2048);
        egui::ScrollArea::vertical()
            .max_height(300.0)
            .show(ui, |ui| {
                ui.monospace(&hex);
            });
    }

    ui.separator();

    // Write sectors
    ui.group(|ui| {
        ui.label("Write Sectors");
        ui.horizontal(|ui| {
            ui.label("LBA:");
            ui.add(egui::TextEdit::singleline(&mut state.write_lba_input).desired_width(100.0));

            if ui
                .add_enabled(!state.is_busy(), egui::Button::new("Write from File..."))
                .clicked()
            {
                if let Ok(lba) = state.write_lba_input.trim().parse::<u32>() {
                    if let Some(path) = rfd::FileDialog::new()
                        .set_title("Select file to write")
                        .add_filter("Binary", &["bin", "img", "raw"])
                        .add_filter("All", &["*"])
                        .pick_file()
                    {
                        let path_str = path.display().to_string();
                        state.confirm_dialog = Some(emmc_app::state::ConfirmDialog::new(
                            "Write Sectors",
                            format!(
                                "Write {} to LBA {}?",
                                path.file_name().unwrap_or_default().to_string_lossy(),
                                lba
                            ),
                            format!("write_sectors:{}:{}", lba, path_str),
                        ));
                    }
                } else {
                    state.log.error("Invalid LBA");
                }
            }
        });
    });

    ui.separator();

    // Erase sectors
    ui.group(|ui| {
        ui.label("Erase Sectors");
        ui.horizontal(|ui| {
            ui.label("Uses LBA/Count from Read above.");

            if ui
                .add_enabled(!state.is_busy(), egui::Button::new("Erase"))
                .clicked()
            {
                if let (Ok(lba), Ok(count)) = (
                    state.sector_lba_input.trim().parse::<u32>(),
                    state.sector_count_input.trim().parse::<u16>(),
                ) {
                    state.confirm_dialog = Some(emmc_app::state::ConfirmDialog::new(
                        "Erase Sectors",
                        format!("Erase {} sector(s) starting at LBA {}?", count, lba),
                        format!("erase:{}:{}", lba, count),
                    ));
                } else {
                    state.log.error("Invalid LBA or count");
                }
            }

            if ui
                .add_enabled(!state.is_busy(), egui::Button::new("Secure Erase"))
                .on_hover_text("Physical overwrite (CMD38 arg=0x80000000)")
                .clicked()
            {
                if let (Ok(lba), Ok(count)) = (
                    state.sector_lba_input.trim().parse::<u32>(),
                    state.sector_count_input.trim().parse::<u16>(),
                ) {
                    state.confirm_dialog = Some(emmc_app::state::ConfirmDialog::new(
                        "Secure Erase",
                        format!("Secure erase {} sector(s) starting at LBA {}?\nPhysical overwrite guaranteed.", count, lba),
                        format!("secure_erase:{}:{}", lba, count),
                    ));
                } else {
                    state.log.error("Invalid LBA or count");
                }
            }
        });
    });

    ui.separator();

    // Write ExtCSD / Cache Flush
    ui.group(|ui| {
        ui.label("ExtCSD Write");
        ui.horizontal(|ui| {
            ui.label("Index:");
            ui.add(egui::TextEdit::singleline(&mut state.extcsd_index_input).desired_width(50.0));
            ui.label("Value:");
            ui.add(egui::TextEdit::singleline(&mut state.extcsd_value_input).desired_width(50.0));

            if ui
                .add_enabled(!state.is_busy(), egui::Button::new("Write ExtCSD"))
                .clicked()
            {
                if let (Ok(index), Ok(value)) = (
                    state.extcsd_index_input.trim().parse::<u8>(),
                    state.extcsd_value_input.trim().parse::<u8>(),
                ) {
                    state.confirm_dialog = Some(emmc_app::state::ConfirmDialog::new(
                        "Write ExtCSD",
                        format!("Write ExtCSD[{}] = 0x{:02X}?", index, value),
                        format!("write_extcsd:{}:{}", index, value),
                    ));
                } else {
                    state.log.error("Invalid index (0-255) or value (0-255)");
                }
            }

            if ui
                .add_enabled(!state.is_busy(), egui::Button::new("Cache Flush"))
                .on_hover_text("Enable cache (ExtCSD[33]=1) + flush (ExtCSD[32]=1)")
                .clicked()
            {
                state.confirm_dialog = Some(emmc_app::state::ConfirmDialog::new(
                    "Cache Flush",
                    "Enable eMMC cache and flush to flash?",
                    "cache_flush".to_string(),
                ));
            }
        });
    });

    ui.separator();

    // Verify sectors vs file
    ui.group(|ui| {
        ui.label("Verify vs File");
        ui.horizontal(|ui| {
            ui.label("LBA from Read above.");

            if ui
                .add_enabled(!state.is_busy(), egui::Button::new("Verify vs File..."))
                .clicked()
            {
                if let Ok(lba) = state.sector_lba_input.trim().parse::<u32>() {
                    if let Some(path) = rfd::FileDialog::new()
                        .set_title("Select file to verify against")
                        .add_filter("Binary", &["bin", "img", "raw"])
                        .add_filter("All", &["*"])
                        .pick_file()
                    {
                        state.set_running("Verifying...");
                        operations::verify_sectors(
                            state.effective_port(),
                            state.selected_baud,
                            state.current_emmc_freq,
                            lba,
                            path.display().to_string(),
                            state.cancel_flag.clone(),
                            tx.clone(),
                            state.log.clone(),
                        );
                    }
                } else {
                    state.log.error("Invalid LBA");
                }
            }
        });

        // Show verify result
        if let Some(result) = &state.verify_result {
            ui.separator();
            egui::ScrollArea::vertical()
                .max_height(100.0)
                .id_salt("verify_result")
                .show(ui, |ui| {
                    ui.monospace(result);
                });
        }
    });

    ui.separator();

    // Full dump
    ui.group(|ui| {
        ui.label("Full Dump / Restore");

        ui.horizontal(|ui| {
            ui.checkbox(&mut state.verify_after_write, "Verify after write/restore");
            ui.checkbox(&mut state.verify_after_dump, "Verify after dump");
        });

        ui.horizontal(|ui| {
            if ui
                .add_enabled(!state.is_busy(), egui::Button::new("Dump to File..."))
                .clicked()
            {
                if let Some(path) = rfd::FileDialog::new()
                    .set_title("Save eMMC Dump")
                    .add_filter("Binary Image", &["img", "bin", "raw"])
                    .add_filter("All", &["*"])
                    .save_file()
                {
                    let sector_count = state
                        .ext_csd_info
                        .as_ref()
                        .map(|e| e.sec_count)
                        .unwrap_or(0);

                    if sector_count == 0 {
                        state
                            .log
                            .error("Read ExtCSD first to determine sector count");
                    } else {
                        state.set_running("Dumping eMMC...");
                        operations::dump_to_file(
                            state.effective_port(),
                            state.selected_baud,
                            state.current_emmc_freq,
                            0,
                            sector_count,
                            path.display().to_string(),
                            state.verify_after_dump,
                            state.cancel_flag.clone(),
                            tx.clone(),
                            state.log.clone(),
                        );
                    }
                }
            }

            if ui
                .add_enabled(!state.is_busy(), egui::Button::new("Restore from File..."))
                .clicked()
            {
                if let Some(path) = rfd::FileDialog::new()
                    .set_title("Select image to restore")
                    .add_filter("Binary Image", &["img", "bin", "raw"])
                    .add_filter("All", &["*"])
                    .pick_file()
                {
                    let path_str = path.display().to_string();
                    state.confirm_dialog = Some(emmc_app::state::ConfirmDialog::new(
                        "Restore eMMC",
                        format!(
                            "Restore from {}? This will OVERWRITE the eMMC!",
                            path.file_name().unwrap_or_default().to_string_lossy()
                        ),
                        format!("restore:{}", path_str),
                    ));
                }
            }
        });
    });

    // Progress
    if let Some(progress) = &state.operation_progress {
        ui.add_space(8.0);
        ui.add(
            egui::ProgressBar::new(progress.fraction())
                .text(&progress.description)
                .animate(true),
        );
    }
}
