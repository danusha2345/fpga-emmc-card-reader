use eframe::egui;
use std::collections::HashSet;

use crate::theme;

pub fn show_sector_map(
    ui: &mut egui::Ui,
    total_sectors: usize,
    diff_sectors: &HashSet<u64>,
) {
    if total_sectors == 0 {
        return;
    }

    // Calculate grid dimensions
    let available_width = ui.available_width();
    let cell_size = 4.0f32;
    let cols = ((available_width / (cell_size + 1.0)) as usize).max(1);
    let sectors_per_cell =
        total_sectors.div_ceil(cols * 200).max(1);
    let total_cells =
        total_sectors.div_ceil(sectors_per_cell);
    let rows = total_cells.div_ceil(cols);
    let display_rows = rows.min(200); // Cap display

    let (response, painter) = ui.allocate_painter(
        egui::vec2(
            cols as f32 * (cell_size + 1.0),
            display_rows as f32 * (cell_size + 1.0),
        ),
        egui::Sense::hover(),
    );

    let origin = response.rect.min;

    for cell in 0..total_cells.min(display_rows * cols) {
        let sector_start = (cell * sectors_per_cell) as u64;
        let sector_end =
            ((cell + 1) * sectors_per_cell).min(total_sectors) as u64;

        let has_diff = (sector_start..sector_end)
            .any(|s| diff_sectors.contains(&s));

        let color = if has_diff {
            theme::COLOR_DIFF
        } else {
            theme::COLOR_SECTOR_BLANK
        };

        let col = cell % cols;
        let row = cell / cols;
        let x = origin.x + col as f32 * (cell_size + 1.0);
        let y = origin.y + row as f32 * (cell_size + 1.0);

        painter.rect_filled(
            egui::Rect::from_min_size(
                egui::pos2(x, y),
                egui::vec2(cell_size, cell_size),
            ),
            0.0,
            color,
        );
    }

    // Legend
    ui.add_space(4.0);
    ui.horizontal(|ui| {
        let legend = |ui: &mut egui::Ui, color: egui::Color32, label: &str| {
            let (rect, _) =
                ui.allocate_exact_size(egui::vec2(12.0, 12.0), egui::Sense::hover());
            ui.painter().rect_filled(rect, 0.0, color);
            ui.label(label);
        };
        legend(ui, theme::COLOR_SECTOR_BLANK, "Same");
        legend(ui, theme::COLOR_DIFF, "Different");
    });
}
