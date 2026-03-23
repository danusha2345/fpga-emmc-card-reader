use eframe::egui;
use std::collections::HashSet;

use crate::theme;

pub fn show_hex_edit(
    ui: &mut egui::Ui,
    data: &mut [u8],
    modified: &HashSet<usize>,
    cursor: &mut usize,
    base_addr: u64,
) {
    let bytes_per_row = theme::HEX_BYTES_PER_ROW;
    let num_rows = data.len().div_ceil(bytes_per_row);
    egui::ScrollArea::vertical()
        .max_height(500.0)
        .show(ui, |ui| {
            ui.style_mut().override_font_id =
                Some(egui::FontId::monospace(12.0));

            for row in 0..num_rows {
                let offset = row * bytes_per_row;
                let end = (offset + bytes_per_row).min(data.len());

                ui.horizontal(|ui| {
                    // Address
                    ui.monospace(format!("{:08X}  ", base_addr + offset as u64));

                    // Hex bytes
                    for (i, &byte) in data[offset..end].iter().enumerate() {
                        let abs_i = offset + i;
                        let is_modified = modified.contains(&abs_i);
                        let is_cursor = abs_i == *cursor;

                        let text = format!("{:02X}", byte);

                        let color = if is_cursor {
                            egui::Color32::WHITE
                        } else if is_modified {
                            theme::COLOR_MODIFIED
                        } else {
                            egui::Color32::LIGHT_GRAY
                        };

                        let bg = if is_cursor {
                            Some(egui::Color32::from_rgb(60, 60, 120))
                        } else {
                            None
                        };

                        let label = egui::RichText::new(&text).color(color);
                        let resp = if let Some(bg_color) = bg {
                            ui.visuals_mut().widgets.noninteractive.bg_fill = bg_color;
                            
                            ui
                                .add(egui::Label::new(label).sense(egui::Sense::click()))
                        } else {
                            ui.add(egui::Label::new(label).sense(egui::Sense::click()))
                        };

                        if resp.clicked() {
                            *cursor = abs_i;
                        }

                        if i == 7 {
                            ui.add_space(4.0);
                        }
                    }

                    ui.add_space(8.0);

                    // ASCII column
                    ui.monospace("|");
                    for (i, &byte) in data[offset..end].iter().enumerate() {
                        let abs_i = offset + i;
                        let ch = if byte.is_ascii_graphic() || byte == b' ' {
                            byte as char
                        } else {
                            '.'
                        };
                        let is_modified = modified.contains(&abs_i);
                        let color = if is_modified {
                            theme::COLOR_MODIFIED
                        } else {
                            egui::Color32::LIGHT_GRAY
                        };
                        ui.add(
                            egui::Label::new(
                                egui::RichText::new(ch.to_string()).color(color),
                            )
                            .sense(egui::Sense::click()),
                        );
                    }
                    ui.monospace("|");
                });
            }
        });

    // Cursor info
    if *cursor < data.len() {
        ui.add_space(theme::GROUP_SPACING);
        ui.horizontal(|ui| {
            ui.monospace(format!(
                "Cursor: 0x{:08X} (offset {})  Value: 0x{:02X} ({})",
                base_addr + *cursor as u64,
                *cursor,
                data[*cursor],
                data[*cursor]
            ));
        });
    }
}
