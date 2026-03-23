use eframe::egui;
use programmer_engine::command::Command;

use crate::app::ProgrammerApp;
use crate::theme;

pub fn show_filesystem_panel(ui: &mut egui::Ui, app: &mut ProgrammerApp) {
    ui.heading("Filesystem Browser");
    ui.add_space(theme::SECTION_SPACING);

    let connected = app.state.connected && !app.state.is_busy();

    // --- Partition selector ---
    ui.horizontal(|ui| {
        ui.label("Partition:");
        let re = ui.add(
            egui::TextEdit::singleline(&mut app.state.ext4_partition_input)
                .desired_width(150.0)
                .hint_text("name or LBA"),
        );
        if ui
            .add_enabled(connected, egui::Button::new("Load ext4"))
            .clicked()
            || (re.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) && connected)
        {
            if let Some(lba) = find_partition_start(&app.state) {
                app.state.ext4_partition_lba = Some(lba);
                app.state.ext4_current_path = "/".to_string();
                app.dispatch_command(Command::Ext4Load { partition_lba: lba });
            } else {
                app.state
                    .log
                    .error("Partition not found. Read partition table first or enter LBA directly.");
            }
        }
    });

    // --- FS Info ---
    if let Some(ref info) = app.state.ext4_info {
        ui.add_space(theme::SECTION_SPACING);
        egui::CollapsingHeader::new("Filesystem Info")
            .default_open(false)
            .show(ui, |ui| {
                egui::Grid::new("ext4_info_grid")
                    .num_columns(2)
                    .spacing([16.0, 2.0])
                    .show(ui, |ui| {
                        ui.label("Volume:");
                        ui.label(if info.volume_name.is_empty() {
                            "(none)"
                        } else {
                            &info.volume_name
                        });
                        ui.end_row();

                        ui.label("UUID:");
                        ui.label(&info.uuid);
                        ui.end_row();

                        ui.label("Block size:");
                        ui.label(format!("{}", info.block_size));
                        ui.end_row();

                        let capacity_mb =
                            info.block_count as f64 * info.block_size as f64 / (1024.0 * 1024.0);
                        let free_mb =
                            info.free_blocks as f64 * info.block_size as f64 / (1024.0 * 1024.0);
                        ui.label("Capacity:");
                        ui.label(format!(
                            "{:.0} MB ({:.0} MB free)",
                            capacity_mb, free_mb
                        ));
                        ui.end_row();

                        ui.label("Inodes:");
                        ui.label(format!(
                            "{} ({} free)",
                            info.inode_count, info.free_inodes
                        ));
                        ui.end_row();

                        ui.label("Features:");
                        let mut feats = Vec::new();
                        if info.is_64bit {
                            feats.push("64bit");
                        }
                        if info.has_extents {
                            feats.push("extents");
                        }
                        if info.metadata_csum {
                            feats.push("metadata_csum");
                        }
                        ui.label(feats.join(", "));
                        ui.end_row();
                    });
            });
    }

    // Only show the rest if ext4 is loaded
    if app.state.ext4_partition_lba.is_none() || app.state.ext4_info.is_none() {
        ui.add_space(theme::SECTION_SPACING);
        ui.label("Load an ext4 partition to browse the filesystem.");
        ui.label("1. Go to Partitions tab and read partition table");
        ui.label("2. Enter partition name (e.g. 'userdata') or start LBA");
        ui.label("3. Click 'Load ext4'");
        return;
    }

    ui.add_space(theme::SECTION_SPACING);
    ui.separator();

    // --- Path bar ---
    ui.horizontal(|ui| {
        ui.label("Path:");
        let re = ui.add(
            egui::TextEdit::singleline(&mut app.state.ext4_current_path)
                .desired_width(300.0)
                .font(egui::TextStyle::Monospace),
        );
        if ui
            .add_enabled(connected, egui::Button::new("Go"))
            .clicked()
            || (re.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) && connected)
        {
            let path = app.state.ext4_current_path.clone();
            app.dispatch_command(Command::Ext4Navigate { path });
        }
        if ui
            .add_enabled(connected, egui::Button::new("Up"))
            .clicked()
        {
            let path = parent_path(&app.state.ext4_current_path);
            app.dispatch_command(Command::Ext4Navigate { path });
        }
        if ui
            .add_enabled(connected, egui::Button::new("/"))
            .on_hover_text("Home (root)")
            .clicked()
        {
            app.dispatch_command(Command::Ext4Navigate {
                path: "/".to_string(),
            });
        }
    });

    // --- Search bar ---
    ui.add_space(theme::GROUP_SPACING);
    ui.horizontal(|ui| {
        ui.label("Search:");
        let re = ui.add(
            egui::TextEdit::singleline(&mut app.state.ext4_search_query)
                .desired_width(200.0)
                .hint_text("filename pattern"),
        );
        if ui
            .add_enabled(
                connected && !app.state.ext4_search_query.is_empty(),
                egui::Button::new("Search"),
            )
            .clicked()
            || (re.lost_focus()
                && ui.input(|i| i.key_pressed(egui::Key::Enter))
                && connected
                && !app.state.ext4_search_query.is_empty())
        {
            let query = app.state.ext4_search_query.clone();
            app.dispatch_command(Command::Ext4Search { query });
        }
        if !app.state.ext4_search_results.is_empty()
            && ui.small_button("Clear results").clicked()
        {
            app.state.ext4_search_results.clear();
        }
    });

    // --- Search results ---
    if !app.state.ext4_search_results.is_empty() {
        ui.add_space(theme::GROUP_SPACING);
        let label = format!("Search Results ({})", app.state.ext4_search_results.len());
        egui::CollapsingHeader::new(label)
            .default_open(true)
            .show(ui, |ui| {
                egui::ScrollArea::vertical()
                    .id_salt("search_results")
                    .max_height(150.0)
                    .show(ui, |ui| {
                        let mut navigate_to = None;
                        let mut read_file = None;
                        for result in &app.state.ext4_search_results {
                            let icon = file_type_icon(result.file_type);
                            if ui
                                .selectable_label(false, format!("{} {}", icon, result.path))
                                .clicked()
                                && connected
                            {
                                if result.file_type == 2 {
                                    navigate_to = Some(result.path.clone());
                                } else {
                                    // Navigate to parent dir and read file
                                    let parent = parent_path(&result.path);
                                    navigate_to = Some(parent);
                                    read_file = Some(result.path.clone());
                                }
                            }
                        }
                        if let Some(path) = navigate_to {
                            app.dispatch_command(Command::Ext4Navigate { path });
                        }
                        if let Some(path) = read_file {
                            app.dispatch_command(Command::Ext4ReadFile { path });
                        }
                    });
            });
    }

    ui.add_space(theme::SECTION_SPACING);
    ui.separator();

    // --- Directory listing ---
    if !app.state.ext4_entries.is_empty() {
        ui.label(format!(
            "Directory: {} ({} entries)",
            app.state.ext4_current_path,
            app.state.ext4_entries.len()
        ));
        ui.add_space(theme::GROUP_SPACING);

        let mut navigate_to = None;
        let mut read_file = None;

        egui::ScrollArea::vertical()
            .id_salt("dir_listing")
            .max_height(250.0)
            .show(ui, |ui| {
                egui::Grid::new("ext4_dir_grid")
                    .num_columns(3)
                    .striped(true)
                    .min_col_width(40.0)
                    .show(ui, |ui| {
                        ui.strong("Type");
                        ui.strong("Name");
                        ui.strong("Inode");
                        ui.end_row();

                        for entry in &app.state.ext4_entries {
                            let icon = file_type_icon(entry.file_type);
                            ui.label(icon);

                            let resp =
                                ui.add(egui::Label::new(&entry.name).sense(egui::Sense::click()));
                            if resp.clicked() && connected {
                                match entry.file_type {
                                    2 => {
                                        // directory
                                        if entry.name == ".." {
                                            navigate_to = Some(parent_path(
                                                &app.state.ext4_current_path,
                                            ));
                                        } else if entry.name != "." {
                                            let base = &app.state.ext4_current_path;
                                            let path = if base == "/" {
                                                format!("/{}", entry.name)
                                            } else {
                                                format!("{}/{}", base, entry.name)
                                            };
                                            navigate_to = Some(path);
                                        }
                                    }
                                    _ => {
                                        // file or symlink
                                        let base = &app.state.ext4_current_path;
                                        let path = if base == "/" {
                                            format!("/{}", entry.name)
                                        } else {
                                            format!("{}/{}", base, entry.name)
                                        };
                                        read_file = Some(path);
                                    }
                                }
                            }
                            resp.on_hover_text(match entry.file_type {
                                1 => "File (click to read)",
                                2 => "Directory (click to enter)",
                                7 => "Symlink (click to read)",
                                _ => "Unknown type",
                            });

                            ui.label(entry.inode.to_string());
                            ui.end_row();
                        }
                    });
            });

        if let Some(path) = navigate_to {
            app.dispatch_command(Command::Ext4Navigate { path });
        }
        if let Some(path) = read_file {
            app.dispatch_command(Command::Ext4ReadFile { path });
        }
    }

    // --- File preview ---
    let file_preview = app
        .state
        .ext4_file_path
        .as_ref()
        .zip(app.state.ext4_file_content.as_ref())
        .map(|(p, d)| (p.clone(), d.clone()));

    if let Some((path, data)) = file_preview {
        ui.add_space(theme::SECTION_SPACING);
        ui.separator();
        ui.horizontal(|ui| {
            ui.strong(format!("File: {}", path));
            ui.label(format!("({} bytes)", data.len()));
        });
        ui.add_space(theme::GROUP_SPACING);

        // Action buttons
        ui.horizontal(|ui| {
            if ui.button("Save to PC").clicked() {
                let filename = path.rsplit('/').next().unwrap_or("file");
                if let Some(save_path) = rfd::FileDialog::new()
                    .set_file_name(filename)
                    .save_file()
                {
                    match std::fs::write(&save_path, &data) {
                        Ok(()) => {
                            app.state
                                .log
                                .info(format!("Saved to {}", save_path.display()));
                        }
                        Err(e) => {
                            app.state
                                .log
                                .error(format!("Save failed: {}", e));
                        }
                    }
                }
            }
            if ui.button("Open in Hex Editor").clicked() {
                app.state.hex_data = data.clone();
                app.state.hex_source_lba = None;
                app.state.hex_modified.clear();
                app.state.hex_undo_stack.clear();
                app.state.hex_redo_stack.clear();
                app.state.hex_cursor = 0;
                app.state.active_tab =
                    programmer_engine::state::ActiveTab::HexEditor;
            }
            if ui
                .add_enabled(connected, egui::Button::new("Overwrite from File..."))
                .clicked()
            {
                if let Some(local_path) = rfd::FileDialog::new().pick_file() {
                    app.dispatch_command(Command::Ext4OverwriteFile {
                        ext4_path: path.clone(),
                        local_path,
                    });
                }
            }
        });

        ui.add_space(theme::GROUP_SPACING);

        // Content preview
        let is_text = data.len() <= 8192
            && data
                .iter()
                .all(|&b| b.is_ascii_graphic() || b.is_ascii_whitespace());
        egui::ScrollArea::vertical()
            .id_salt("file_preview")
            .max_height(300.0)
            .show(ui, |ui| {
                if is_text {
                    let text = String::from_utf8_lossy(&data);
                    ui.add(
                        egui::TextEdit::multiline(&mut text.as_ref())
                            .font(egui::TextStyle::Monospace)
                            .desired_width(f32::INFINITY)
                            .interactive(false),
                    );
                } else {
                    let hex = hex_dump(&data, 2048);
                    ui.add(
                        egui::TextEdit::multiline(&mut hex.as_str())
                            .font(egui::TextStyle::Monospace)
                            .desired_width(f32::INFINITY)
                            .interactive(false),
                    );
                }
            });
    }

    // --- Create file ---
    if app.state.ext4_partition_lba.is_some() && app.state.ext4_info.is_some() {
        ui.add_space(theme::SECTION_SPACING);
        ui.separator();
        ui.horizontal(|ui| {
            ui.label("Create file in current dir:");
            if ui
                .add_enabled(connected, egui::Button::new("From File..."))
                .clicked()
            {
                if let Some(local_path) = rfd::FileDialog::new().pick_file() {
                    let name = local_path
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_else(|| "new_file".to_string());
                    match std::fs::read(&local_path) {
                        Ok(data) => {
                            let parent_path = app.state.ext4_current_path.clone();
                            app.dispatch_command(Command::Ext4CreateFile {
                                parent_path,
                                name,
                                data,
                            });
                        }
                        Err(e) => {
                            app.state
                                .log
                                .error(format!("Read file: {}", e));
                        }
                    }
                }
            }
            if ui
                .add_enabled(connected, egui::Button::new("Create Empty"))
                .clicked()
            {
                let parent_path = app.state.ext4_current_path.clone();
                app.dispatch_command(Command::Ext4CreateFile {
                    parent_path,
                    name: "new_file".to_string(),
                    data: Vec::new(),
                });
            }
        });
    }
}

