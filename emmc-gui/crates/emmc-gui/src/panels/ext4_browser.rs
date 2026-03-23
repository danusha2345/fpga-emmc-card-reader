use crossbeam_channel::Sender;
use eframe::egui;
use emmc_app::operations::{self, WorkerMessage};
use emmc_app::state::{ActiveTab, AppState, HexSource};

pub fn show_ext4_panel(ui: &mut egui::Ui, state: &mut AppState, tx: &Sender<WorkerMessage>) {
    ui.heading("ext4 File Browser");

    if !state.connected {
        ui.label("Not connected.");
        return;
    }

    // Partition selector + Load
    ui.horizontal(|ui| {
        ui.label("Partition:");
        ui.add(egui::TextEdit::singleline(&mut state.ext4_partition_input).desired_width(120.0));

        if ui
            .add_enabled(!state.is_busy(), egui::Button::new("Load FS"))
            .clicked()
        {
            let start_lba = find_partition_start(state);
            if let Some(lba) = start_lba {
                state.set_running("Loading ext4...");
                operations::ext4_load(
                    state.effective_port(),
                    state.selected_baud,
                    lba,
                    tx.clone(),
                    state.log.clone(),
                );
            } else {
                state
                    .log
                    .error("Partition not found. Read partitions first.");
            }
        }
    });

    // FS info
    if let Some(info) = &state.ext4_info {
        ui.separator();
        ui.collapsing("Filesystem Info", |ui| {
            egui::Grid::new("ext4_info_grid")
                .num_columns(2)
                .spacing([8.0, 4.0])
                .show(ui, |ui| {
                    ui.label("Volume:");
                    ui.label(if info.volume_name.is_empty() {
                        "(none)"
                    } else {
                        &info.volume_name
                    });
                    ui.end_row();

                    ui.label("UUID:");
                    ui.monospace(&info.uuid);
                    ui.end_row();

                    ui.label("Block Size:");
                    ui.label(format!("{} bytes", info.block_size));
                    ui.end_row();

                    ui.label("Blocks:");
                    ui.label(format!("{} ({} free)", info.block_count, info.free_blocks));
                    ui.end_row();

                    ui.label("Inodes:");
                    ui.label(format!("{} ({} free)", info.inode_count, info.free_inodes));
                    ui.end_row();

                    ui.label("64-bit:");
                    ui.label(format!("{}", info.is_64bit));
                    ui.end_row();

                    ui.label("Extents:");
                    ui.label(format!("{}", info.has_extents));
                    ui.end_row();

                    ui.label("Metadata CRC:");
                    ui.label(format!("{}", info.metadata_csum));
                    ui.end_row();

                    let cap = info.block_count as f64 * info.block_size as f64;
                    let free = info.free_blocks as f64 * info.block_size as f64;
                    ui.label("Capacity:");
                    ui.label(format!(
                        "{:.0} MB (used {:.0} MB, free {:.0} MB)",
                        cap / 1048576.0,
                        (cap - free) / 1048576.0,
                        free / 1048576.0
                    ));
                    ui.end_row();
                });
        });
    }

    // Path bar + navigation
    if state.ext4_info.is_some() {
        ui.separator();
        ui.horizontal(|ui| {
            ui.label("Path:");
            let response = ui
                .add(egui::TextEdit::singleline(&mut state.ext4_current_path).desired_width(300.0));

            let go_clicked = ui
                .add_enabled(!state.is_busy(), egui::Button::new("Go"))
                .clicked();
            let enter_pressed =
                response.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));

            if go_clicked || enter_pressed {
                navigate_ext4(state, tx, &state.ext4_current_path.clone());
            }

            if ui.button("Up").clicked() {
                let path = state.ext4_current_path.clone();
                let parent = parent_path(&path);
                navigate_ext4(state, tx, &parent);
            }

            if ui.button("Home /").clicked() {
                navigate_ext4(state, tx, "/");
            }
        });

        // Directory listing
        if !state.ext4_entries.is_empty() {
            ui.separator();
            ui.label(format!(
                "{} ({} entries)",
                state.ext4_current_path,
                state.ext4_entries.len()
            ));

            egui::ScrollArea::vertical()
                .max_height(300.0)
                .show(ui, |ui| {
                    egui::Grid::new("ext4_dir_grid")
                        .striped(true)
                        .min_col_width(40.0)
                        .show(ui, |ui| {
                            ui.strong("Type");
                            ui.strong("Name");
                            ui.strong("Inode");
                            ui.end_row();

                            let entries = state.ext4_entries.clone();
                            for entry in &entries {
                                ui.label(entry.file_type_name());

                                let is_dir = entry.file_type == 2;
                                if ui
                                    .add(egui::Label::new(&entry.name).sense(egui::Sense::click()))
                                    .clicked()
                                {
                                    if is_dir && entry.name != "." {
                                        let new_path = if entry.name == ".." {
                                            parent_path(&state.ext4_current_path)
                                        } else {
                                            let base =
                                                state.ext4_current_path.trim_end_matches('/');
                                            format!("{}/{}", base, entry.name)
                                        };
                                        navigate_ext4(state, tx, &new_path);
                                    } else if !is_dir {
                                        let base = state.ext4_current_path.trim_end_matches('/');
                                        let file_path = format!("{}/{}", base, entry.name);
                                        read_ext4_file(state, tx, &file_path);
                                    }
                                }

                                ui.label(format!("{}", entry.inode));
                                ui.end_row();
                            }
                        });
                });
        }

        // File preview
        if let Some(data) = state.ext4_file_content.clone() {
            ui.separator();

            let file_path = state.ext4_file_path.clone();

            if let Some(path) = &file_path {
                ui.label(format!("File: {} ({} bytes)", path, data.len()));
            }

            ui.horizontal(|ui| {
                if ui.button("Save to PC").clicked() {
                    if let Some(save_path) =
                        rfd::FileDialog::new().set_title("Save file").save_file()
                    {
                        if let Err(e) = std::fs::write(&save_path, &data) {
                            state.log.error(format!("Save failed: {}", e));
                        } else {
                            state.log.info(format!("Saved to {}", save_path.display()));
                        }
                    }
                }

                if ui.button("Open in Hex Editor").clicked() {
                    state.hex_data = data.clone();
                    state.hex_source = HexSource::Ext4File {
                        path: file_path.clone().unwrap_or_default(),
                    };
                    state.hex_modified.clear();
                    state.hex_cursor = 0;
                    state.active_tab = ActiveTab::HexEditor;
                }

                // Overwrite from file
                if let Some(ext4_path) = file_path.clone() {
                    if ui
                        .add_enabled(
                            !state.is_busy(),
                            egui::Button::new("Overwrite from File..."),
                        )
                        .clicked()
                    {
                        if let Some(local_path) = rfd::FileDialog::new()
                            .set_title("Select file to overwrite with")
                            .pick_file()
                        {
                            if let Some(part_lba) = find_partition_start(state) {
                                let local_str = local_path.display().to_string();
                                state.confirm_dialog = Some(emmc_app::state::ConfirmDialog::new(
                                    "Overwrite ext4 File",
                                    format!(
                                        "Overwrite {} with {}?",
                                        ext4_path,
                                        local_path
                                            .file_name()
                                            .unwrap_or_default()
                                            .to_string_lossy()
                                    ),
                                    format!("ext4_write:{}:{}:{}", part_lba, ext4_path, local_str),
                                ));
                            }
                        }
                    }
                }
            });

            // Preview
            let is_text = data.len() <= 8192
                && data
                    .iter()
                    .all(|&b| b == 0 || (32..127).contains(&b) || b == 9 || b == 10 || b == 13);

            if is_text && !data.is_empty() {
                egui::ScrollArea::vertical()
                    .max_height(200.0)
                    .id_salt("ext4_text_preview")
                    .show(ui, |ui| {
                        ui.monospace(String::from_utf8_lossy(&data).as_ref());
                    });
            } else {
                let hex = emmc_app::operations::hex_dump(&data, 512);
                egui::ScrollArea::vertical()
                    .max_height(200.0)
                    .id_salt("ext4_hex_preview")
                    .show(ui, |ui| {
                        ui.monospace(&hex);
                    });
            }
        }

        // Create file
        ui.separator();
        ui.group(|ui| {
            ui.label("Create File");
            ui.horizontal(|ui| {
                ui.label(format!("In: {}", state.ext4_current_path));

                if ui
                    .add_enabled(!state.is_busy(), egui::Button::new("Create from File..."))
                    .clicked()
                {
                    if let Some(local_path) = rfd::FileDialog::new()
                        .set_title("Select file to create")
                        .pick_file()
                    {
                        if let Some(part_lba) = find_partition_start(state) {
                            let name = local_path
                                .file_name()
                                .unwrap_or_default()
                                .to_string_lossy()
                                .to_string();
                            let parent = state.ext4_current_path.clone();

                            match std::fs::read(&local_path) {
                                Ok(data) => {
                                    state.set_running("Creating file...");
                                    operations::ext4_create(
                                        state.effective_port(),
                                        state.selected_baud,
                                        part_lba,
                                        parent,
                                        name,
                                        data,
                                        tx.clone(),
                                        state.log.clone(),
                                    );
                                }
                                Err(e) => {
                                    state.log.error(format!("Read file failed: {}", e));
                                }
                            }
                        }
                    }
                }

                if ui
                    .add_enabled(!state.is_busy(), egui::Button::new("Create Empty File..."))
                    .clicked()
                {
                    // Simple dialog: use rfd doesn't have text input, so we use a prompt approach
                    // For now, create a file named "new_file" with empty content
                    if let Some(part_lba) = find_partition_start(state) {
                        let parent = state.ext4_current_path.clone();
                        state.set_running("Creating empty file...");
                        operations::ext4_create(
                            state.effective_port(),
                            state.selected_baud,
                            part_lba,
                            parent,
                            "new_file".to_string(),
                            Vec::new(),
                            tx.clone(),
                            state.log.clone(),
                        );
                    }
                }
            });
        });
    }
}

