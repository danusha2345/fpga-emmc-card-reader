use eframe::egui;
use programmer_engine::state::OperationProgress;

#[allow(dead_code)]
pub fn show_progress_bar(
    ui: &mut egui::Ui,
    progress: &OperationProgress,
    show_cancel: bool,
) -> bool {
    let mut cancelled = false;

    ui.horizontal(|ui| {
        ui.add(
            egui::ProgressBar::new(progress.fraction())
                .text(&progress.description)
                .animate(true),
        );
        if show_cancel && ui.small_button("Cancel").clicked() {
            cancelled = true;
        }
    });

    cancelled
}
