use eframe::egui;
use programmer_engine::command::Command;
use programmer_engine::state::{ActiveTab, PartitionEntryData, PartitionTableData};

use crate::app::ProgrammerApp;
use crate::theme;

pub fn show_partitions_panel(ui: &mut egui::Ui, app: &mut ProgrammerApp) {
    ui.heading("Partitions");
    ui.add_space(theme::SECTION_SPACING);

    let connected = app.state.connected && !app.state.is_busy();

    ui.horizontal(|ui| {
        if ui
            .add_enabled(connected, egui::Button::new("Read Partition Table"))
            .clicked()
        {
            // Read LBA 0-127 (MBR + GPT + first partitions for FS detection)
            app.state.partition_read_pending = true;
            app.dispatch_command(Command::ReadSectors {
                lba: 0,
                count: 128,
                path: None,
            });
        }

        if ui
            .add_enabled(
                !app.state.hex_data.is_empty(),
                egui::Button::new("Parse from Hex"),
            )
            .clicked()
        {
            app.state.partition_data = parse_partition_table(&app.state.hex_data);
        }
    });

    // Auto-parse after partition read completes
    if app.state.partition_read_pending
        && !app.state.is_busy()
        && !app.state.hex_data.is_empty()
    {
        app.state.partition_read_pending = false;
        app.state.partition_data = parse_partition_table(&app.state.hex_data);
    }

    ui.add_space(theme::SECTION_SPACING);

    if let Some(ref pt) = app.state.partition_data {
        ui.label(format!("Table type: {}", pt.table_type));
        ui.label(format!("Partitions: {}", pt.entries.len()));
        ui.add_space(theme::GROUP_SPACING);

        let connected = app.state.connected && !app.state.is_busy();

        let mut ext4_target: Option<u64> = None;

        egui::ScrollArea::vertical()
            .show(ui, |ui| {
                egui::Grid::new("partition_table")
                    .num_columns(8)
                    .striped(true)
                    .show(ui, |ui| {
                        // Header
                        ui.strong("#");
                        ui.strong("Name");
                        ui.strong("Type");
                        ui.strong("FS");
                        ui.strong("Start LBA");
                        ui.strong("End LBA");
                        ui.strong("Size");
                        ui.strong("");
                        ui.end_row();

                        for entry in &pt.entries {
                            ui.label(entry.index.to_string());
                            ui.label(&entry.name);
                            ui.label(&entry.type_name);
                            ui.label(&entry.fs_type);
                            ui.label(entry.start_lba.to_string());
                            ui.label(entry.end_lba.to_string());
                            ui.label(&entry.size_human);

                            // Show ext4 button for ext4 partitions, or any Linux/Data partition
                            let is_ext4 = entry.fs_type == "ext4";
                            let can_browse = is_ext4
                                || matches!(
                                    entry.type_name.as_str(),
                                    "Linux" | "Data" | "Basic Data"
                                );
                            if can_browse {
                                let label = if is_ext4 { "Browse" } else { "ext4?" };
                                if ui
                                    .add_enabled(
                                        connected,
                                        egui::Button::new(label).small(),
                                    )
                                    .on_hover_text("Browse as ext4 filesystem")
                                    .clicked()
                                {
                                    ext4_target = Some(entry.start_lba);
                                }
                            } else {
                                ui.label("");
                            }
                            ui.end_row();
                        }
                    });
            });

        // Handle ext4 button click (outside borrow of pt)
        if let Some(lba) = ext4_target {
            app.state.ext4_partition_input = lba.to_string();
            app.state.ext4_partition_lba = Some(lba);
            app.state.ext4_current_path = "/".to_string();
            app.state.active_tab = ActiveTab::Filesystem;
            app.dispatch_command(Command::Ext4Load { partition_lba: lba });
        }
    } else {
        ui.label("No partition table loaded.");
    }
}

fn parse_partition_table(data: &[u8]) -> Option<PartitionTableData> {
    if data.len() < 512 {
        return None;
    }

    // Check MBR signature
    if data[510] != 0x55 || data[511] != 0xAA {
        return None;
    }

    // Check for GPT
    let is_gpt = if data.len() >= 1024 {
        &data[512..520] == b"EFI PART"
    } else {
        false
    };

    if is_gpt {
        parse_gpt(data)
    } else {
        parse_mbr(data)
    }
}

fn parse_mbr(data: &[u8]) -> Option<PartitionTableData> {
    let mut entries = Vec::new();
    let mut num = 0u32;
    for i in 0..4 {
        let offset = 446 + i * 16;
        let entry = &data[offset..offset + 16];
        let part_type = entry[4];
        if part_type == 0x00 {
            continue;
        }
        num += 1;
        let start_lba =
            u32::from_le_bytes([entry[8], entry[9], entry[10], entry[11]]) as u64;
        let size_sectors = u32::from_le_bytes([
            entry[12],
            entry[13],
            entry[14],
            entry[15],
        ]) as u64;

        entries.push(PartitionEntryData {
            index: num,
            name: String::new(),
            type_name: mbr_type_name(part_type).to_string(),
            fs_type: detect_fs_type(data, start_lba),
            start_lba,
            end_lba: start_lba + size_sectors.saturating_sub(1),
            size_sectors,
            size_human: format_size(size_sectors * 512),
        });
    }

    Some(PartitionTableData {
        table_type: "MBR".to_string(),
        entries,
    })
}

