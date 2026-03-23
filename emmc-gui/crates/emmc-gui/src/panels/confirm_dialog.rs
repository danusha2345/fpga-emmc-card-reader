use eframe::egui;
use emmc_app::state::AppState;

pub fn show_confirm_dialog(ctx: &egui::Context, state: &mut AppState) {
    let mut close = false;

    if let Some(dialog) = &mut state.confirm_dialog {
        egui::Window::new(&dialog.title)
            .collapsible(false)
            .resizable(false)
            .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
            .show(ctx, |ui| {
                ui.label(&dialog.message);

                if let Some(detail) = &dialog.detail {
                    ui.separator();
                    egui::ScrollArea::vertical()
                        .max_height(200.0)
                        .show(ui, |ui| {
                            ui.monospace(detail);
                        });
                }

                ui.separator();

                ui.horizontal(|ui| {
                    if ui.button("Confirm").clicked() {
                        dialog.confirmed = Some(true);
                        close = true;
                    }
                    if ui.button("Cancel").clicked() {
                        dialog.confirmed = Some(false);
                        close = true;
                    }
                });
            });
    }

    if close {
        if let Some(dialog) = state.confirm_dialog.take() {
            if dialog.confirmed == Some(true) {
                // Set pending_action — dispatched by app.rs where worker_tx is available
                state.pending_action = Some(dialog.action_id);
            }
        }
    }
}
