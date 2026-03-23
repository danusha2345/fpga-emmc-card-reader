use eframe::egui;
use programmer_engine::state::AppState;

pub fn show_confirm_dialog(ctx: &egui::Context, state: &mut AppState) {
    let should_show = state.confirm_dialog.is_some();
    if !should_show {
        return;
    }

    let mut confirmed = None;

    if let Some(ref dialog) = state.confirm_dialog {
        egui::Window::new(&dialog.title)
            .collapsible(false)
            .resizable(false)
            .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
            .show(ctx, |ui| {
                ui.label(&dialog.message);
                ui.add_space(8.0);
                ui.horizontal(|ui| {
                    if ui.button("Confirm").clicked() {
                        confirmed = Some(true);
                    }
                    if ui.button("Cancel").clicked() {
                        confirmed = Some(false);
                    }
                });
            });
    }

    if let Some(yes) = confirmed {
        if yes {
            if let Some(dialog) = state.confirm_dialog.take() {
                state.pending_command = Some(dialog.command);
            }
        } else {
            state.confirm_dialog = None;
        }
    }
}
