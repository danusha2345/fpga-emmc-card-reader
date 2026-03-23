use crate::logging::AppLog;
use crate::state::OperationProgress;
use crossbeam_channel::Sender;
use programmer_hal::traits::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[allow(unused_imports)]
use programmer_hal as _;

#[derive(Debug)]
pub enum WorkerMessage {
    PortsScanned(Vec<String>),
    FifoDevicesScanned {
        available: bool,
        info: Option<String>,
    },
    Connected,
    ConnectedWithSpeed {
        actual_baud: u32,
        baud_preset: u8,
        clk_preset: u8,
    },
    ChipIdentified(ChipInfo),
    ExtCsdRead(Vec<u8>),
    SectorsRead {
        lba: u32,
        data: Vec<u8>,
    },
    SectorsWritten {
        lba: u32,
        count: u32,
    },
    SectorsErased {
        lba: u32,
        count: u32,
    },
    SecureErased {
        lba: u32,
        count: u32,
    },
    CardStatusRead(u32),
    ControllerStatusRead(emmc_core::protocol::ControllerStatus),
    VerifyComplete {
        total_bytes: u64,
        mismatches: usize,
    },
    BlankCheckComplete {
        is_blank: bool,
        first_non_blank: Option<u64>,
    },
    PartitionSet(u8),
    ExtCsdWritten {
        index: u8,
        value: u8,
    },
    RawCmdResponse {
        data: Vec<u8>,
    },
    SpeedSet(u8),
    BaudSet {
        preset: u8,
        baud: u32,
    },
    BusWidthSet(u8),
    Reinitialized,
    DumpCompleted {
        bytes: u64,
        path: String,
    },
    RestoreCompleted {
        bytes: u64,
        path: String,
    },
    Ext4Loaded(crate::state::Ext4FsInfo),
    Ext4DirListing {
        path: String,
        entries: Vec<crate::state::Ext4Entry>,
    },
    Ext4FileContent {
        path: String,
        data: Vec<u8>,
    },
    Ext4FileWritten {
        path: String,
    },
    Ext4FileCreated {
        path: String,
    },
    Ext4SearchDone {
        query: String,
        results: Vec<crate::state::Ext4SearchResult>,
    },
    Progress(OperationProgress),
    Completed(String),
    Error(String),
}

pub struct ChannelProgress {
    tx: Sender<WorkerMessage>,
    cancel: Arc<AtomicBool>,
}

impl ChannelProgress {
    pub fn new(tx: Sender<WorkerMessage>, cancel: Arc<AtomicBool>) -> Self {
        Self { tx, cancel }
    }
}

impl ProgressReporter for ChannelProgress {
    fn report(&self, current: u64, total: u64, description: &str) {
        let _ = self.tx.send(WorkerMessage::Progress(OperationProgress {
            current,
            total,
            description: description.to_string(),
        }));
    }

    fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }
}

pub struct NullProgress;

impl ProgressReporter for NullProgress {
    fn report(&self, _current: u64, _total: u64, _description: &str) {}
    fn is_cancelled(&self) -> bool {
        false
    }
}

pub fn scan_ports(tx: Sender<WorkerMessage>, _log: AppLog) {
    std::thread::spawn(move || {
        let ports = list_available_ports();
        let _ = tx.send(WorkerMessage::PortsScanned(ports));
    });
}

/// Scan for FT245 FIFO devices (FT232H)
pub fn scan_fifo_devices(tx: Sender<WorkerMessage>, log: AppLog) {
    std::thread::spawn(move || {
        #[cfg(feature = "fifo")]
        {
            let devices = emmc_core::transport_fifo::find_fifo_devices();
            if let Some(dev) = devices.first() {
                let info = format!(
                    "{} (SN: {})",
                    dev.description,
                    if dev.serial.is_empty() {
                        "unknown"
                    } else {
                        &dev.serial
                    }
                );
                log.info(format!("FT232H found: {}", info));
                let _ = tx.send(WorkerMessage::FifoDevicesScanned {
                    available: true,
                    info: Some(info),
                });
            } else {
                log.debug("No FIFO devices found");
                let _ = tx.send(WorkerMessage::FifoDevicesScanned {
                    available: false,
                    info: None,
                });
            }
        }
        #[cfg(not(feature = "fifo"))]
        {
            let _ = &log;
            let _ = tx.send(WorkerMessage::FifoDevicesScanned {
                available: false,
                info: None,
            });
        }
    });
}

pub fn list_available_ports() -> Vec<String> {
    serialport::available_ports()
        .unwrap_or_default()
        .into_iter()
        .filter(|p| {
            let name = &p.port_name;
            name.contains("ttyACM") || name.contains("ttyUSB")
        })
        .map(|p| p.port_name)
        .collect()
}
