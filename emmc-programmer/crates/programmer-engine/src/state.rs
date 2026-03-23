use crate::command::Command;
use crate::logging::AppLog;
use programmer_hal::ChipInfo;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpeedProfile {
    Fast,
    Medium,
    Safe,
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
            SpeedProfile::Fast => 3,
            SpeedProfile::Medium => 1,
            SpeedProfile::Safe => 0,
        }
    }

    pub fn clk_preset(&self) -> u8 {
        match self {
            SpeedProfile::Fast => 3,
            SpeedProfile::Medium => 2,
            SpeedProfile::Safe => 0,
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
    ChipInfo,
    Operations,
    Partitions,
    HexEditor,
    Filesystem,
    ImageManager,
}

impl ActiveTab {
    pub fn label(&self) -> &'static str {
        match self {
            ActiveTab::ChipInfo => "Chip Info",
            ActiveTab::Operations => "Operations",
            ActiveTab::Partitions => "Partitions",
            ActiveTab::HexEditor => "Hex Editor",
            ActiveTab::Filesystem => "Filesystem",
            ActiveTab::ImageManager => "Image Manager",
        }
    }

    pub fn all() -> &'static [ActiveTab] {
        &[
            ActiveTab::ChipInfo,
            ActiveTab::Operations,
            ActiveTab::Partitions,
            ActiveTab::HexEditor,
            ActiveTab::Filesystem,
            ActiveTab::ImageManager,
        ]
    }
}

pub struct AppState {
    // Connection
    pub available_ports: Vec<String>,
    pub selected_port: String,
    pub selected_baud: u32,
    pub connected: bool,
    pub speed_profile: SpeedProfile,
    pub selected_clk_preset: usize,
    pub selected_baud_preset: usize,
    pub current_baud: u32,
    pub current_emmc_freq: u32,
    pub bus_width: u8,

    // FIFO transport
    pub use_fifo: bool,
    pub fifo_available: bool,
    pub fifo_device_info: Option<String>,

    // Chip info
    pub chip_info: Option<ChipInfo>,
    pub ext_csd_raw: Option<Vec<u8>>,
    pub ext_csd_parsed: Option<ExtCsdData>,

    // Active eMMC partition
    pub active_partition: u8,

    // Card status (CMD13)
    pub card_status_raw: Option<u32>,

    // Controller status (12-byte FPGA debug)
    pub controller_status: Option<emmc_core::protocol::ControllerStatus>,

    // Raw CMD
    pub raw_cmd_index_input: String,
    pub raw_cmd_arg_input: String,
    pub raw_cmd_has_response: bool,
    pub raw_cmd_busy_wait: bool,
    pub raw_cmd_has_data: bool,

    // ExtCSD write
    pub extcsd_write_index_input: String,
    pub extcsd_write_value_input: String,

    // Partition table
    pub partition_data: Option<PartitionTableData>,
    pub partition_read_pending: bool,

    // Sector / operations
    pub sector_lba_input: String,
    pub sector_count_input: String,
    pub verify_after_write: bool,
    pub verify_after_dump: bool,

    // Hex editor
    pub hex_data: Vec<u8>,
    pub hex_source_lba: Option<u64>,
    pub hex_modified: HashSet<usize>,
    pub hex_cursor: usize,
    pub hex_lba_input: String,
    pub hex_count_input: String,
    pub hex_search_input: String,
    pub hex_goto_input: String,
    pub hex_undo_stack: Vec<HexEdit>,
    pub hex_redo_stack: Vec<HexEdit>,

    // ext4 filesystem
    pub ext4_partition_input: String,
    pub ext4_info: Option<Ext4FsInfo>,
    pub ext4_current_path: String,
    pub ext4_entries: Vec<Ext4Entry>,
    pub ext4_file_content: Option<Vec<u8>>,
    pub ext4_file_path: Option<String>,
    pub ext4_partition_lba: Option<u64>,
    pub ext4_search_query: String,
    pub ext4_search_results: Vec<Ext4SearchResult>,

    // Image manager
    pub image_buffer: Option<ImageData>,
    pub image_diff_buffer: Option<ImageData>,
    pub image_diff_cache: Option<Vec<crate::image::DiffEntry>>,

    // Operation state
    pub operation_status: OperationStatus,
    pub operation_progress: Option<OperationProgress>,
    pub cancel_flag: Arc<AtomicBool>,

    // UI state
    pub active_tab: ActiveTab,
    pub log: AppLog,
    pub show_log: bool,

    // Confirm dialog
    pub confirm_dialog: Option<ConfirmDialog>,
    pub pending_command: Option<Command>,
}

#[derive(Debug, Clone)]
pub struct HexEdit {
    pub offset: usize,
    pub old_value: u8,
    pub new_value: u8,
}

#[derive(Debug, Clone)]
pub struct PartitionTableData {
    pub table_type: String,
    pub entries: Vec<PartitionEntryData>,
}

