use crossbeam_channel::Sender;
use eframe::egui;
use emmc_app::operations::{self, WorkerMessage};
use emmc_app::state::{AppState, EmmcPartition, SpeedProfile};

use crate::theme;

pub fn show_connection_panel(ui: &mut egui::Ui, state: &mut AppState, tx: &Sender<WorkerMessage>) {
    ui.heading("Connection");
    ui.separator();

    // Transport mode selection
    ui.label("Transport:");
    ui.horizontal(|ui| {
        if ui
            .selectable_label(!state.use_fifo, "UART")
            .clicked()
        {
            state.use_fifo = false;
        }
        let fifo_resp = ui.add_enabled(
            state.fifo_available,
            egui::Button::new("FIFO").selected(state.use_fifo),
        );
        if fifo_resp.clicked() && state.fifo_available {
            state.use_fifo = true;
        }
        if !state.fifo_available {
            fifo_resp.on_hover_text("No FT232H FIFO device found");
        }
    });

    if state.use_fifo {
        // FIFO mode: show device info + refresh
        ui.horizontal(|ui| {
            if let Some(info) = &state.fifo_device_info {
                ui.label(info.as_str());
            } else {
                ui.label("No FIFO device");
            }
            if ui
                .small_button("R")
                .on_hover_text("Refresh devices")
                .clicked()
            {
                operations::scan_fifo_devices(tx.clone(), state.log.clone());
                operations::scan_ports(tx.clone(), state.log.clone());
            }
        });
    } else {
        // UART mode: port selection
        ui.label("Port:");
        ui.horizontal(|ui| {
            egui::ComboBox::from_id_salt("port_select")
                .width(120.0)
                .selected_text(&state.selected_port)
                .show_ui(ui, |ui| {
                    for port in &state.available_ports {
                        ui.selectable_value(&mut state.selected_port, port.clone(), port);
                    }
                });
            if ui
                .small_button("R")
                .on_hover_text("Refresh ports")
                .clicked()
            {
                operations::scan_ports(tx.clone(), state.log.clone());
                operations::scan_fifo_devices(tx.clone(), state.log.clone());
            }
        });
    }

    // Pre-connect settings (only when disconnected)
    if !state.connected {
        if !state.use_fifo {
            // Initial baud (adapter-dependent, UART only)
            ui.label("Initial Baud:");
            egui::ComboBox::from_id_salt("initial_baud")
                .width(220.0)
                .selected_text(match state.initial_baud {
                    2_000_000 => "2M (FT2232C clone)",
                    _ => "3 Mbaud",
                })
                .show_ui(ui, |ui| {
                    ui.selectable_value(
                        &mut state.initial_baud,
                        3_000_000,
                        "3 Mbaud (default)",
                    );
                    ui.selectable_value(
                        &mut state.initial_baud,
                        2_000_000,
                        "2M (FT2232C clone → 3M)",
                    );
                });
        }

        // Speed profile (eMMC clock preset applies to both UART and FIFO)
        ui.label("Speed Profile:");
        egui::ComboBox::from_id_salt("speed_profile")
            .width(220.0)
            .selected_text(state.speed_profile.label())
            .show_ui(ui, |ui| {
                for profile in SpeedProfile::all() {
                    ui.selectable_value(&mut state.speed_profile, *profile, profile.label());
                }
            });
    }

    ui.add_space(8.0);

    // Connect / Disconnect
    if state.connected {
        // Show current speed as colored status
        let clk_str = match state.current_emmc_freq {
            10_000_000 => "10 MHz",
            6_000_000 => "6 MHz",
            3_750_000 => "3.75 MHz",
            _ => "2 MHz",
        };
        if state.use_fifo {
            ui.colored_label(
                theme::COLOR_CONNECTED,
                format!("Connected  FIFO, eMMC: {}", clk_str),
            );
        } else {
            let baud_str = match state.current_baud {
                12_000_000 => "12M",
                6_000_000 => "6M",
                _ => "3M",
            };
            ui.colored_label(
                theme::COLOR_CONNECTED,
                format!("Connected  UART: {}, eMMC: {}", baud_str, clk_str),
            );
        }
        ui.add_space(4.0);

        if ui
            .add_enabled(!state.is_busy(), egui::Button::new("Disconnect"))
            .clicked()
        {
            state.connected = false;
            state.cid_info = None;
            state.csd_info = None;
            state.ext_csd_info = None;
            state.partition_table = None;
            state.ext4_info = None;
            state.log.info("Disconnected");
            state.set_completed("Disconnected");
        }
    } else {
        ui.colored_label(theme::COLOR_DISCONNECTED, "Disconnected");
        ui.add_space(4.0);

        let can_connect = !state.is_busy()
            && (state.use_fifo || !state.selected_port.is_empty());
        if ui
            .add_enabled(can_connect, egui::Button::new("Connect"))
            .clicked()
        {
            state.set_running("Connecting...");
            operations::connect(
                state.effective_port(),
                state.initial_baud,
                state.speed_profile,
                tx.clone(),
                state.log.clone(),
            );
        }
    }

    ui.separator();

    // Active partition
    ui.label("Partition:");
    ui.horizontal_wrapped(|ui| {
        for part in &[
            EmmcPartition::User,
            EmmcPartition::Boot0,
            EmmcPartition::Boot1,
            EmmcPartition::RPMB,
        ] {
            let selected = state.active_partition == *part;
            let enabled = state.connected && !state.is_busy();
            let is_rpmb = *part == EmmcPartition::RPMB;
            let button = if is_rpmb {
                egui::Button::new(
                    egui::RichText::new(part.label()).color(theme::COLOR_ORANGE),
                )
                .selected(selected)
            } else {
                egui::Button::new(part.label()).selected(selected)
            };
            let response = ui.add_enabled(enabled, button);
            if is_rpmb {
                response.clone().on_hover_text(
                    "WARNING: RPMB requires authenticated frame protocol.\n\
                     Plain CMD17/CMD24 is a JEDEC protocol violation\n\
                     that can BRICK the eMMC controller!",
                );
            }
            if response.clicked() {
                if is_rpmb {
                    state.confirm_dialog = Some(emmc_app::state::ConfirmDialog::new(
                        "RPMB Warning",
                        "RPMB requires authenticated frame protocol (CMD23+CMD25+CMD23+CMD18).\n\
                         Our FPGA sends plain CMD17/CMD24 which is a JEDEC protocol violation.\n\
                         This can BRICK the eMMC controller!\n\n\
                         Incident: YMTC 64GB eMMC entered irreversible error state after CMD17 on RPMB.\n\n\
                         Switch to RPMB anyway?",
                        "set_partition_rpmb",
                    ));
                } else {
                    state.active_partition = *part;
                    state.set_running(format!("Switching to {}...", part.label()));
                    operations::set_partition(
                        state.effective_port(),
                        state.selected_baud,
                        part.id(),
                        tx.clone(),
                        state.log.clone(),
                    );
                }
            }
        }
    });

    // Manual speed control (when connected, collapsible)
    if state.connected {
        ui.collapsing("Speed Control", |ui| {
            let enabled = !state.is_busy();

            // eMMC Clock speed (applies to both UART and FIFO)
            ui.label("eMMC Clock:");
            let clk_names = [
                "2 MHz", "3.75 MHz", "6 MHz", "10 MHz", "15 MHz", "15 MHz", "30 MHz",
            ];
            let current_name = clk_names.get(state.selected_clk_preset).unwrap_or(&"?");
            egui::ComboBox::from_id_salt("clk_preset")
                .width(90.0)
                .selected_text(*current_name)
                .show_ui(ui, |ui| {
                    for (i, name) in clk_names.iter().enumerate() {
                        if ui
                            .add_enabled(
                                enabled,
                                egui::Button::new(*name).selected(state.selected_clk_preset == i),
                            )
                            .clicked()
                        {
                            state.pending_action = Some(format!("set_clock:{}", i));
                        }
                    }
                });

            // UART Baud speed (hidden in FIFO mode)
            if !state.use_fifo {
                ui.label("UART Baud:");
                let presets: [(u8, &str); 3] =
                    [(0, "3 Mbaud"), (1, "6 Mbaud"), (3, "12 Mbaud")];
                let current_name = presets
                    .iter()
                    .find(|(p, _)| *p as usize == state.selected_baud_preset)
                    .map(|(_, n)| *n)
                    .unwrap_or("?");
                egui::ComboBox::from_id_salt("baud_preset")
                    .width(100.0)
                    .selected_text(current_name)
                    .show_ui(ui, |ui| {
                        for (preset, name) in &presets {
                            if ui
                                .add_enabled(
                                    enabled,
                                    egui::Button::new(*name)
                                        .selected(state.selected_baud_preset == *preset as usize),
                                )
                                .clicked()
                            {
                                state.pending_action = Some(format!("set_baud:{}", preset));
                            }
                        }
                    });
            }

            // Bus width (applies to both UART and FIFO)
            ui.label("Bus Width:");
            ui.horizontal(|ui| {
                for (width, name) in [(1u8, "1-bit"), (4, "4-bit")] {
                    let selected = state.bus_width == width;
                    if ui
                        .add_enabled(enabled, egui::Button::new(name).selected(selected))
                        .clicked()
                    {
                        state.pending_action = Some(format!("set_bus_width:{}", width));
                    }
                }
            });
        });
    }

    // Cancel button
    if state.is_busy() {
        ui.separator();
        ui.horizontal(|ui| {
            ui.spinner();
            if ui.button("Cancel").clicked() {
                state.cancel_operation();
            }
        });
    }

    // Progress
    if let Some(progress) = &state.operation_progress {
        ui.add(egui::ProgressBar::new(progress.fraction()).text(&progress.description));
    }

    // Quick actions
    if state.connected && !state.is_busy() {
        ui.separator();
        ui.horizontal(|ui| {
            if ui
                .button("Status")
                .on_hover_text("Controller debug status (12 bytes)")
                .clicked()
            {
                state.pending_action = Some("controller_status".to_string());
            }
            if ui
                .button("Card Status")
                .on_hover_text("CMD13 SEND_STATUS")
                .clicked()
            {
                state.pending_action = Some("card_status".to_string());
            }
            if ui
                .button("Re-Init")
                .on_hover_text("CMD0 + full init sequence")
                .clicked()
            {
                state.pending_action = Some("reinit".to_string());
            }
        });
    }

    // Raw eMMC CMD
    if state.connected && !state.is_busy() {
        ui.separator();
        ui.label("Raw eMMC CMD:");
        ui.horizontal(|ui| {
            ui.label("CMD");
            ui.add(
                egui::TextEdit::singleline(&mut state.raw_cmd_index)
                    .desired_width(30.0)
                    .hint_text("13"),
            );
            ui.label("Arg");
            ui.add(
                egui::TextEdit::singleline(&mut state.raw_cmd_arg)
                    .desired_width(90.0)
                    .hint_text("0x00010000"),
            );
        });
        ui.horizontal(|ui| {
            ui.checkbox(&mut state.raw_cmd_resp, "Response");
            ui.checkbox(&mut state.raw_cmd_long, "Long (R2)");
            ui.checkbox(&mut state.raw_cmd_busy, "Busy wait");
        });
        let can_send = !state.raw_cmd_index.is_empty();
        if ui
            .add_enabled(can_send, egui::Button::new("Send"))
            .clicked()
        {
            let flags = (state.raw_cmd_resp as u8)
                | ((state.raw_cmd_long as u8) << 1)
                | ((state.raw_cmd_busy as u8) << 2);
            let arg = state.raw_cmd_arg.trim().trim_start_matches("0x");
            let arg_clean = if arg.is_empty() { "0" } else { arg };
            state.pending_action = Some(format!(
                "raw_cmd:{}:{}:{}",
                state.raw_cmd_index.trim(),
                arg_clean,
                flags
            ));
        }
        if let Some(result) = &state.raw_cmd_result {
            ui.label(result);
        }
    }

    // Controller status display
    if let Some(cs) = &state.controller_status {
        ui.separator();
        ui.label(format!(
            "init={}({}) mc={}({})",
            cs.init_state,
            cs.init_state_name(),
            cs.mc_state,
            cs.mc_state_name(),
        ));
        ui.label(format!(
            "info={} ready={} fast_clk={} part={} clk={} baud={}",
            cs.info_valid as u8,
            cs.cmd_ready as u8,
            cs.use_fast_clk as u8,
            cs.partition_name(),
            cs.clk_preset_name(),
            cs.baud_preset_name(),
        ));
        ui.label(format!(
            "CMD={} DAT0={} cmd_fsm={} dat_fsm={}",
            cs.cmd_pin as u8,
            cs.dat0_pin as u8,
            cs.cmd_fsm_name(),
            cs.dat_fsm_name(),
        ));
        if cs.cmd_timeout_cnt > 0
            || cs.cmd_crc_err_cnt > 0
            || cs.dat_rd_err_cnt > 0
            || cs.dat_wr_err_cnt > 0
        {
            ui.colored_label(
                theme::COLOR_WARNING,
                format!(
                    "errs: to={} crc={} rd={} wr={}",
                    cs.cmd_timeout_cnt, cs.cmd_crc_err_cnt, cs.dat_rd_err_cnt, cs.dat_wr_err_cnt,
                ),
            );
        }
        if cs.init_retry_cnt > 0 {
            ui.label(format!("init_retries={}", cs.init_retry_cnt));
        }
    }

    // Card summary
    if let Some(cid) = &state.cid_info {
        ui.separator();
        ui.label(format!("{} {}", cid.manufacturer_name(), cid.product_name));
        if let Some(ext) = &state.ext_csd_info {
            ui.label(ext.capacity_human());
        }
    }
}
