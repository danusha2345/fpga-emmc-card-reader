use crossbeam_channel::Sender;
use eframe::egui;
use emmc_app::operations::{self, WorkerMessage};
use emmc_app::state::AppState;
use emmc_core::card_info::ExtCsdInfo;

pub fn show_card_info_panel(ui: &mut egui::Ui, state: &mut AppState, tx: &Sender<WorkerMessage>) {
    ui.heading("eMMC Info");

    if !state.connected {
        ui.label("Not connected.");
        return;
    }

    // Dead eMMC detection — before CID section
    if let Some(cid) = &state.cid_info {
        if cid.manufacturer_id == 0x65 && cid.product_name.trim().starts_with("M MOR") {
            ui.add_space(4.0);
            ui.colored_label(
                egui::Color32::from_rgb(255, 80, 80),
                "\u{26a0} DEAD eMMC DETECTED \u{2014} MID=0x65 / \"M MOR\"",
            );
            ui.label(
                "Fallback CID from failed NAND controller. \
                 Common causes: water damage, ESD, NAND wear-out. \
                 All metadata is invalid. Chip is NOT recoverable.",
            );
            ui.add_space(8.0);
        }
    }

    // CID info
    if let Some(cid) = &state.cid_info {
        ui.collapsing("CID Register", |ui| {
            egui::Grid::new("cid_grid")
                .num_columns(2)
                .spacing([8.0, 4.0])
                .show(ui, |ui| {
                    ui.label("Manufacturer:");
                    ui.label(format!(
                        "{} (0x{:02X})",
                        cid.manufacturer_name(),
                        cid.manufacturer_id
                    ));
                    ui.end_row();

                    ui.label("Device Type:");
                    ui.label(format!("0x{:04X}", cid.device_type));
                    ui.end_row();

                    ui.label("Product Name:");
                    ui.label(&cid.product_name);
                    ui.end_row();

                    ui.label("Revision:");
                    ui.label(&cid.product_rev);
                    ui.end_row();

                    ui.label("Serial:");
                    ui.label(format!("{}", cid.serial_number));
                    ui.end_row();

                    ui.label("Mfg Date:");
                    ui.label(&cid.mfg_date);
                    ui.end_row();

                    ui.label("Raw:");
                    let hex: String = cid
                        .raw
                        .iter()
                        .map(|b| format!("{:02X}", b))
                        .collect::<Vec<_>>()
                        .join(" ");
                    ui.monospace(&hex);
                    ui.end_row();
                });
        });
    }

    // CSD info
    if let Some(csd) = &state.csd_info {
        ui.collapsing("CSD Register", |ui| {
            egui::Grid::new("csd_grid")
                .num_columns(2)
                .spacing([8.0, 4.0])
                .show(ui, |ui| {
                    ui.label("Structure:");
                    ui.label(format!("{}", csd.structure));
                    ui.end_row();

                    ui.label("Spec Version:");
                    ui.label(format!("{}", csd.spec_vers));
                    ui.end_row();

                    ui.label("Read BL Len:");
                    ui.label(format!("{}", csd.read_bl_len));
                    ui.end_row();

                    if let Some(cap) = csd.capacity_bytes {
                        ui.label("Capacity:");
                        ui.label(emmc_core::card_info::format_size(cap));
                        ui.end_row();
                    }
                    if let Some(note) = &csd.capacity_note {
                        ui.label("Note:");
                        ui.label(note);
                        ui.end_row();
                    }

                    ui.label("Raw:");
                    let hex: String = csd
                        .raw
                        .iter()
                        .map(|b| format!("{:02X}", b))
                        .collect::<Vec<_>>()
                        .join(" ");
                    ui.monospace(&hex);
                    ui.end_row();
                });
        });
    }

    // Extended CSD
    ui.separator();
    ui.horizontal(|ui| {
        ui.heading("Extended CSD");
        if ui
            .add_enabled(
                state.connected && !state.is_busy(),
                egui::Button::new("Read"),
            )
            .clicked()
        {
            state.set_running("Reading ExtCSD...");
            operations::read_ext_csd(
                state.effective_port(),
                state.selected_baud,
                tx.clone(),
                state.log.clone(),
            );
        }
    });

    if let Some(ext) = &state.ext_csd_info {
        // --- Device Info ---
        ui.add_space(8.0);
        ui.heading("Device Info");
        ui.add_space(4.0);

        egui::Grid::new("extcsd_device_info")
            .num_columns(2)
            .striped(true)
            .spacing([8.0, 4.0])
            .show(ui, |ui| {
                ui.label("Capacity:");
                ui.label(format!(
                    "{} ({} sectors)",
                    ext.capacity_human(),
                    ext.sec_count
                ));
                ui.end_row();

                ui.label("FW Version:");
                ui.monospace(&ext.fw_version);
                ui.end_row();

                ui.label("Boot Partition Size:");
                ui.label(ext.boot_size_human());
                ui.end_row();

                ui.label("RPMB Size:");
                ui.label(ext.rpmb_size_human());
                ui.end_row();
            });

        // --- Speed Modes ---
        ui.add_space(8.0);
        ui.heading("Speed Modes");
        ui.add_space(4.0);

        ui.horizontal(|ui| {
            speed_badge(ui, "HS26", ext.hs_support);
            speed_badge(ui, "HS52", ext.hs52_support);
            speed_badge(ui, "DDR", ext.ddr_support);
        });

        // --- Boot Config ---
        ui.add_space(8.0);
        ui.heading("Boot Config");
        ui.add_space(4.0);

        egui::Grid::new("extcsd_boot_config")
            .num_columns(2)
            .striped(true)
            .spacing([8.0, 4.0])
            .show(ui, |ui| {
                ui.label("Boot ACK:");
                ui.label(if ext.boot_ack { "Enabled" } else { "Disabled" });
                ui.end_row();

                ui.label("Boot Partition:");
                let boot_part_name = match ext.boot_partition {
                    0 => "Not enabled",
                    1 => "Boot0",
                    2 => "Boot1",
                    7 => "User area",
                    _ => "Reserved",
                };
                ui.label(format!("{} ({})", boot_part_name, ext.boot_partition));
                ui.end_row();

                ui.label("Partition Access:");
                let access_name = match ext.partition_access {
                    0 => "User area",
                    1 => "Boot0",
                    2 => "Boot1",
                    3 => "RPMB",
                    _ => "GP partition",
                };
                ui.label(format!("{} ({})", access_name, ext.partition_access));
                ui.end_row();
            });

        // --- Health ---
        ui.add_space(8.0);
        ui.heading("Health");
        ui.add_space(4.0);

        egui::Grid::new("extcsd_health")
            .num_columns(3)
            .spacing([12.0, 4.0])
            .show(ui, |ui| {
                // Life Time A
                ui.label("Life Time A:");
                let lta_str = ExtCsdInfo::life_time_str(ext.life_time_est_a);
                ui.colored_label(
                    life_time_color(ext.life_time_est_a),
                    format!("0x{:02X} \u{2014} {}", ext.life_time_est_a, lta_str),
                );
                health_bar(ui, ext.life_time_est_a);
                ui.end_row();

                // Life Time B
                ui.label("Life Time B:");
                let ltb_str = ExtCsdInfo::life_time_str(ext.life_time_est_b);
                ui.colored_label(
                    life_time_color(ext.life_time_est_b),
                    format!("0x{:02X} \u{2014} {}", ext.life_time_est_b, ltb_str),
                );
                health_bar(ui, ext.life_time_est_b);
                ui.end_row();

                // Pre-EOL
                ui.label("Pre-EOL:");
                let eol_str = ExtCsdInfo::pre_eol_str(ext.pre_eol_info);
                ui.colored_label(
                    pre_eol_color(ext.pre_eol_info),
                    format!("0x{:02X} \u{2014} {}", ext.pre_eol_info, eol_str),
                );
                ui.label(""); // empty cell for 3-column alignment
                ui.end_row();
            });
    }
}

