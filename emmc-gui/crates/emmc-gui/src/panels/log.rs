use eframe::egui;
use emmc_app::logging::LogLevel;
use emmc_app::state::AppState;

use crate::theme;

pub fn show_log_panel(ui: &mut egui::Ui, state: &mut AppState) {
    ui.horizontal(|ui| {
        ui.strong("Log");
        ui.label(
            egui::RichText::new(format!("({})", state.log.log_file_path()))
                .small()
                .color(egui::Color32::GRAY),
        );
        ui.separator();
        ui.checkbox(&mut state.log_auto_scroll, "Auto-scroll");
        if ui.button("Clear").clicked() {
            state.log.clear();
        }
        if ui.button("Save Log").clicked() {
            if let Some(path) = rfd::FileDialog::new()
                .set_file_name("emmc_gui_log.txt")
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
        ui.label(format!("{} entries", state.log.len()));
    });

    ui.separator();

    let entries = state.log.entries();

    let scroll = egui::ScrollArea::vertical()
        .auto_shrink([false, false])
        .stick_to_bottom(state.log_auto_scroll);

    scroll.show(ui, |ui| {
        for entry in &entries {
            let color = match entry.level {
                LogLevel::Debug => egui::Color32::GRAY,
                LogLevel::Info => egui::Color32::LIGHT_GRAY,
                LogLevel::Warn => theme::COLOR_WARNING,
                LogLevel::Error => theme::COLOR_ERROR,
            };

            ui.horizontal(|ui| {
                ui.monospace(format!("[{:8.3}]", entry.elapsed_secs));
                ui.colored_label(color, entry.level.label());
                ui.label(&entry.message);
            });
        }
    });
}