#[derive(Debug, Clone)]
pub struct PartitionEntryData {
    pub index: u32,
    pub name: String,
    pub type_name: String,
    pub fs_type: String,
    pub start_lba: u64,
    pub end_lba: u64,
    pub size_sectors: u64,
    pub size_human: String,
}

#[derive(Debug, Clone)]
pub struct ImageData {
    pub path: String,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct Ext4FsInfo {
    pub volume_name: String,
    pub uuid: String,
    pub block_size: u32,
    pub block_count: u64,
    pub free_blocks: u64,
    pub inode_count: u32,
    pub free_inodes: u32,
    pub is_64bit: bool,
    pub has_extents: bool,
    pub metadata_csum: bool,
}

#[derive(Debug, Clone)]
pub struct Ext4Entry {
    pub inode: u32,
    pub name: String,
    pub file_type: u8, // 1=file, 2=dir, 7=symlink
}

#[derive(Debug, Clone)]
pub struct Ext4SearchResult {
    pub path: String,
    pub file_type: u8,
}

pub struct ConfirmDialog {
    pub title: String,
    pub message: String,
    pub command: Command,
}

#[derive(Debug, Clone)]
pub struct ExtCsdData {
    pub capacity_bytes: u64,
    pub fw_version: String,
    pub boot_partition_size: u64,
    pub rpmb_size: u64,
    pub boot_ack: bool,
    pub boot_partition: u8,
    pub partition_access: u8,
    pub hs_support: bool,
    pub hs52_support: bool,
    pub ddr_support: bool,
    pub life_time_est_a: u8,
    pub life_time_est_b: u8,
    pub pre_eol_info: u8,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            available_ports: Vec::new(),
            selected_port: String::new(),
            selected_baud: 3_000_000,
            connected: false,
            speed_profile: SpeedProfile::Safe,
            selected_clk_preset: 0,
            selected_baud_preset: 0,
            current_baud: 3_000_000,
            current_emmc_freq: 2_000_000,
            bus_width: 1,

            use_fifo: false,
            fifo_available: false,
            fifo_device_info: None,

            chip_info: None,
            ext_csd_raw: None,
            ext_csd_parsed: None,

            active_partition: 0,

            card_status_raw: None,
            controller_status: None,

            raw_cmd_index_input: "13".to_string(),
            raw_cmd_arg_input: "00000000".to_string(),
            raw_cmd_has_response: true,
            raw_cmd_busy_wait: false,
            raw_cmd_has_data: false,

            extcsd_write_index_input: String::new(),
            extcsd_write_value_input: String::new(),

            partition_data: None,
            partition_read_pending: false,

            sector_lba_input: "0".to_string(),
            sector_count_input: "1".to_string(),
            verify_after_write: false,
            verify_after_dump: false,

            hex_data: Vec::new(),
            hex_source_lba: None,
            hex_modified: HashSet::new(),
            hex_cursor: 0,
            hex_lba_input: "0".to_string(),
            hex_count_input: "1".to_string(),
            hex_search_input: String::new(),
            hex_goto_input: String::new(),
            hex_undo_stack: Vec::new(),
            hex_redo_stack: Vec::new(),

            ext4_partition_input: "userdata".to_string(),
            ext4_info: None,
            ext4_current_path: "/".to_string(),
            ext4_entries: Vec::new(),
            ext4_file_content: None,
            ext4_file_path: None,
            ext4_partition_lba: None,
            ext4_search_query: String::new(),
            ext4_search_results: Vec::new(),

            image_buffer: None,
            image_diff_buffer: None,
            image_diff_cache: None,

            operation_status: OperationStatus::Idle,
            operation_progress: None,
            cancel_flag: Arc::new(AtomicBool::new(false)),

            active_tab: ActiveTab::ChipInfo,
            log: AppLog::new(),
            show_log: true,

            confirm_dialog: None,
            pending_command: None,
        }
    }

    pub fn is_connected(&self) -> bool {
        self.connected
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

    pub fn hex_apply_edit(&mut self, offset: usize, new_value: u8) {
        if offset < self.hex_data.len() {
            let old_value = self.hex_data[offset];
            if old_value != new_value {
                self.hex_undo_stack.push(HexEdit {
                    offset,
                    old_value,
                    new_value,
                });
                self.hex_redo_stack.clear();
                self.hex_data[offset] = new_value;
                self.hex_modified.insert(offset);
            }
        }
    }

    pub fn hex_undo(&mut self) {
        if let Some(edit) = self.hex_undo_stack.pop() {
            self.hex_data[edit.offset] = edit.old_value;
            if edit.old_value == edit.new_value {
                self.hex_modified.remove(&edit.offset);
            }
            self.hex_redo_stack.push(edit);
        }
    }

    pub fn hex_redo(&mut self) {
        if let Some(edit) = self.hex_redo_stack.pop() {
            self.hex_data[edit.offset] = edit.new_value;
            self.hex_modified.insert(edit.offset);
            self.hex_undo_stack.push(edit);
        }
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}
