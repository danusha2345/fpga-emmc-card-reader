# Flash Programmer — Universal eMMC/NAND/SPI Programmer GUI

Cross-platform (Linux/Win/macOS) open-source flash programmer with trait-based architecture for multiple hardware backends.

## Quick Start

```bash
cd emmc-programmer
cargo run --release -p programmer-gui
```

## Architecture

```
emmc-programmer/
├── programmer-hal        # Traits: Programmer, ProgrammerExt, ProgressReporter
├── programmer-fpga       # FPGA UART backend (wraps emmc-core::EmmcConnection)
├── programmer-engine     # State, Command enum, worker operations, logging
└── programmer-gui        # egui UI: 6 tabs, sidebar, log, hex editor
```

### Core Traits

```rust
pub trait Programmer: Send {
    fn backend_name(&self) -> &str;
    fn supported_chip_types(&self) -> &[ChipType];
    fn identify(&mut self) -> Result<Option<ChipInfo>>;
    fn read(&mut self, addr: u64, len: u64, progress: &dyn ProgressReporter) -> Result<Vec<u8>>;
    fn write(&mut self, addr: u64, data: &[u8], progress: &dyn ProgressReporter) -> Result<()>;
    fn erase(&mut self, addr: u64, len: u64, progress: &dyn ProgressReporter) -> Result<()>;
    fn verify(&mut self, addr: u64, expected: &[u8], progress: &dyn ProgressReporter) -> Result<VerifyResult>;
    fn blank_check(&mut self, addr: u64, len: u64, progress: &dyn ProgressReporter) -> Result<BlankCheckResult>;
    fn extensions(&mut self) -> Option<&mut dyn ProgrammerExt> { None }
}
```

### UI Tabs

| # | Tab | Hotkey | Description |
|---|-----|--------|-------------|
| 1 | Chip Info | Ctrl+1 | CID/CSD, ExtCSD hex view, key fields |
| 2 | Operations | Ctrl+2 | Read/Write/Erase/Verify/BlankCheck, Dump/Restore |
| 3 | Partitions | Ctrl+3 | GPT/MBR table, partition list |
| 4 | Hex Editor | Ctrl+4 | Undo/redo, hex+ASCII search, goto, write-back |
| 5 | Filesystem | Ctrl+5 | ext4 browser (placeholder) |
| 6 | Image Manager | Ctrl+6 | Load/save images, binary diff, sector map |

Other hotkeys: `Ctrl+L` toggle log, `Ctrl+Z/Y` undo/redo, `Escape` cancel.

### Typed Command Dispatch

All operations go through `Command` enum — type-safe, with automatic confirm dialogs for destructive operations (write, erase, restore).

### Adding a New Backend

1. Create a new crate (e.g., `programmer-ch341`)
2. Implement `Programmer` trait for your hardware
3. Register in `programmer-gui/src/app.rs`

### Dependencies on emmc-core

`programmer-fpga` uses `emmc-core` via path dependency (`../../emmc-gui/crates/emmc-core`):
- `EmmcConnection` — serial protocol
- `CidInfo` — CID parsing
- `partition`, `ext4` — filesystem support

## Market Context

| Product | Price | Platform | eMMC | Open Source |
|---------|-------|----------|------|-------------|
| RT809H | ~$125 | Win | + | - |
| EasyJTAG | ~$350 | Win | + | - |
| Medusa Pro II | ~$600 | Win | + | - |
| **This** | **free** | **Cross** | **+** | **+** |
