#![allow(dead_code)]
use eframe::egui::Color32;

// Status colors
pub const COLOR_SUCCESS: Color32 = Color32::from_rgb(80, 200, 120);
pub const COLOR_ERROR: Color32 = Color32::from_rgb(255, 90, 90);
pub const COLOR_WARNING: Color32 = Color32::from_rgb(255, 200, 60);
pub const COLOR_CONNECTED: Color32 = Color32::from_rgb(80, 200, 120);
pub const COLOR_DISCONNECTED: Color32 = Color32::from_rgb(255, 90, 90);
pub const COLOR_MODIFIED: Color32 = Color32::from_rgb(255, 180, 50);
pub const COLOR_DIFF: Color32 = Color32::from_rgb(255, 100, 100);

// Sector map colors
pub const COLOR_SECTOR_READ: Color32 = Color32::from_rgb(60, 160, 255);
pub const COLOR_SECTOR_WRITTEN: Color32 = Color32::from_rgb(80, 200, 120);
pub const COLOR_SECTOR_ERASED: Color32 = Color32::from_rgb(180, 180, 180);
pub const COLOR_SECTOR_ERROR: Color32 = Color32::from_rgb(255, 60, 60);
pub const COLOR_SECTOR_BLANK: Color32 = Color32::from_rgb(40, 40, 40);

// Spacing
pub const SECTION_SPACING: f32 = 8.0;
pub const GROUP_SPACING: f32 = 4.0;

// Layout
pub const STATUS_BAR_HEIGHT: f32 = 24.0;
pub const SIDEBAR_WIDTH: f32 = 220.0;
pub const SIDEBAR_MIN_WIDTH: f32 = 180.0;
pub const LOG_MIN_HEIGHT: f32 = 80.0;
pub const LOG_DEFAULT_HEIGHT: f32 = 150.0;

// Hex view
pub const HEX_BYTES_PER_ROW: usize = 16;
