use eframe::egui;
use programmer_engine::command::Command;
use programmer_engine::operations;
use programmer_engine::state::SpeedProfile;

use crate::app::ProgrammerApp;
use crate::theme;

pub fn show_connection_panel(ui: &mut egui::Ui, app: &mut ProgrammerApp) {
    ui.heading("Connection");
    ui.add_space(theme::SECTION_SPACING);

    // Connection status
    let (status_text, status_color) = if app.state.connected {
        ("Connected", theme::COLOR_CONNECTED)
    } else {
        ("Disconnected", theme::COLOR_DISCONNECTED)
    };
    ui.colored_label(status_color, status_text);
    ui.add_space(theme::GROUP_SPACING);

    // Transport mode
    ui.label("Transport:");
    ui.horizontal(|ui| {
        if ui
            .selectable_label(!app.state.use_fifo, "UART")
            .clicked()
        {
            app.state.use_fifo = false;
        }
        let fifo_resp = ui.add_enabled(
            app.state.fifo_available,
            egui::Button::new("FIFO").selected(app.state.use_fifo),
        );
        if fifo_resp.clicked() && app.state.fifo_available {
            app.state.use_fifo = true;
        }
        if !app.state.fifo_available {
            fifo_resp.on_hover_text("No FT232H FIFO device found");
        }
    });

    if app.state.use_fifo {
        ui.horizontal(|ui| {
            if let Some(ref info) = app.state.fifo_device_info {
                ui.label(info.as_str());
            } else {
                ui.label("No FIFO device");
            }
            if ui.small_button("Refresh").clicked() {
                operations::scan_fifo_devices(app.worker_tx.clone(), app.state.log.clone());
                operations::scan_ports(app.worker_tx.clone(), app.state.log.clone());
            }
        });
    } else {
        // Port selection (UART only)
        ui.label("Port:");
        let port_count = app.state.available_ports.len();
        egui::ComboBox::from_id_salt("port_select")
            .width(ui.available_width() - 40.0)
            .selected_text(if app.state.selected_port.is_empty() {
                "No ports found"
            } else {
                &app.state.selected_port
            })
            .show_ui(ui, |ui| {
                for port in &app.state.available_ports {
                    ui.selectable_value(
                        &mut app.state.selected_port,
                        port.clone(),
                        port,
                    );
                }
            });

        if ui.small_button("Refresh").clicked() {
            operations::scan_ports(app.worker_tx.clone(), app.state.log.clone());
            operations::scan_fifo_devices(app.worker_tx.clone(), app.state.log.clone());
        }
        let _ = port_count;
    }

    ui.add_space(theme::GROUP_SPACING);

    // Speed profile
    ui.label("Speed:");
    egui::ComboBox::from_id_salt("speed_profile")
        .width(ui.available_width())
        .selected_text(app.state.speed_profile.label())
        .show_ui(ui, |ui| {
            for profile in SpeedProfile::all() {
                ui.selectable_value(
                    &mut app.state.speed_profile,
                    *profile,
                    profile.label(),
                );
            }
        });

    ui.add_space(theme::SECTION_SPACING);

    // Connect / Disconnect
    let can_connect = !app.state.is_busy()
        && (app.state.use_fifo || !app.state.selected_port.is_empty());
    if !app.state.connected {
        if ui
            .add_enabled(can_connect, egui::Button::new("Connect"))
            .clicked()
        {
            app.do_connect();
        }
    } else if ui
        .add_enabled(!app.state.is_busy(), egui::Button::new("Disconnect"))
        .clicked()
    {
        app.do_disconnect();
    }

    ui.add_space(theme::SECTION_SPACING);
    ui.separator();
    ui.add_space(theme::GROUP_SPACING);

    // Backend info
    if app.state.use_fifo {
        ui.label("Backend: FT245 FIFO");
    } else {
        ui.label("Backend: FPGA UART");
    }

    if app.state.connected {
        if !app.state.use_fifo {
            ui.label(format!("Baud: {}", app.state.current_baud));
        }

        let clk_names = [
            "2 MHz",
            "3.75 MHz",
            "6 MHz",
            "10 MHz",
            "15 MHz",
            "15 MHz",
            "30 MHz",
        ];
        let clk_name = clk_names
            .get(app.state.selected_clk_preset)
            .unwrap_or(&"?");
        ui.label(format!("eMMC CLK: {}", clk_name));

        // Bus width
        let bus_label = if app.state.bus_width == 4 { "Bus: 4-bit" } else { "Bus: 1-bit" };
        ui.label(bus_label);
        let not_busy = !app.state.is_busy();
        ui.horizontal(|ui| {
            if ui
                .add_enabled(not_busy, egui::Button::new("1-bit").small().selected(app.state.bus_width == 1))
                .clicked()
            {
                app.dispatch_command(Command::SetBusWidth(1));
            }
            if ui
                .add_enabled(not_busy, egui::Button::new("4-bit").small().selected(app.state.bus_width == 4))
                .clicked()
            {
                app.dispatch_command(Command::SetBusWidth(4));
            }
        });

        // Partition selector
        let part_names = ["User", "Boot0", "Boot1", "RPMB"];
        let part_label = part_names.get(app.state.active_partition as usize).unwrap_or(&"?");
        ui.label(format!("Partition: {}", part_label));
        ui.horizontal(|ui| {
            for (id, name) in part_names.iter().enumerate() {
                let selected = app.state.active_partition == id as u8;
                let btn = if id == 3 {
                    // RPMB gets warning color
                    egui::Button::new(*name).small().selected(selected)
                } else {
                    egui::Button::new(*name).small().selected(selected)
                };
                let resp = ui.add_enabled(not_busy, btn);
                if id == 3 {
                    let resp = resp.on_hover_text("WARNING: RPMB requires authenticated access");
                    if resp.clicked() {
                        app.dispatch_command(Command::SetPartition(id as u8));
                    }
                } else if resp.clicked() {
                    app.dispatch_command(Command::SetPartition(id as u8));
                }
            }
        });
    }

    // Chip summary
    if let Some(ref info) = app.state.chip_info {
        ui.add_space(theme::SECTION_SPACING);
        ui.separator();
        ui.add_space(theme::GROUP_SPACING);
        ui.heading("Chip");
        ui.label(format!("{} {}", info.manufacturer, info.product_name));
        if info.capacity_bytes > 0 {
            let gb = info.capacity_bytes as f64 / (1024.0 * 1024.0 * 1024.0);
            ui.label(format!("{:.1} GB", gb));
        }
    }
}
