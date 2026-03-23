use eframe::egui;
use std::collections::HashSet;

use crate::theme;

/// Editable hex editor widget
pub fn show_hex_editor(
    ui: &mut egui::Ui,
    data: &mut Vec<u8>,
    modified: &mut HashSet<usize>,
    cursor: &mut usize,
) {
    if data.is_empty() {
        ui.label("No data");
        return;
    }

    let total_rows = (data.len() + 15) / 16;
    let row_height = 16.0;
    let visible_height = ui.available_height().min(600.0);

    egui::ScrollArea::vertical()
        .auto_shrink([false, false])
        .max_height(visible_height)
        .show_rows(ui, row_height, total_rows, |ui, row_range| {
            // Build text for visible rows
            let font = egui::FontId::monospace(13.0);

            for row in row_range {
                let offset = row * 16;
                let end = (offset + 16).min(data.len());
                let chunk = &data[offset..end];

                ui.horizontal(|ui| {
                    // Offset column
                    ui.label(
                        egui::RichText::new(format!("{:08X}", offset))
                            .font(font.clone())
                            .color(egui::Color32::DARK_GRAY),
                    );

                    ui.add_space(8.0);

                    // Hex bytes
                    for (j, idx) in (offset..end).enumerate() {
                        if j == 8 {
                            ui.add_space(4.0);
                        }

                        let byte = data[idx];
                        let is_modified = modified.contains(&idx);
                        let is_cursor = idx == *cursor;

                        let text = format!("{:02X}", byte);
                        let mut rt = egui::RichText::new(&text).font(font.clone());

                        if is_modified {
                            rt = rt
                                .color(egui::Color32::BLACK)
                                .background_color(theme::COLOR_WARNING);
                        } else if is_cursor {
                            rt = rt
                                .color(egui::Color32::BLACK)
                                .background_color(egui::Color32::LIGHT_BLUE);
                        }

                        let response = ui.add(egui::Label::new(rt).sense(egui::Sense::click()));

                        if response.clicked() {
                            *cursor = idx;
                        }

                        ui.add_space(1.0);
                    }

                    // Padding for short last row
                    let padding = 16 - chunk.len();
                    for j in 0..padding {
                        if chunk.len() + j == 8 {
                            ui.add_space(4.0);
                        }
                        ui.label(egui::RichText::new("  ").font(font.clone()));
                        ui.add_space(1.0);
                    }

                    ui.add_space(8.0);

                    // ASCII column
                    ui.label(
                        egui::RichText::new("|")
                            .font(font.clone())
                            .color(egui::Color32::DARK_GRAY),
                    );

                    for idx in offset..end {
                        let byte = data[idx];
                        let ch = if byte.is_ascii_graphic() || byte == b' ' {
                            byte as char
                        } else {
                            '.'
                        };

                        let is_modified = modified.contains(&idx);
                        let mut rt = egui::RichText::new(format!("{}", ch)).font(font.clone());

                        if is_modified {
                            rt = rt.background_color(theme::COLOR_WARNING);
                        }

                        let response = ui.add(egui::Label::new(rt).sense(egui::Sense::click()));

                        if response.clicked() {
                            *cursor = idx;
                        }
                    }

                    ui.label(
                        egui::RichText::new("|")
                            .font(font.clone())
                            .color(egui::Color32::DARK_GRAY),
                    );
                });
            }
        });

    // Handle keyboard input for hex editing
    ui.input(|i| {
        if *cursor < data.len() {
            for event in &i.events {
                if let egui::Event::Text(text) = event {
                    for ch in text.chars() {
                        if let Some(nibble) = ch.to_digit(16) {
                            let byte = &mut data[*cursor];
                            // Shift existing value left by 4 and add new nibble
                            *byte = (*byte << 4) | (nibble as u8);
                            modified.insert(*cursor);
                        }
                    }
                }
                if let egui::Event::Key {
                    key, pressed: true, ..
                } = event
                {
                    match key {
                        egui::Key::ArrowRight => {
                            if *cursor + 1 < data.len() {
                                *cursor += 1;
                            }
                        }
                        egui::Key::ArrowLeft => {
                            if *cursor > 0 {
                                *cursor -= 1;
                            }
                        }
                        egui::Key::ArrowDown => {
                            if *cursor + 16 < data.len() {
                                *cursor += 16;
                            }
                        }
                        egui::Key::ArrowUp => {
                            if *cursor >= 16 {
                                *cursor -= 16;
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
    });
}
