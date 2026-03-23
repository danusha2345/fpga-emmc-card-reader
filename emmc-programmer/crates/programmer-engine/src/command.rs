use std::path::PathBuf;

#[derive(Debug, Clone)]
pub enum Command {
    Identify,
    ReadSectors {
        lba: u32,
        count: u32,
        path: Option<PathBuf>,
    },
    WriteSectors {
        lba: u32,
        path: PathBuf,
        verify: bool,
    },
    WriteSectorsData {
        lba: u32,
        data: Vec<u8>,
        verify: bool,
    },
    Erase {
        lba: u32,
        count: u32,
    },
    SecureErase {
        lba: u32,
        count: u32,
    },
    CardStatus,
    Verify {
        lba: u32,
        path: PathBuf,
    },
    BlankCheck {
        lba: u32,
        count: u32,
    },
    DumpFull {
        path: PathBuf,
        verify: bool,
    },
    RestoreFull {
        path: PathBuf,
        verify: bool,
    },
    SetPartition(u8),
    ReadExtCsd,
    WriteExtCsd {
        index: u8,
        value: u8,
    },
    SendRawCmd {
        index: u8,
        arg: u32,
        flags: u8,
    },
    SetSpeed(u8),
    SetBaud(u8),
    SetBusWidth(u8),
    ControllerStatus,
    Reinit,
    HexWriteBack {
        lba: u32,
        data: Vec<u8>,
    },
    Ext4Load {
        partition_lba: u64,
    },
    Ext4Navigate {
        path: String,
    },
    Ext4ReadFile {
        path: String,
    },
    Ext4OverwriteFile {
        ext4_path: String,
        local_path: PathBuf,
    },
    Ext4CreateFile {
        parent_path: String,
        name: String,
        data: Vec<u8>,
    },
    Ext4Search {
        query: String,
    },
}

impl Command {
    pub fn label(&self) -> &'static str {
        match self {
            Command::Identify => "Identify",
            Command::ReadSectors { .. } => "Read Sectors",
            Command::WriteSectors { .. } | Command::WriteSectorsData { .. } => "Write Sectors",
            Command::Erase { .. } => "Erase",
            Command::SecureErase { .. } => "Secure Erase",
            Command::CardStatus => "Card Status",
            Command::Verify { .. } => "Verify",
            Command::BlankCheck { .. } => "Blank Check",
            Command::DumpFull { .. } => "Full Dump",
            Command::RestoreFull { .. } => "Full Restore",
            Command::SetPartition(_) => "Set Partition",
            Command::ReadExtCsd => "Read ExtCSD",
            Command::WriteExtCsd { .. } => "Write ExtCSD",
            Command::SendRawCmd { .. } => "Raw Command",
            Command::SetSpeed(_) => "Set Speed",
            Command::SetBaud(_) => "Set Baud",
            Command::SetBusWidth(_) => "Set Bus Width",
            Command::ControllerStatus => "Controller Status",
            Command::Reinit => "Reinit",
            Command::HexWriteBack { .. } => "Hex Write Back",
            Command::Ext4Load { .. } => "Load ext4",
            Command::Ext4Navigate { .. } => "Browse",
            Command::Ext4ReadFile { .. } => "Read File",
            Command::Ext4OverwriteFile { .. } => "Overwrite File",
            Command::Ext4CreateFile { .. } => "Create File",
            Command::Ext4Search { .. } => "Search",
        }
    }

    pub fn is_destructive(&self) -> bool {
        matches!(
            self,
            Command::WriteSectors { .. }
                | Command::WriteSectorsData { .. }
                | Command::Erase { .. }
                | Command::SecureErase { .. }
                | Command::RestoreFull { .. }
                | Command::WriteExtCsd { .. }
                | Command::HexWriteBack { .. }
                | Command::Ext4OverwriteFile { .. }
                | Command::Ext4CreateFile { .. }
                | Command::SetPartition(3)
        )
    }

    pub fn confirm_message(&self) -> Option<String> {
        match self {
            Command::WriteSectors { lba, path, .. } => Some(format!(
                "Write {} to LBA {}?",
                path.display(),
                lba
            )),
            Command::WriteSectorsData { lba, data, .. } => Some(format!(
                "Write {} bytes to LBA {}?",
                data.len(),
                lba
            )),
            Command::Erase { lba, count } => {
                Some(format!("Erase {} sector(s) at LBA {}?", count, lba))
            }
            Command::SecureErase { lba, count } => {
                Some(format!("Secure erase {} sector(s) at LBA {}?", count, lba))
            }
            Command::RestoreFull { path, .. } => {
                Some(format!("Restore full image from {}?", path.display()))
            }
            Command::WriteExtCsd { index, value } => {
                Some(format!("Write ExtCSD[{}] = 0x{:02X}?", index, value))
            }
            Command::HexWriteBack { lba, data } => Some(format!(
                "Write back {} bytes to LBA {}?",
                data.len(),
                lba
            )),
            Command::Ext4OverwriteFile { ext4_path, local_path } => Some(format!(
                "Overwrite {} from {}?",
                ext4_path,
                local_path.display()
            )),
            Command::Ext4CreateFile { parent_path, name, data } => Some(format!(
                "Create file {}/{} ({} bytes)?",
                parent_path, name, data.len()
            )),
            Command::SetPartition(3) => Some(
                "Switch to RPMB partition?\n\n\
                 WARNING: RPMB requires authenticated frame protocol.\n\
                 Plain read/write on RPMB is a JEDEC protocol violation\n\
                 that can permanently brick the eMMC chip."
                    .to_string(),
            ),
            _ => None,
        }
    }
}
