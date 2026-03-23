use eframe::egui;

/// Read-only hex dump widget
pub fn show_hex_bytes(ui: &mut egui::Ui, data: &[u8], max_bytes: usize) {
    let show = data.len().min(max_bytes);

    egui::ScrollArea::both()
        .auto_shrink([false, false])
        .show(ui, |ui| {
            let mut text = String::new();
            for (i, chunk) in data[..show].chunks(16).enumerate() {
                let offset = i * 16;
                text.push_str(&format!("{:08X}  ", offset));

                for (j, &byte) in chunk.iter().enumerate() {
                    text.push_str(&format!("{:02X} ", byte));
                    if j == 7 {
                        text.push(' ');
                    }
                }

                let padding = 16 - chunk.len();
                for j in 0..padding {
                    text.push_str("   ");
                    if chunk.len() + j == 7 {
                        text.push(' ');
                    }
                }

                text.push_str(" |");
                for &byte in chunk {
                    if byte.is_ascii_graphic() || byte == b' ' {
                        text.push(byte as char);
                    } else {
                        text.push('.');
                    }
                }
                text.push_str("|\n");
            }

            if show < data.len() {
                text.push_str(&format!("... ({} more bytes)\n", data.len() - show));
            }

            ui.monospace(&text);
        });
}
