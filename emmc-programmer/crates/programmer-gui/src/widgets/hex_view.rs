use eframe::egui;

use crate::theme;

pub fn show_hex_view(ui: &mut egui::Ui, data: &[u8], base_addr: u64) {
    let bytes_per_row = theme::HEX_BYTES_PER_ROW;
    let num_rows = data.len().div_ceil(bytes_per_row);

    egui::ScrollArea::vertical()
        .max_height(400.0)
        .show(ui, |ui| {
            ui.style_mut().override_font_id =
                Some(egui::FontId::monospace(12.0));

            for row in 0..num_rows {
                let offset = row * bytes_per_row;
                let end = (offset + bytes_per_row).min(data.len());
                let row_data = &data[offset..end];

                let mut line = format!("{:08X}  ", base_addr + offset as u64);

                // Hex part
                for (i, &byte) in row_data.iter().enumerate() {
                    line.push_str(&format!("{:02X} ", byte));
                    if i == 7 {
                        line.push(' ');
                    }
                }

                // Pad if short row
                for i in row_data.len()..bytes_per_row {
                    line.push_str("   ");
                    if i == 7 {
                        line.push(' ');
                    }
                }

                line.push_str(" |");

                // ASCII part
                for &byte in row_data {
                    if byte.is_ascii_graphic() || byte == b' ' {
                        line.push(byte as char);
                    } else {
                        line.push('.');
                    }
                }

                line.push('|');

                ui.label(line);
            }
        });
}
