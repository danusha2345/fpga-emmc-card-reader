use crossbeam_channel::Sender;
use eframe::egui;
use emmc_app::operations::{self, WorkerMessage};
use emmc_app::state::{AppState, HexSource};

pub fn show_hex_editor_panel(ui: &mut egui::Ui, state: &mut AppState, tx: &Sender<WorkerMessage>) {
    ui.heading("Hex Editor");

    // Load controls
    ui.group(|ui| {
        ui.label("Load from sectors:");
        ui.horizontal(|ui| {
            ui.label("LBA:");
            ui.add(egui::TextEdit::singleline(&mut state.hex_lba_input).desired_width(100.0));
            ui.label("Count:");
            ui.add(egui::TextEdit::singleline(&mut state.hex_count_input).desired_width(60.0));

            if ui
                .add_enabled(
                    state.connected && !state.is_busy(),
                    egui::Button::new("Load"),
                )
                .clicked()
            {
                if let (Ok(lba), Ok(count)) = (
                    state.hex_lba_input.trim().parse::<u32>(),
                    state.hex_count_input.trim().parse::<u16>(),
                ) {
                    state.set_running("Loading sectors...");
                    operations::read_sectors(
                        state.effective_port(),
                        state.selected_baud,
                        lba,
                        count,
                        tx.clone(),
                        state.log.clone(),
                    );
                    // The data will arrive via SectorsRead message
                    // We need to detect it was for hex editor
                    state.hex_source = HexSource::Sectors {
                        lba: lba as u64,
                        count: count as u64,
                    };
                }
            }
        });
    });

    if state.hex_data.is_empty() {
        ui.label("No data loaded. Use 'Load' above or 'Open in Hex Editor' from other tabs.");
        return;
    }

    // Source info
    let source_text = match &state.hex_source {
        HexSource::None => "No source".to_string(),
        HexSource::Sectors { lba, count } => {
            format!(
                "Sectors: LBA {} - {} ({} sectors, {} bytes)",
                lba,
                lba + count - 1,
                count,
                state.hex_data.len()
            )
        }
        HexSource::Ext4File { path } => {
            format!("ext4 file: {} ({} bytes)", path, state.hex_data.len())
        }
    };
    ui.label(&source_text);

    // Status bar
    ui.horizontal(|ui| {
        ui.label(format!("Offset: 0x{:08X}", state.hex_cursor));
        ui.separator();
        ui.label(format!("Modified: {} bytes", state.hex_modified.len()));
        ui.separator();
        ui.label(format!("Size: {} bytes", state.hex_data.len()));
    });

    // Action buttons
    ui.horizontal(|ui| {
        // Write back
        if let HexSource::Sectors { lba, .. } = &state.hex_source {
            let lba = *lba;
            if ui
                .add_enabled(
                    !state.hex_modified.is_empty() && state.connected && !state.is_busy(),
                    egui::Button::new("Write Back to eMMC"),
                )
                .clicked()
            {
                state.confirm_dialog = Some(emmc_app::state::ConfirmDialog::new(
                    "Write Back",
                    format!(
                        "Write {} modified bytes back to LBA {}?",
                        state.hex_modified.len(),
                        lba
                    ),
                    format!("hex_write_back:{}", lba),
                ));
            }
        }

        // Save to file
        if ui.button("Save to File").clicked() {
            if let Some(path) = rfd::FileDialog::new()
                .set_title("Save hex data")
                .add_filter("Binary", &["bin", "raw"])
                .add_filter("All", &["*"])
                .save_file()
            {
                if let Err(e) = std::fs::write(&path, &state.hex_data) {
                    state.log.error(format!("Save failed: {}", e));
                } else {
                    state.log.info(format!(
                        "Saved {} bytes to {}",
                        state.hex_data.len(),
                        path.display()
                    ));
                }
            }
        }

        // Discard changes
        if ui
            .add_enabled(
                !state.hex_modified.is_empty(),
                egui::Button::new("Discard Changes"),
            )
            .clicked()
        {
            state.hex_modified.clear();
            // Reload original data
            state.log.info("Changes discarded");
        }
    });

    ui.separator();

    // Hex editor widget
    crate::widgets::hex_edit::show_hex_editor(
        ui,
        &mut state.hex_data,
        &mut state.hex_modified,
        &mut state.hex_cursor,
    );
}