fn parse_gpt(data: &[u8]) -> Option<PartitionTableData> {
    if data.len() < 1024 {
        return None;
    }

    let header = &data[512..1024];
    if &header[0..8] != b"EFI PART" {
        return None;
    }

    let num_entries =
        u32::from_le_bytes([header[80], header[81], header[82], header[83]])
            as usize;
    let entry_size =
        u32::from_le_bytes([header[84], header[85], header[86], header[87]])
            as usize;

    // GPT entries start at LBA 2 (byte offset 1024)
    let entries_offset = 1024;
    let entries_end = entries_offset + num_entries * entry_size;
    if data.len() < entries_end {
        return None;
    }

    let mut entries = Vec::new();
    let mut num = 0u32;

    for i in 0..num_entries {
        let offset = entries_offset + i * entry_size;
        if offset + 128 > data.len() {
            break;
        }
        let entry = &data[offset..offset + 128];
        let type_guid_raw = &entry[0..16];
        if type_guid_raw == [0u8; 16] {
            continue;
        }
        num += 1;
        let start_lba = u64::from_le_bytes(entry[32..40].try_into().unwrap());
        let end_lba = u64::from_le_bytes(entry[40..48].try_into().unwrap());

        // Name: UTF-16LE at offset 56, 72 bytes
        let name_raw = &entry[56..128];
        let name = String::from_utf16_lossy(
            &name_raw
                .chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect::<Vec<_>>(),
        )
        .trim_end_matches('\0')
        .to_string();

        let size_sectors = end_lba - start_lba + 1;

        entries.push(PartitionEntryData {
            index: num,
            name,
            type_name: gpt_type_name(type_guid_raw).to_string(),
            fs_type: detect_fs_type(data, start_lba),
            start_lba,
            end_lba,
            size_sectors,
            size_human: format_size(size_sectors * 512),
        });
    }

    Some(PartitionTableData {
        table_type: "GPT".to_string(),
        entries,
    })
}

fn gpt_type_name(guid: &[u8]) -> &'static str {
    // GUIDs stored as mixed-endian in GPT
    // Compare first 4 bytes (LE) to identify common types
    let g0 = u32::from_le_bytes([guid[0], guid[1], guid[2], guid[3]]);
    match g0 {
        // EFI System: C12A7328-...
        0xC12A7328 => "EFI System",
        // Microsoft Basic Data: EBD0A0A2-...
        0xEBD0A0A2 => "Basic Data",
        // Linux Filesystem: 0FC63DAF-...
        0x0FC63DAF => "Linux",
        // Linux Swap: 0657FD6D-...
        0x0657FD6D => "Linux Swap",
        // Linux LVM: E6D6D379-...
        0xE6D6D379 => "Linux LVM",
        // Android vendor (various GUIDs starting with these)
        _ => {
            // Check for all-zero (should not happen here, filtered above)
            if guid.iter().all(|&b| b == 0) {
                "Empty"
            } else {
                "Data"
            }
        }
    }
}

fn mbr_type_name(type_id: u8) -> &'static str {
    match type_id {
        0x00 => "Empty",
        0x01 => "FAT12",
        0x04 => "FAT16 <32M",
        0x06 => "FAT16",
        0x07 => "NTFS/exFAT",
        0x0B => "FAT32",
        0x0C => "FAT32 LBA",
        0x82 => "Linux swap",
        0x83 => "Linux",
        0xEE => "GPT Protective",
        _ => "Unknown",
    }
}

/// Detect filesystem type from available data at partition start.
/// Returns "" if the partition data is not in the buffer.
fn detect_fs_type(data: &[u8], start_lba: u64) -> String {
    let byte_offset = start_lba as usize * 512;

    // ext4/ext2/ext3: magic 0x53EF at offset 0x438 from partition start
    let ext4_offset = byte_offset + 0x438;
    if ext4_offset + 2 <= data.len() {
        let magic = u16::from_le_bytes([data[ext4_offset], data[ext4_offset + 1]]);
        if magic == 0xEF53 {
            return "ext4".to_string();
        }
    }

    // squashfs: magic "hsqs" at offset 0 from partition start
    if byte_offset + 4 <= data.len() {
        if &data[byte_offset..byte_offset + 4] == b"hsqs" {
            return "sqfs".to_string();
        }
    }

    // UNR0: magic "UNR0" at offset 0
    if byte_offset + 4 <= data.len() {
        if &data[byte_offset..byte_offset + 4] == b"UNR0" {
            return "UNR0".to_string();
        }
    }

    // IM*H containers (IMAH, IMBH, IMCH, etc)
    if byte_offset + 4 <= data.len() {
        if data[byte_offset] == b'I' && data[byte_offset + 1] == b'M' && data[byte_offset + 3] == b'H' {
            let tag = String::from_utf8_lossy(&data[byte_offset..byte_offset + 4]);
            return tag.to_string();
        }
    }

    // If partition data not in buffer, return empty
    if byte_offset >= data.len() {
        return String::new();
    }

    // Data is available but no known magic
    "raw".to_string()
}

fn format_size(bytes: u64) -> String {
    if bytes >= 1024 * 1024 * 1024 {
        format!("{:.1} GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    } else if bytes >= 1024 * 1024 {
        format!("{:.0} MB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.0} KB", bytes as f64 / 1024.0)
    } else {
        format!("{} B", bytes)
    }
}