fn find_partition_start(state: &AppState) -> Option<u64> {
    let input = state.ext4_partition_input.trim();

    // Try as LBA number
    if let Ok(lba) = input.parse::<u64>() {
        return Some(lba);
    }

    // Try to find by name in partition table
    if let Some(pt) = &state.partition_table {
        for part in &pt.partitions {
            if part.name.eq_ignore_ascii_case(input) {
                return Some(part.start_lba);
            }
        }
        // Try by index
        if let Ok(idx) = input.parse::<u32>() {
            for part in &pt.partitions {
                if part.index == idx {
                    return Some(part.start_lba);
                }
            }
        }
    }

    None
}

fn navigate_ext4(state: &mut AppState, tx: &Sender<WorkerMessage>, path: &str) {
    let start_lba = find_partition_start(state);
    if let Some(lba) = start_lba {
        state.set_running(format!("Listing {}...", path));
        state.ext4_file_content = None;
        state.ext4_file_path = None;
        operations::ext4_ls(
            state.effective_port(),
            state.selected_baud,
            lba,
            path.to_string(),
            tx.clone(),
            state.log.clone(),
        );
    }
}

fn read_ext4_file(state: &mut AppState, tx: &Sender<WorkerMessage>, path: &str) {
    let start_lba = find_partition_start(state);
    if let Some(lba) = start_lba {
        state.set_running(format!("Reading {}...", path));
        operations::ext4_cat(
            state.effective_port(),
            state.selected_baud,
            lba,
            path.to_string(),
            tx.clone(),
            state.log.clone(),
        );
    }
}

fn parent_path(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if let Some(pos) = trimmed.rfind('/') {
        if pos == 0 {
            "/".to_string()
        } else {
            trimmed[..pos].to_string()
        }
    } else {
        "/".to_string()
    }
}
