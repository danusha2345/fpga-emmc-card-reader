use eframe::NativeOptions;
use tracing_subscriber::EnvFilter;

mod app;
mod panels;
mod theme;
mod widgets;

fn main() -> eframe::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let options = NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_inner_size([1200.0, 800.0])
            .with_min_inner_size([900.0, 600.0])
            .with_title("eMMC Card Reader")
            .with_maximized(true),
        ..Default::default()
    };

    eframe::run_native(
        "eMMC Card Reader",
        options,
        Box::new(|cc| Ok(Box::new(app::EmmcApp::new(cc)))),
    )
}
