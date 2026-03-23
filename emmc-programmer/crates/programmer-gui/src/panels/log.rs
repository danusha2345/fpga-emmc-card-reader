use eframe::egui;
use programmer_engine::logging::LogLevel;
use programmer_engine::state::AppState;

use crate::theme;

pub fn show_log_panel(ui: &mut egui::Ui, state: &AppState) {
    ui.horizontal(|ui| {
        ui.heading("Log");
        ui.label(
            egui::RichText::new(format!("({})", state.log.log_file_path()))
                .small()
                .color(egui::Color32::GRAY),
        );
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.small_button("Clear").clicked() {
                state.log.clear();
            }
            if ui.small_button("Save Log").clicked() {
                if let Some(path) = rfd::FileDialog::new()
                    .set_file_name("programmer_gui_log.txt")
                    .save_file()
                {
                    match state.log.save_to_file(&path.display().to_string()) {
                        Ok(()) => {
                            state.log.info(format!("Log saved to {}", path.display()));
                        }
                        Err(e) => {
                            state.log.error(format!("Save log failed: {}", e));
                        }
                    }
                }
            }
        });
    });

    ui.separator();

    let entries = state.log.entries();
    egui::ScrollArea::vertical()
        .auto_shrink([false; 2])
        .stick_to_bottom(true)
        .show(ui, |ui| {
            for entry in &entries {
                let color = match entry.level {
                    LogLevel::Debug => egui::Color32::GRAY,
                    LogLevel::Info => egui::Color32::LIGHT_GRAY,
                    LogLevel::Warn => theme::COLOR_WARNING,
                    LogLevel::Error => theme::COLOR_ERROR,
                };
                ui.horizontal(|ui| {
                    ui.monospace(format!("[{:8.2}]", entry.elapsed_secs));
                    ui.colored_label(color, format!("[{}]", entry.level.label()));
                    ui.label(&entry.message);
                });
            }
        });
}
