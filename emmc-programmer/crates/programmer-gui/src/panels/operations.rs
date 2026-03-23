use eframe::egui;
use programmer_engine::command::Command;

use crate::app::ProgrammerApp;
use crate::theme;

pub fn show_operations_panel(ui: &mut egui::Ui, app: &mut ProgrammerApp) {
    ui.heading("Operations");
    ui.add_space(theme::SECTION_SPACING);

    let connected = app.state.connected && !app.state.is_busy();

    // Read section
    ui.group(|ui| {
        ui.label("Read Sectors");
        ui.horizontal(|ui| {
            ui.label("LBA:");
            ui.add(
                egui::TextEdit::singleline(&mut app.state.sector_lba_input)
                    .desired_width(100.0),
            );
            ui.label("Count:");
            ui.add(
                egui::TextEdit::singleline(&mut app.state.sector_count_input)
                    .desired_width(80.0),
            );
        });
        ui.horizontal(|ui| {
            if ui
                .add_enabled(connected, egui::Button::new("Read to Hex"))
                .clicked()
            {
                if let (Ok(lba), Ok(count)) = (
                    app.state.sector_lba_input.parse::<u32>(),
                    app.state.sector_count_input.parse::<u32>(),
                ) {
                    app.dispatch_command(Command::ReadSectors {
                        lba,
                        count,
                        path: None,
                    });
                }
            }
            if ui
                .add_enabled(connected, egui::Button::new("Read to File"))
                .clicked()
            {
                if let (Ok(lba), Ok(count)) = (
                    app.state.sector_lba_input.parse::<u32>(),
                    app.state.sector_count_input.parse::<u32>(),
                ) {
                    if let Some(path) = rfd::FileDialog::new()
                        .set_file_name("sectors.bin")
                        .save_file()
                    {
                        app.dispatch_command(Command::ReadSectors {
                            lba,
                            count,
                            path: Some(path),
                        });
                    }
                }
            }
        });
    });

    ui.add_space(theme::SECTION_SPACING);

    // Write section
    ui.group(|ui| {
        ui.label("Write Sectors");
        ui.horizontal(|ui| {
            ui.label("LBA:");
            ui.add(
                egui::TextEdit::singleline(&mut app.state.sector_lba_input)
                    .desired_width(100.0),
            );
            ui.checkbox(&mut app.state.verify_after_write, "Verify");
        });
        if ui
            .add_enabled(connected, egui::Button::new("Write from File"))
            .clicked()
        {
            if let Ok(lba) = app.state.sector_lba_input.parse::<u32>() {
                if let Some(path) = rfd::FileDialog::new().pick_file() {
                    app.dispatch_command(Command::WriteSectors {
                        lba,
                        path,
                        verify: app.state.verify_after_write,
                    });
                }
            }
        }
    });

    ui.add_space(theme::SECTION_SPACING);

    // Erase section
    ui.group(|ui| {
        ui.label("Erase");
        ui.horizontal(|ui| {
            ui.label("LBA:");
            ui.add(
                egui::TextEdit::singleline(&mut app.state.sector_lba_input)
                    .desired_width(100.0),
            );
            ui.label("Count:");
            ui.add(
                egui::TextEdit::singleline(&mut app.state.sector_count_input)
                    .desired_width(80.0),
            );
        });
        ui.horizontal(|ui| {
            if ui
                .add_enabled(connected, egui::Button::new("Erase"))
                .clicked()
            {
                if let (Ok(lba), Ok(count)) = (
                    app.state.sector_lba_input.parse::<u32>(),
                    app.state.sector_count_input.parse::<u32>(),
                ) {
                    app.dispatch_command(Command::Erase { lba, count });
                }
            }
            if ui
                .add_enabled(connected, egui::Button::new("Secure Erase"))
                .on_hover_text("CMD38 with arg=0x80000000")
                .clicked()
            {
                if let (Ok(lba), Ok(count)) = (
                    app.state.sector_lba_input.parse::<u32>(),
                    app.state.sector_count_input.parse::<u32>(),
                ) {
                    app.dispatch_command(Command::SecureErase { lba, count });
                }
            }
        });
    });

    ui.add_space(theme::SECTION_SPACING);

    // Verify / Blank Check
    ui.group(|ui| {
        ui.label("Verify / Blank Check");
        ui.horizontal(|ui| {
            if ui
                .add_enabled(connected, egui::Button::new("Verify against File"))
                .clicked()
            {
                if let Ok(lba) = app.state.sector_lba_input.parse::<u32>() {
                    if let Some(path) = rfd::FileDialog::new().pick_file() {
                        app.dispatch_command(Command::Verify { lba, path });
                    }
                }
            }
            if ui
                .add_enabled(connected, egui::Button::new("Blank Check"))
                .clicked()
            {
                if let (Ok(lba), Ok(count)) = (
                    app.state.sector_lba_input.parse::<u32>(),
                    app.state.sector_count_input.parse::<u32>(),
                ) {
                    app.dispatch_command(Command::BlankCheck { lba, count });
                }
            }
        });
    });

    ui.add_space(theme::SECTION_SPACING);

    // Dump / Restore
    ui.group(|ui| {
        ui.label("Full Dump / Restore");
        ui.checkbox(&mut app.state.verify_after_dump, "Verify after dump/restore");
        ui.horizontal(|ui| {
            if ui
                .add_enabled(connected, egui::Button::new("Dump Full"))
                .clicked()
            {
                if let Some(path) = rfd::FileDialog::new()
                    .set_file_name("dump.img")
                    .save_file()
                {
                    app.dispatch_command(Command::DumpFull {
                        path,
                        verify: app.state.verify_after_dump,
                    });
                }
            }
            if ui
                .add_enabled(connected, egui::Button::new("Restore Full"))
                .clicked()
            {
                if let Some(path) = rfd::FileDialog::new().pick_file() {
                    app.dispatch_command(Command::RestoreFull {
                        path,
                        verify: app.state.verify_after_dump,
                    });
                }
            }
        });
    });

    ui.add_space(theme::SECTION_SPACING);

    // Partition select
    ui.group(|ui| {
        ui.label("eMMC Partition");
        ui.horizontal(|ui| {
            let partitions = ["User (0)", "Boot0 (1)", "Boot1 (2)", "RPMB (3)"];
            for (id, name) in partitions.iter().enumerate() {
                if ui
                    .add_enabled(connected, egui::Button::new(*name))
                    .clicked()
                {
                    app.dispatch_command(Command::SetPartition(id as u8));
                }
            }
        });
    });

    ui.add_space(theme::SECTION_SPACING);

    // Speed controls
    ui.group(|ui| {
        ui.label("Speed Control");
        ui.horizontal(|ui| {
            ui.label("eMMC CLK:");
            let clk_presets = [
                "2 MHz (0)",
                "3.75 MHz (1)",
                "6 MHz (2)",
                "10 MHz (3)",
                "15 MHz (4)",
            ];
            for (preset, name) in clk_presets.iter().enumerate() {
                if ui
                    .add_enabled(connected, egui::Button::new(*name).small())
                    .clicked()
                {
                    app.dispatch_command(Command::SetSpeed(preset as u8));
                }
            }
        });
        ui.horizontal(|ui| {
            ui.label("UART:");
            let baud_presets = ["3M (0)", "6M (1)", "12M (3)"];
            let baud_ids: [u8; 3] = [0, 1, 3];
            for (i, name) in baud_presets.iter().enumerate() {
                if ui
                    .add_enabled(connected, egui::Button::new(*name).small())
                    .clicked()
                {
                    app.dispatch_command(Command::SetBaud(baud_ids[i]));
                }
            }
        });
        ui.horizontal(|ui| {
            ui.label("Bus Width:");
            for (width, name) in [(1u8, "1-bit"), (4, "4-bit")] {
                let selected = app.state.bus_width == width;
                if ui
                    .add_enabled(connected, egui::Button::new(name).small().selected(selected))
                    .clicked()
                {
                    app.dispatch_command(Command::SetBusWidth(width));
                }
            }
        });
    });

    ui.add_space(theme::SECTION_SPACING);

    // Card Status (CMD13)
    ui.group(|ui| {
        ui.label("Card Status (CMD13)");
        ui.horizontal(|ui| {
            if ui
                .add_enabled(connected, egui::Button::new("Read Card Status"))
                .clicked()
            {
                app.dispatch_command(Command::CardStatus);
            }
        });
        if let Some(status) = app.state.card_status_raw {
            ui.add_space(theme::GROUP_SPACING);
            egui::Grid::new("card_status_grid")
                .num_columns(2)
                .striped(true)
                .show(ui, |ui| {
                    ui.label("Raw:");
                    ui.monospace(format!("0x{:08X}", status));
                    ui.end_row();

                    ui.label("CURRENT_STATE:");
                    let state_val = (status >> 9) & 0xF;
                    let state_name = match state_val {
                        0 => "Idle",
                        1 => "Ready",
                        2 => "Ident",
                        3 => "Standby",
                        4 => "Transfer",
                        5 => "Data",
                        6 => "Receive",
                        7 => "Program",
                        8 => "Disconnect",
                        9 => "Bus Test",
                        _ => "Reserved",
                    };
                    ui.label(format!("{} ({})", state_name, state_val));
                    ui.end_row();

                    ui.label("READY_FOR_DATA:");
                    ui.label(if status & (1 << 8) != 0 { "Yes" } else { "No" });
                    ui.end_row();

                    ui.label("SWITCH_ERROR:");
                    ui.label(if status & (1 << 7) != 0 { "Yes" } else { "No" });
                    ui.end_row();

                    ui.label("ERASE_RESET:");
                    ui.label(if status & (1 << 13) != 0 { "Yes" } else { "No" });
                    ui.end_row();

                    ui.label("WP_ERASE_SKIP:");
                    ui.label(if status & (1 << 15) != 0 { "Yes" } else { "No" });
                    ui.end_row();

                    ui.label("ERROR:");
                    ui.label(if status & (1 << 19) != 0 { "Yes" } else { "No" });
                    ui.end_row();

                    ui.label("CC_ERROR:");
                    ui.label(if status & (1 << 20) != 0 { "Yes" } else { "No" });
                    ui.end_row();

                    ui.label("ADDRESS_ERROR:");
                    ui.label(if status & (1 << 22) != 0 { "Yes" } else { "No" });
                    ui.end_row();
                });
        }
    });

    ui.add_space(theme::SECTION_SPACING);

    // Raw CMD
    ui.group(|ui| {
        ui.label("Raw Command");
        ui.horizontal(|ui| {
            ui.label("CMD:");
            ui.add(
                egui::TextEdit::singleline(&mut app.state.raw_cmd_index_input)
                    .desired_width(40.0),
            );
            ui.label("Arg (hex):");
            ui.add(
                egui::TextEdit::singleline(&mut app.state.raw_cmd_arg_input)
                    .desired_width(80.0)
                    .font(egui::TextStyle::Monospace),
            );
        });
        ui.horizontal(|ui| {
            ui.checkbox(&mut app.state.raw_cmd_has_response, "Response");
            ui.checkbox(&mut app.state.raw_cmd_busy_wait, "Busy wait");
            ui.checkbox(&mut app.state.raw_cmd_has_data, "Has data");

            if ui
                .add_enabled(connected, egui::Button::new("Send"))
                .clicked()
            {
                if let Ok(index) = app.state.raw_cmd_index_input.parse::<u8>() {
                    let arg = u32::from_str_radix(
                        app.state.raw_cmd_arg_input.trim_start_matches("0x"),
                        16,
                    )
                    .unwrap_or(0);
                    let mut flags = 0u8;
                    if app.state.raw_cmd_has_response {
                        flags |= 0x01;
                    }
                    if app.state.raw_cmd_has_data {
                        flags |= 0x02;
                    }
                    if app.state.raw_cmd_busy_wait {
                        flags |= 0x04;
                    }
                    app.dispatch_command(Command::SendRawCmd { index, arg, flags });
                }
            }
        });
    });

    ui.add_space(theme::SECTION_SPACING);

    // ExtCSD Write
    ui.group(|ui| {
        ui.label("ExtCSD Write (CMD6 SWITCH)");
        ui.horizontal(|ui| {
            ui.label("Index:");
            ui.add(
                egui::TextEdit::singleline(&mut app.state.extcsd_write_index_input)
                    .desired_width(50.0)
                    .hint_text("e.g. 179"),
            );
            ui.label("Value (hex):");
            ui.add(
                egui::TextEdit::singleline(&mut app.state.extcsd_write_value_input)
                    .desired_width(50.0)
                    .hint_text("e.g. 48")
                    .font(egui::TextStyle::Monospace),
            );
            if ui
                .add_enabled(connected, egui::Button::new("Write"))
                .clicked()
            {
                if let Ok(index) = app.state.extcsd_write_index_input.parse::<u8>() {
                    let value = u8::from_str_radix(
                        app.state
                            .extcsd_write_value_input
                            .trim_start_matches("0x"),
                        16,
                    )
                    .unwrap_or(0);
                    app.dispatch_command(Command::WriteExtCsd { index, value });
                }
            }
        });
    });
}
