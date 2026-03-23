use eframe::egui;
use programmer_engine::command::Command;

use crate::app::ProgrammerApp;
use crate::theme;
use crate::widgets;

pub fn show_hex_editor_panel(ui: &mut egui::Ui, app: &mut ProgrammerApp) {
    ui.heading("Hex Editor");
    ui.add_space(theme::SECTION_SPACING);

    let connected = app.state.connected && !app.state.is_busy();

    // Load controls
    ui.horizontal(|ui| {
        ui.label("LBA:");
        ui.add(
            egui::TextEdit::singleline(&mut app.state.hex_lba_input)
                .desired_width(100.0),
        );
        ui.label("Count:");
        ui.add(
            egui::TextEdit::singleline(&mut app.state.hex_count_input)
                .desired_width(60.0),
        );
        if ui
            .add_enabled(connected, egui::Button::new("Load"))
            .clicked()
        {
            if let (Ok(lba), Ok(count)) = (
                app.state.hex_lba_input.parse::<u32>(),
                app.state.hex_count_input.parse::<u32>(),
            ) {
                app.dispatch_command(Command::ReadSectors {
                    lba,
                    count,
                    path: None,
                });
            }
        }
    });

    // Toolbar
    ui.horizontal(|ui| {
        let has_data = !app.state.hex_data.is_empty();
        let has_undo = !app.state.hex_undo_stack.is_empty();
        let has_redo = !app.state.hex_redo_stack.is_empty();
        let has_mods = !app.state.hex_modified.is_empty();

        if ui
            .add_enabled(has_undo, egui::Button::new("Undo (Ctrl+Z)"))
            .clicked()
        {
            app.state.hex_undo();
        }
        if ui
            .add_enabled(has_redo, egui::Button::new("Redo (Ctrl+Y)"))
            .clicked()
        {
            app.state.hex_redo();
        }

        ui.separator();

        if ui
            .add_enabled(
                has_mods && connected,
                egui::Button::new("Write Back"),
            )
            .clicked()
        {
            if let Some(lba) = app.state.hex_source_lba {
                let data = app.state.hex_data.clone();
                app.dispatch_command(Command::HexWriteBack {
                    lba: lba as u32,
                    data,
                });
            }
        }

        if has_mods {
            ui.colored_label(
                theme::COLOR_MODIFIED,
                format!("{} byte(s) modified", app.state.hex_modified.len()),
            );
        }

        ui.separator();

        // Search
        ui.label("Search:");
        ui.add(
            egui::TextEdit::singleline(&mut app.state.hex_search_input)
                .desired_width(120.0)
                .hint_text("hex or ASCII"),
        );
        if ui.add_enabled(has_data, egui::Button::new("Find")).clicked() {
            if let Some(pos) = search_hex(
                &app.state.hex_data,
                &app.state.hex_search_input,
                app.state.hex_cursor,
            ) {
                app.state.hex_cursor = pos;
            }
        }

        ui.separator();

        // Goto
        ui.label("Goto:");
        ui.add(
            egui::TextEdit::singleline(&mut app.state.hex_goto_input)
                .desired_width(80.0)
                .hint_text("offset"),
        );
        if ui.add_enabled(has_data, egui::Button::new("Go")).clicked() {
            let input = app.state.hex_goto_input.trim();
            let offset = if let Some(hex) = input.strip_prefix("0x") {
                usize::from_str_radix(hex, 16).ok()
            } else {
                input.parse::<usize>().ok()
            };
            if let Some(off) = offset {
                if off < app.state.hex_data.len() {
                    app.state.hex_cursor = off;
                }
            }
        }
    });

    ui.add_space(theme::GROUP_SPACING);

    // Hex editor view
    if app.state.hex_data.is_empty() {
        ui.label("No data loaded. Use 'Load' to read sectors.");
    } else {
        let base_addr = app.state.hex_source_lba.unwrap_or(0) * 512;
        widgets::hex_edit::show_hex_edit(
            ui,
            &mut app.state.hex_data,
            &app.state.hex_modified,
            &mut app.state.hex_cursor,
            base_addr,
        );
    }
}

fn search_hex(data: &[u8], query: &str, start: usize) -> Option<usize> {
    let query = query.trim();
    if query.is_empty() {
        return None;
    }

    // Try hex pattern first (e.g., "FF 00 AB")
    let hex_bytes: Option<Vec<u8>> = query
        .split_whitespace()
        .map(|s| u8::from_str_radix(s, 16).ok())
        .collect();

    let pattern = if let Some(bytes) = hex_bytes {
        bytes
    } else {
        // ASCII search
        query.as_bytes().to_vec()
    };

    if pattern.is_empty() {
        return None;
    }

    // Search from start+1, wrapping around
    let len = data.len();
    for i in 1..=len {
        let pos = (start + i) % len;
        if pos + pattern.len() <= len
            && data[pos..pos + pattern.len()] == pattern[..]
        {
            return Some(pos);
        }
    }
    None
}
