use emmc_core::card_info::{CidInfo, CsdInfo, ExtCsdInfo};
use emmc_core::ext4::{Ext4DirEntry, Ext4Info};
use emmc_core::partition::PartitionTable;
use emmc_core::protocol::ControllerStatus;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crate::logging::AppLog;


#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpeedProfile {
    Fast,   // 12M UART (preset 3) + 10 MHz eMMC (preset 3)
    Medium, // 6M UART (preset 1) + 6 MHz eMMC (preset 2)
    Safe,   // 3M UART (preset 0) + 2 MHz eMMC (preset 0)
}

impl SpeedProfile {
    pub fn label(&self) -> &'static str {
        match self {
            SpeedProfile::Fast => "Fast (12M + 10 MHz)",
            SpeedProfile::Medium => "Medium (6M + 6 MHz)",
            SpeedProfile::Safe => "Safe (3M + 2 MHz)",
        }
    }

    pub fn baud_preset(&self) -> u8 {
        match self {
            SpeedProfile::Fast => 3,   // 12 Mbaud
            SpeedProfile::Medium => 1, // 6 Mbaud
            SpeedProfile::Safe => 0,   // 3 Mbaud
        }
    }

    pub fn clk_preset(&self) -> u8 {
        match self {
            SpeedProfile::Fast => 3,   // 10 MHz
            SpeedProfile::Medium => 2, // 6 MHz
            SpeedProfile::Safe => 0,   // 2 MHz
        }
    }

    pub fn target_baud(&self) -> u32 {
        match self {
            SpeedProfile::Fast => 12_000_000,
            SpeedProfile::Medium => 6_000_000,
            SpeedProfile::Safe => 3_000_000,
        }
    }

    pub fn all() -> &'static [SpeedProfile] {
        &[SpeedProfile::Fast, SpeedProfile::Medium, SpeedProfile::Safe]
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum OperationStatus {
    Idle,
    Running(String),
    Completed(String),
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct OperationProgress {
    pub current: u64,
    pub total: u64,
    pub description: String,
}

impl OperationProgress {
    pub fn fraction(&self) -> f32 {
        if self.total == 0 {
            0.0
        } else {
            self.current as f32 / self.total as f32
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActiveTab {
    EmmcInfo,
    Sectors,
    Partitions,
    Ext4Browser,
    HexEditor,
}

impl ActiveTab {
    pub fn label(&self) -> &'static str {
        match self {
            ActiveTab::EmmcInfo => "eMMC Info",
            ActiveTab::Sectors => "Sectors",
            ActiveTab::Partitions => "Partitions",
            ActiveTab::Ext4Browser => "ext4 Browser",
            ActiveTab::HexEditor => "Hex Editor",
        }
    }

    pub fn all() -> &'static [ActiveTab] {
        &[
            ActiveTab::EmmcInfo,
            ActiveTab::Sectors,
            ActiveTab::Partitions,
            ActiveTab::Ext4Browser,
            ActiveTab::HexEditor,
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EmmcPartition {
    User,
    Boot0,
    Boot1,
    RPMB,
}

impl EmmcPartition {
    pub fn id(&self) -> u8 {
        match self {
            EmmcPartition::User => 0,
            EmmcPartition::Boot0 => 1,
            EmmcPartition::Boot1 => 2,
            EmmcPartition::RPMB => 3,
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            EmmcPartition::User => "User",
            EmmcPartition::Boot0 => "Boot0",
            EmmcPartition::Boot1 => "Boot1",
            EmmcPartition::RPMB => "RPMB",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum HexSource {
    None,
    Sectors { lba: u64, count: u64 },
    Ext4File { path: String },
}

/// Confirmation dialog state
pub struct ConfirmDialog {
    pub title: String,
    pub message: String,
    pub detail: Option<String>,
    pub confirmed: Option<bool>,
    pub action_id: String,
}

impl ConfirmDialog {
    pub fn new(
        title: impl Into<String>,
        message: impl Into<String>,
        action_id: impl Into<String>,
    ) -> Self {
        Self {
            title: title.into(),
            message: message.into(),
            detail: None,
            confirmed: None,
            action_id: action_id.into(),
        }
    }
}

pub struct AppState {
    // Connection
    pub available_ports: Vec<String>,
    pub selected_port: String,
    pub selected_baud: u32,
    pub connected: bool,

    // FIFO transport
    pub use_fifo: bool,
    pub fifo_available: bool,
    pub fifo_device_info: Option<String>,

    // Speed profile
    pub speed_profile: SpeedProfile,
    pub initial_baud: u32,

    // eMMC partition
    pub active_partition: EmmcPartition,

    // eMMC clock preset (0-6)
    pub selected_clk_preset: usize,

    // UART baud preset (0-3)
    pub selected_baud_preset: usize,

    // Tracked UART baud rate and eMMC clock freq (for adaptive read chunk)
    pub current_baud: u32,
    pub current_emmc_freq: u32,

    // eMMC bus width (1 or 4)
    pub bus_width: u8,

    // Raw CMD state
    pub raw_cmd_index: String,
    pub raw_cmd_arg: String,
    pub raw_cmd_resp: bool,
    pub raw_cmd_long: bool,
    pub raw_cmd_busy: bool,
    pub raw_cmd_result: Option<String>,

    // Card info
    pub cid_info: Option<CidInfo>,
    pub csd_info: Option<CsdInfo>,
    pub ext_csd_info: Option<ExtCsdInfo>,

    // Partitions
    pub partition_table: Option<PartitionTable>,

    // Sector tab
    pub sector_lba_input: String,
    pub sector_count_input: String,
    pub sector_data: Vec<u8>,
    pub sector_source_lba: u64,
    pub write_lba_input: String,
    pub extcsd_index_input: String,
    pub extcsd_value_input: String,

    // ext4 browser
    pub ext4_partition_input: String,
    pub ext4_info: Option<Ext4Info>,
    pub ext4_current_path: String,
    pub ext4_entries: Vec<Ext4DirEntry>,
    pub ext4_file_content: Option<Vec<u8>>,
    pub ext4_file_path: Option<String>,

    // Hex editor
    pub hex_data: Vec<u8>,
    pub hex_source: HexSource,
    pub hex_modified: HashSet<usize>,
    pub hex_cursor: usize,
    pub hex_lba_input: String,
    pub hex_count_input: String,

    // Operation state
    pub operation_status: OperationStatus,
    pub operation_progress: Option<OperationProgress>,
    pub cancel_flag: Arc<AtomicBool>,

    // UI state
    pub active_tab: ActiveTab,
    pub log: AppLog,
    pub show_log: bool,
    pub log_auto_scroll: bool,

    // Controller debug status
    pub controller_status: Option<ControllerStatus>,

    // Confirm dialog
    pub confirm_dialog: Option<ConfirmDialog>,

    // Pending action from confirm dialog (dispatched by app.rs where worker_tx is available)
    pub pending_action: Option<String>,

    pub verify_result: Option<String>,

    // RPMB
    pub rpmb_counter_result: Option<String>,
    pub rpmb_data_result: Option<String>,
    pub rpmb_data_bytes: Option<Vec<u8>>,
    pub rpmb_address_input: String,

    // Verify options
    pub verify_after_write: bool,
    pub verify_after_dump: bool,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            available_ports: Vec::new(),
            selected_port: String::new(),
            selected_baud: 3_000_000,
            connected: false,

            use_fifo: false,
            fifo_available: false,
            fifo_device_info: None,

            speed_profile: SpeedProfile::Fast,
            initial_baud: 3_000_000,

            active_partition: EmmcPartition::User,
            selected_clk_preset: 0,
            selected_baud_preset: 0,
            current_baud: 3_000_000,
            current_emmc_freq: 2_000_000,
            bus_width: 1,
            raw_cmd_index: String::new(),
            raw_cmd_arg: String::new(),
            raw_cmd_resp: true,
            raw_cmd_long: false,
            raw_cmd_busy: false,
            raw_cmd_result: None,

            cid_info: None,
            csd_info: None,
            ext_csd_info: None,

            partition_table: None,

            sector_lba_input: "0".to_string(),
            sector_count_input: "1".to_string(),
            sector_data: Vec::new(),
            sector_source_lba: 0,
            write_lba_input: "0".to_string(),
            extcsd_index_input: String::new(),
            extcsd_value_input: String::new(),

            ext4_partition_input: "userdata".to_string(),
            ext4_info: None,
            ext4_current_path: "/".to_string(),
            ext4_entries: Vec::new(),
            ext4_file_content: None,
            ext4_file_path: None,

            hex_data: Vec::new(),
            hex_source: HexSource::None,
            hex_modified: HashSet::new(),
            hex_cursor: 0,
            hex_lba_input: "0".to_string(),
            hex_count_input: "1".to_string(),

            operation_status: OperationStatus::Idle,
            operation_progress: None,
            cancel_flag: Arc::new(AtomicBool::new(false)),

            active_tab: ActiveTab::EmmcInfo,
            log: AppLog::new(),
            show_log: true,
            log_auto_scroll: true,

            controller_status: None,
            confirm_dialog: None,
            pending_action: None,

            verify_result: None,

            rpmb_counter_result: None,
            rpmb_data_result: None,
            rpmb_data_bytes: None,
            rpmb_address_input: "0".to_string(),

            verify_after_write: false,
            verify_after_dump: false,
        }
    }

    pub fn is_connected(&self) -> bool {
        self.connected
    }

    /// Port string for operations: "fifo://" when FIFO mode, else selected serial port.
    pub fn effective_port(&self) -> String {
        if self.use_fifo {
            "fifo://".to_string()
        } else {
            self.selected_port.clone()
        }
    }

    pub fn is_busy(&self) -> bool {
        matches!(self.operation_status, OperationStatus::Running(_))
    }

    pub fn set_running(&mut self, desc: impl Into<String>) {
        self.cancel_flag.store(false, Ordering::Relaxed);
        self.operation_status = OperationStatus::Running(desc.into());
    }

    pub fn set_completed(&mut self, msg: impl Into<String>) {
        self.operation_status = OperationStatus::Completed(msg.into());
        self.operation_progress = None;
    }

    pub fn set_failed(&mut self, msg: impl Into<String>) {
        let msg = msg.into();
        self.log.error(&msg);
        self.operation_status = OperationStatus::Failed(msg);
        self.operation_progress = None;
    }

    pub fn cancel_operation(&self) {
        self.cancel_flag.store(true, Ordering::Relaxed);
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}
