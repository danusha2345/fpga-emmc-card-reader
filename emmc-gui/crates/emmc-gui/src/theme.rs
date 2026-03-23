use eframe::egui::Color32;

// Status colors
pub const COLOR_SUCCESS: Color32 = Color32::from_rgb(80, 200, 120);
pub const COLOR_ERROR: Color32 = Color32::from_rgb(255, 90, 90);
pub const COLOR_WARNING: Color32 = Color32::from_rgb(255, 200, 60);
pub const COLOR_ORANGE: Color32 = Color32::from_rgb(255, 160, 0);
pub const COLOR_CONNECTED: Color32 = Color32::from_rgb(80, 200, 120);
pub const COLOR_DISCONNECTED: Color32 = Color32::from_rgb(255, 90, 90);

// Spacing
pub const SECTION_SPACING: f32 = 8.0;
pub const GROUP_SPACING: f32 = 4.0;
pub const INLINE_SPACING: f32 = 16.0;

// Layout
pub const STATUS_BAR_HEIGHT: f32 = 24.0;
pub const SIDEBAR_WIDTH: f32 = 200.0;
pub const SIDEBAR_MIN_WIDTH: f32 = 180.0;

// Scroll area heights
pub const SCROLL_SMALL: f32 = 80.0;
pub const SCROLL_MEDIUM: f32 = 120.0;
pub const SCROLL_LARGE: f32 = 200.0;
pub const SCROLL_HEX: f32 = 300.0;
