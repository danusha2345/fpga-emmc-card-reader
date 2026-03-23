use eframe::egui;
use emmc_core::card_info::ExtCsdInfo;
use programmer_engine::command::Command;

use crate::app::ProgrammerApp;
use crate::theme;
use crate::widgets;

pub fn show_chip_info_panel(ui: &mut egui::Ui, app: &mut ProgrammerApp) {
    ui.heading("Chip Information");
    ui.add_space(theme::SECTION_SPACING);

    let connected = app.state.connected && !app.state.is_busy();

    ui.horizontal(|ui| {
        if ui
            .add_enabled(connected, egui::Button::new("Identify"))
            .clicked()
        {
            app.dispatch_command(Command::Identify);
        }
        if ui
            .add_enabled(connected, egui::Button::new("Read ExtCSD"))
            .clicked()
        {
            app.dispatch_command(Command::ReadExtCsd);
        }
        if ui
            .add_enabled(connected, egui::Button::new("Status"))
            .clicked()
        {
            app.dispatch_command(Command::ControllerStatus);
        }
        if ui
            .add_enabled(connected, egui::Button::new("Reinit"))
            .clicked()
        {
            app.dispatch_command(Command::Reinit);
        }
    });

    ui.add_space(theme::SECTION_SPACING);

    // CID info
    if let Some(ref info) = app.state.chip_info {
        // Dead eMMC detection: MID=0x65 + Product "M MOR"
        if info.manufacturer_id == 0x65 && info.product_name.trim().starts_with("M MOR") {
            ui.colored_label(
                theme::COLOR_ERROR,
                "⚠ DEAD eMMC DETECTED — MID=0x65 / \"M MOR\"",
            );
            ui.label(
                "Fallback CID from failed NAND controller. \
                 Common causes: water damage, ESD, NAND wear-out. \
                 All metadata is invalid. Chip is NOT recoverable.",
            );
            ui.add_space(theme::SECTION_SPACING);
        }

        egui::Grid::new("chip_info_grid")
            .num_columns(2)
            .striped(true)
            .show(ui, |ui| {
                ui.label("Type:");
                ui.label(info.chip_type.to_string());
                ui.end_row();

                ui.label("Manufacturer:");
                let mfr_text = if let Some(ref country) = info.manufacturer_country {
                    format!(
                        "{} (MID=0x{:02X}, {})",
                        info.manufacturer, info.manufacturer_id, country
                    )
                } else {
                    format!(
                        "{} (MID=0x{:02X})",
                        info.manufacturer, info.manufacturer_id
                    )
                };
                ui.label(mfr_text);
                ui.end_row();

                ui.label("Product:");
                if let Some(ref series) = info.product_series {
                    ui.label(format!("{} [{}]", info.product_name, series));
                } else {
                    ui.label(&info.product_name);
                }
                ui.end_row();

                if let Some(ref nand) = info.nand_type {
                    ui.label("NAND:");
                    ui.label(nand);
                    ui.end_row();
                }

                if let Some(ref ver) = info.emmc_version {
                    ui.label("eMMC Version:");
                    ui.label(ver);
                    ui.end_row();
                }

                if let Some(ref notes) = info.product_notes {
                    ui.label("Notes:");
                    ui.label(notes);
                    ui.end_row();
                }

                if info.capacity_bytes > 0 {
                    ui.label("Capacity:");
                    let gb =
                        info.capacity_bytes as f64 / (1024.0 * 1024.0 * 1024.0);
                    ui.label(format!(
                        "{:.2} GB ({} sectors)",
                        gb,
                        info.capacity_bytes / 512
                    ));
                    ui.end_row();
                }

                if let Some(ref sn) = info.serial_number {
                    ui.label("Serial:");
                    ui.label(sn);
                    ui.end_row();
                }

                if let Some(ref rev) = info.revision {
                    ui.label("Revision:");
                    ui.label(rev);
                    ui.end_row();
                }

                if let Some(ref date) = info.date {
                    ui.label("Date:");
                    ui.label(date);
                    ui.end_row();
                }
            });

        // Raw CID hex
        ui.add_space(theme::GROUP_SPACING);
        ui.label("Raw CID:");
        let hex: Vec<String> =
            info.raw_id.iter().map(|b| format!("{:02X}", b)).collect();
        ui.monospace(hex.join(" "));
        // CSD Register (collapsible)
        if let Some(ref csd_raw) = info.csd_raw {
            ui.add_space(theme::GROUP_SPACING);
            ui.collapsing("CSD Register", |ui| {
                egui::Grid::new("csd_grid")
                    .num_columns(2)
                    .striped(true)
                    .show(ui, |ui| {
                        if let Some(structure) = info.csd_structure {
                            ui.label("Structure:");
                            ui.label(format!("{}", structure));
                            ui.end_row();
                        }
                        if let Some(spec_vers) = info.csd_spec_vers {
                            ui.label("Spec Version:");
                            ui.label(format!("{}", spec_vers));
                            ui.end_row();
                        }
                        ui.label("Raw:");
                        let hex: Vec<String> =
                            csd_raw.iter().map(|b| format!("{:02X}", b)).collect();
                        ui.monospace(hex.join(" "));
                        ui.end_row();
                    });
            });
        }
    } else {
        ui.label("No chip detected. Click 'Identify' to read chip info.");
    }

    // ExtCSD — parsed view
    if let Some(ref ext) = app.state.ext_csd_parsed {
        ui.add_space(theme::SECTION_SPACING);
        ui.separator();

        // Device Info section
        ui.heading("Device Info");
        ui.add_space(theme::GROUP_SPACING);

        egui::Grid::new("extcsd_device_info")
            .num_columns(2)
            .striped(true)
            .show(ui, |ui| {
                ui.label("Capacity:");
                let gb = ext.capacity_bytes as f64 / (1024.0 * 1024.0 * 1024.0);
                ui.label(format!(
                    "{:.2} GB ({} sectors)",
                    gb,
                    ext.capacity_bytes / 512
                ));
                ui.end_row();

                ui.label("FW Version:");
                ui.monospace(&ext.fw_version);
                ui.end_row();

                ui.label("Boot Partition Size:");
                let boot_kb = ext.boot_partition_size / 1024;
                ui.label(format!("{} KB", boot_kb));
                ui.end_row();

                ui.label("RPMB Size:");
                let rpmb_kb = ext.rpmb_size / 1024;
                ui.label(format!("{} KB", rpmb_kb));
                ui.end_row();
            });

        // Speed Modes section
        ui.add_space(theme::SECTION_SPACING);
        ui.heading("Speed Modes");
        ui.add_space(theme::GROUP_SPACING);

        ui.horizontal(|ui| {
            speed_badge(ui, "HS26", ext.hs_support);
            speed_badge(ui, "HS52", ext.hs52_support);
            speed_badge(ui, "DDR", ext.ddr_support);
        });

        // Boot Config section
        ui.add_space(theme::SECTION_SPACING);
        ui.heading("Boot Config");
        ui.add_space(theme::GROUP_SPACING);

        egui::Grid::new("extcsd_boot_config")
            .num_columns(2)
            .striped(true)
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

        // Health section
        ui.add_space(theme::SECTION_SPACING);
        ui.heading("Health");
        ui.add_space(theme::GROUP_SPACING);

        egui::Grid::new("extcsd_health")
            .num_columns(3)
            .spacing([12.0, 4.0])
            .show(ui, |ui| {
                // Life Time A
                ui.label("Life Time A:");
                let lta_str = ExtCsdInfo::life_time_str(ext.life_time_est_a);
                ui.colored_label(
                    life_time_color(ext.life_time_est_a),
                    format!("0x{:02X} — {}", ext.life_time_est_a, lta_str),
                );
                health_bar(ui, ext.life_time_est_a);
                ui.end_row();

                // Life Time B
                ui.label("Life Time B:");
                let ltb_str = ExtCsdInfo::life_time_str(ext.life_time_est_b);
                ui.colored_label(
                    life_time_color(ext.life_time_est_b),
                    format!("0x{:02X} — {}", ext.life_time_est_b, ltb_str),
                );
                health_bar(ui, ext.life_time_est_b);
                ui.end_row();

                // Pre-EOL
                ui.label("Pre-EOL:");
                let eol_str = ExtCsdInfo::pre_eol_str(ext.pre_eol_info);
                ui.colored_label(
                    pre_eol_color(ext.pre_eol_info),
                    format!("0x{:02X} — {}", ext.pre_eol_info, eol_str),
                );
                ui.label(""); // empty cell
                ui.end_row();
            });
    }

    // Raw ExtCSD hex dump (collapsible)
    if let Some(ref ext_csd) = app.state.ext_csd_raw {
        ui.add_space(theme::SECTION_SPACING);
        ui.collapsing("Full ExtCSD Hex (512 bytes)", |ui| {
            widgets::hex_view::show_hex_view(ui, ext_csd, 0);
        });
    }

    // Controller Status
    if let Some(ref status) = app.state.controller_status {
        ui.add_space(theme::SECTION_SPACING);
        ui.separator();
        ui.heading("Controller Status");
        ui.add_space(theme::GROUP_SPACING);

        egui::Grid::new("controller_status_grid")
            .num_columns(2)
            .striped(true)
            .show(ui, |ui| {
                ui.label("Init State:");
                ui.label(format!("{}", status.init_state));
                ui.end_row();

                ui.label("MC State:");
                ui.label(format!("{}", status.mc_state));
                ui.end_row();

                ui.label("CMD FSM:");
                ui.label(format!("{}", status.cmd_fsm));
                ui.end_row();

                ui.label("DAT FSM:");
                ui.label(format!("{}", status.dat_fsm));
                ui.end_row();

                ui.label("Pins:");
                ui.label(format!(
                    "CMD={} DAT0={}",
                    if status.cmd_pin { "H" } else { "L" },
                    if status.dat0_pin { "H" } else { "L" }
                ));
                ui.end_row();

                ui.label("Flags:");
                ui.label(format!(
                    "info_valid={} cmd_ready={} fast_clk={} reinit={}",
                    status.info_valid, status.cmd_ready,
                    status.use_fast_clk, status.reinit_pending
                ));
                ui.end_row();

                ui.label("Partition:");
                let part_names = ["User", "Boot0", "Boot1", "RPMB"];
                let part_name = part_names.get(status.partition as usize).unwrap_or(&"?");
                ui.label(format!("{} ({})", part_name, status.partition));
                ui.end_row();

                // Error counters
                ui.label("CMD Timeout:");
                let cnt_color = |v: u8| if v > 0 { theme::COLOR_WARNING } else { theme::COLOR_SUCCESS };
                ui.colored_label(cnt_color(status.cmd_timeout_cnt), format!("{}", status.cmd_timeout_cnt));
                ui.end_row();

                ui.label("CMD CRC Errors:");
                ui.colored_label(cnt_color(status.cmd_crc_err_cnt), format!("{}", status.cmd_crc_err_cnt));
                ui.end_row();

                ui.label("DAT Read Errors:");
                ui.colored_label(cnt_color(status.dat_rd_err_cnt), format!("{}", status.dat_rd_err_cnt));
                ui.end_row();

                ui.label("DAT Write Errors:");
                ui.colored_label(cnt_color(status.dat_wr_err_cnt), format!("{}", status.dat_wr_err_cnt));
                ui.end_row();

                ui.label("Init Retries:");
                ui.colored_label(cnt_color(status.init_retry_cnt), format!("{}", status.init_retry_cnt));
                ui.end_row();

                ui.label("Presets:");
                ui.label(format!("baud={} clk={}", status.baud_preset, status.clk_preset));
                ui.end_row();
            });
    }
}

fn life_time_color(val: u8) -> egui::Color32 {
    match val {
        0 => egui::Color32::GRAY,
        1..=5 => theme::COLOR_SUCCESS,
        6..=8 => theme::COLOR_WARNING,
        _ => theme::COLOR_ERROR,
    }
}

fn pre_eol_color(val: u8) -> egui::Color32 {
    match val {
        0 => egui::Color32::GRAY,
        1 => theme::COLOR_SUCCESS,
        2 => theme::COLOR_WARNING,
        3 => theme::COLOR_ERROR,
        _ => egui::Color32::GRAY,
    }
}

fn health_bar(ui: &mut egui::Ui, life_time_val: u8) {
    if life_time_val == 0 || life_time_val > 11 {
        ui.label("—");
        return;
    }
    // life_time_val: 1 = 0-10% used, so remaining = 100% - (val * 10)%
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
        (format!("{} OK", label), theme::COLOR_SUCCESS)
    } else {
        (format!("{} --", label), egui::Color32::GRAY)
    };
    ui.colored_label(color, text);
}
