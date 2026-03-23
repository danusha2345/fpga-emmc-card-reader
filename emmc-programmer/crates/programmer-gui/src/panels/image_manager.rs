use eframe::egui;
use programmer_engine::image;
use programmer_engine::state::ImageData;

use crate::app::ProgrammerApp;
use crate::theme;
use crate::widgets;

pub fn show_image_manager_panel(ui: &mut egui::Ui, app: &mut ProgrammerApp) {
    ui.heading("Image Manager");
    ui.add_space(theme::SECTION_SPACING);

    ui.horizontal(|ui| {
        if ui.button("Load Image A").clicked() {
            if let Some(path) = rfd::FileDialog::new().pick_file() {
                match std::fs::read(&path) {
                    Ok(data) => {
                        let size = data.len();
                        app.state.image_buffer = Some(ImageData {
                            path: path.display().to_string(),
                            data,
                        });
                        app.state.image_diff_cache = None; // invalidate
                        app.state.log.info(format!(
                            "Loaded image: {} ({} bytes, {} sectors)",
                            path.display(),
                            size,
                            size.div_ceil(512)
                        ));
                    }
                    Err(e) => {
                        app.state
                            .log
                            .error(format!("Failed to load: {}", e));
                    }
                }
            }
        }

        if ui.button("Load Image B (diff)").clicked() {
            if let Some(path) = rfd::FileDialog::new().pick_file() {
                match std::fs::read(&path) {
                    Ok(data) => {
                        app.state.image_diff_buffer = Some(ImageData {
                            path: path.display().to_string(),
                            data,
                        });
                        app.state.image_diff_cache = None; // invalidate
                        app.state.log.info(format!(
                            "Loaded diff image: {}",
                            path.display()
                        ));
                    }
                    Err(e) => {
                        app.state
                            .log
                            .error(format!("Failed to load: {}", e));
                    }
                }
            }
        }

        if app.state.image_buffer.is_some()
            && ui.button("Save Image").clicked()
        {
            if let Some(path) = rfd::FileDialog::new()
                .set_file_name("image.bin")
                .save_file()
            {
                if let Some(ref img) = app.state.image_buffer {
                    match std::fs::write(&path, &img.data) {
                        Ok(()) => {
                            app.state.log.info(format!(
                                "Saved: {}",
                                path.display()
                            ));
                        }
                        Err(e) => {
                            app.state
                                .log
                                .error(format!("Save failed: {}", e));
                        }
                    }
                }
            }
        }
    });

    ui.add_space(theme::SECTION_SPACING);

    // Image info
    if let Some(ref img) = app.state.image_buffer {
        ui.group(|ui| {
            ui.label(format!("Image A: {}", img.path));
            ui.label(format!(
                "Size: {} bytes ({} sectors)",
                img.data.len(),
                img.data.len().div_ceil(512)
            ));
        });
    }

    if let Some(ref img) = app.state.image_diff_buffer {
        ui.group(|ui| {
            ui.label(format!("Image B: {}", img.path));
            ui.label(format!(
                "Size: {} bytes ({} sectors)",
                img.data.len(),
                img.data.len().div_ceil(512)
            ));
        });
    }

    // Compute diff once (cached)
    if app.state.image_diff_cache.is_none() {
        if let (Some(ref a), Some(ref b)) =
            (&app.state.image_buffer, &app.state.image_diff_buffer)
        {
            let diffs = image::diff_slices(&a.data, &b.data);
            app.state.image_diff_cache = Some(diffs);
        }
    }

    // Show diff results from cache
    if let (Some(ref diffs), Some(ref a), Some(ref b)) = (
        &app.state.image_diff_cache,
        &app.state.image_buffer,
        &app.state.image_diff_buffer,
    ) {
        ui.add_space(theme::SECTION_SPACING);
        ui.separator();
        ui.heading("Binary Diff");

        if diffs.is_empty() {
            ui.colored_label(theme::COLOR_SUCCESS, "Images are identical");
        } else {
            ui.colored_label(
                theme::COLOR_WARNING,
                format!("{} sector(s) differ", diffs.len()),
            );

            egui::ScrollArea::vertical()
                .max_height(300.0)
                .show(ui, |ui| {
                    egui::Grid::new("diff_grid")
                        .num_columns(2)
                        .striped(true)
                        .show(ui, |ui| {
                            ui.strong("Sector LBA");
                            ui.strong("Offset");
                            ui.end_row();

                            for diff in diffs.iter().take(100) {
                                ui.label(diff.sector_lba.to_string());
                                ui.label(format!("0x{:08X}", diff.offset));
                                ui.end_row();
                            }
                            if diffs.len() > 100 {
                                ui.label(format!(
                                    "... and {} more",
                                    diffs.len() - 100
                                ));
                                ui.end_row();
                            }
                        });
                });
        }

        // Sector map visualization
        ui.add_space(theme::SECTION_SPACING);
        ui.separator();
        ui.heading("Sector Map");
        let total_sectors = a.data.len().max(b.data.len()) / 512;
        let diff_set: std::collections::HashSet<u64> =
            diffs.iter().map(|d| d.sector_lba).collect();
        widgets::sector_map::show_sector_map(ui, total_sectors, &diff_set);
    }
}