fn find_partition_start(
    state: &programmer_engine::state::AppState,
) -> Option<u64> {
    let input = state.ext4_partition_input.trim();

    // Try direct LBA parse
    if let Ok(lba) = input.parse::<u64>() {
        return Some(lba);
    }

    // Look up by name in partition table
    if let Some(ref pt) = state.partition_data {
        for entry in &pt.entries {
            if entry.name.eq_ignore_ascii_case(input) {
                return Some(entry.start_lba);
            }
        }
        // Try partial match
        let lower = input.to_lowercase();
        for entry in &pt.entries {
            if entry.name.to_lowercase().contains(&lower) {
                return Some(entry.start_lba);
            }
        }
    }

    None
}

fn parent_path(path: &str) -> String {
    if path == "/" || path.is_empty() {
        return "/".to_string();
    }
    match path.rfind('/') {
        Some(0) => "/".to_string(),
        Some(pos) => path[..pos].to_string(),
        None => "/".to_string(),
    }
}

fn file_type_icon(ft: u8) -> &'static str {
    match ft {
        1 => "f",
        2 => "d",
        7 => "l",
        _ => "?",
    }
}

fn hex_dump(data: &[u8], max_bytes: usize) -> String {
    let mut out = String::new();
    let limit = data.len().min(max_bytes);
    for (i, chunk) in data[..limit].chunks(16).enumerate() {
        out.push_str(&format!("{:08X}  ", i * 16));
        for (j, &b) in chunk.iter().enumerate() {
            out.push_str(&format!("{:02X} ", b));
            if j == 7 {
                out.push(' ');
            }
        }
        // Pad if short line
        if chunk.len() < 16 {
            for j in chunk.len()..16 {
                out.push_str("   ");
                if j == 7 {
                    out.push(' ');
                }
            }
        }
        out.push_str(" |");
        for &b in chunk {
            if b.is_ascii_graphic() || b == b' ' {
                out.push(b as char);
            } else {
                out.push('.');
            }
        }
        out.push_str("|\n");
    }
    if limit < data.len() {
        out.push_str(&format!("... ({} more bytes)\n", data.len() - limit));
    }
    out
}
