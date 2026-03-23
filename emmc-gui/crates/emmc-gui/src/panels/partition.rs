use crossbeam_channel::Sender;
use eframe::egui;
use emmc_app::operations::{self, WorkerMessage};
use emmc_app::state::{ActiveTab, AppState};
use emmc_core::partition::PartitionTableType;

pub fn show_partition_panel(ui: &mut egui::Ui, state: &mut AppState, tx: &Sender<WorkerMessage>) {
    ui.heading("Partition Table");

    if !state.connected {
        ui.label("Not connected.");
        return;
    }

    // Read partitions button
    if ui
        .add_enabled(!state.is_busy(), egui::Button::new("Read Partitions"))
        .clicked()
    {
        state.set_running("Reading partitions...");
        operations::read_partitions(
            state.effective_port(),
            state.selected_baud,
            tx.clone(),
            state.log.clone(),
        );
    }

    ui.separator();

    // Clone partition table to avoid borrow issues with closures
    let pt_clone = state.partition_table.clone();

    match pt_clone {
        None => {
            ui.label("Partition table not yet read.");
        }
        Some(pt) => {
            let type_str = match pt.table_type {
                PartitionTableType::MBR => "MBR",
                PartitionTableType::GPT => "GPT",
                PartitionTableType::Unknown => "Unknown",
                PartitionTableType::None => "None (unpartitioned)",
            };
            ui.label(format!("Table type: {}", type_str));
            ui.label(format!("Partitions: {}", pt.partitions.len()));
            ui.separator();

            if pt.partitions.is_empty() {
                ui.label("No partitions found.");
            } else {
                egui::ScrollArea::both().show(ui, |ui| {
                    egui::Grid::new("partition_table")
                        .striped(true)
                        .show(ui, |ui| {
                            // Header
                            ui.strong("#");
                            ui.strong("Name");
                            ui.strong("Type");
                            ui.strong("FS");
                            ui.strong("Start LBA");
                            ui.strong("End LBA");
                            ui.strong("Size");
                            ui.strong("Boot");
                            ui.strong("");
                            ui.end_row();

                            for part in &pt.partitions {
                                ui.label(format!("{}", part.index));
                                ui.label(&part.name);
                                ui.label(&part.type_name);
                                ui.label(&part.fs_type);
                                ui.label(format!("{}", part.start_lba));
                                ui.label(format!("{}", part.end_lba));
                                ui.label(part.size_human());
                                ui.label(if part.bootable { "Yes" } else { "" });

                                // Action buttons
                                ui.horizontal(|ui| {
                                    if ui.small_button("Dump").clicked() {
                                        if let Some(path) = rfd::FileDialog::new()
                                            .set_title(&format!(
                                                "Dump partition {}",
                                                if part.name.is_empty() {
                                                    format!("#{}", part.index)
                                                } else {
                                                    part.name.clone()
                                                }
                                            ))
                                            .set_file_name(&format!(
                                                "{}.bin",
                                                if part.name.is_empty() {
                                                    format!("part{}", part.index)
                                                } else {
                                                    part.name.clone()
                                                }
                                            ))
                                            .save_file()
                                        {
                                            state.set_running(format!(
                                                "Dumping partition {}...",
                                                part.name
                                            ));
                                            operations::dump_to_file(
                                                state.effective_port(),
                                                state.selected_baud,
                                                state.current_emmc_freq,
                                                part.start_lba as u32,
                                                part.size_sectors as u32,
                                                path.display().to_string(),
                                                state.verify_after_dump,
                                                state.cancel_flag.clone(),
                                                tx.clone(),
                                                state.log.clone(),
                                            );
                                        }
                                    }

                                    let is_ext4 = part.fs_type == "ext4";
                                    let label = if is_ext4 { "Browse" } else { "ext4?" };
                                    if ui.small_button(label).clicked() {
                                        state.ext4_partition_input = if part.name.is_empty() {
                                            format!("{}", part.start_lba)
                                        } else {
                                            part.name.clone()
                                        };
                                        state.active_tab = ActiveTab::Ext4Browser;
                                        // Auto-load ext4 filesystem
                                        state.set_running("Loading ext4...");
                                        operations::ext4_load(
                                            state.effective_port(),
                                            state.selected_baud,
                                            part.start_lba,
                                            tx.clone(),
                                            state.log.clone(),
                                        );
                                    }
                                });
                                ui.end_row();
                            }
                        });
                });
            }

            // Raw data collapsibles
            ui.separator();
            ui.collapsing("Raw MBR (LBA 0)", |ui| {
                if !pt.raw_mbr.is_empty() {
                    let hex = emmc_app::operations::hex_dump(&pt.raw_mbr, 512);
                    egui::ScrollArea::vertical()
                        .max_height(200.0)
                        .show(ui, |ui| {
                            ui.monospace(&hex);
                        });
                }
            });

            if pt.table_type == PartitionTableType::GPT {
                ui.collapsing("Raw GPT Header (LBA 1)", |ui| {
                    if !pt.raw_gpt_header.is_empty() {
                        let hex = emmc_app::operations::hex_dump(&pt.raw_gpt_header, 512);
                        egui::ScrollArea::vertical()
                            .max_height(200.0)
                            .show(ui, |ui| {
                                ui.monospace(&hex);
                            });
                    }
                });
            }
        }
    }
}