fn life_time_color(val: u8) -> egui::Color32 {
    match val {
        0 => egui::Color32::GRAY,
        1..=5 => egui::Color32::from_rgb(80, 200, 120),
        6..=8 => egui::Color32::from_rgb(255, 180, 0),
        _ => egui::Color32::from_rgb(255, 80, 80),
    }
}

fn pre_eol_color(val: u8) -> egui::Color32 {
    match val {
        0 => egui::Color32::GRAY,
        1 => egui::Color32::from_rgb(80, 200, 120),
        2 => egui::Color32::from_rgb(255, 180, 0),
        3 => egui::Color32::from_rgb(255, 80, 80),
        _ => egui::Color32::GRAY,
    }
}

fn health_bar(ui: &mut egui::Ui, life_time_val: u8) {
    if life_time_val == 0 || life_time_val > 11 {
        ui.label("\u{2014}");
        return;
    }
    let used_frac = (life_time_val as f32 * 10.0).min(100.0) / 100.0;
    let remaining = 1.0 - used_frac;
    let color = life_time_color(life_time_val);
    ui.add(
        egui::ProgressBar::new(remaining)
            .desired_width(120.0)
            .fill(color)
            .text(format!("{}% remaining", (remaining * 100.0) as u32)),
    );
}

fn speed_badge(ui: &mut egui::Ui, label: &str, supported: bool) {
    let (text, color) = if supported {
        (format!("{} OK", label), egui::Color32::from_rgb(80, 200, 120))
    } else {
        (format!("{} --", label), egui::Color32::GRAY)
    };
    ui.colored_label(color, text);
}
