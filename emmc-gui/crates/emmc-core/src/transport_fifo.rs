//! FT232H Async 245 FIFO transport layer.
//!
//! Drop-in replacement for SerialTransport when FT232H is configured
//! for async 245 FIFO mode (via EEPROM). Port of Python `fifo_transport.py`.
//!
//! Requires `fifo` feature: `cargo build --features fifo`

use anyhow::{bail, Context, Result};
use rusb::{DeviceHandle, GlobalContext};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::protocol::crc8;
use crate::transport::Transport;

const FTDI_VID: u16 = 0x0403;
const FTDI_PID_FT232H: u16 = 0x6014;
/// Known FT232H serial number for disambiguation
const FT232H_SERIAL: &str = "FTBMGALQ";

// FTDI SIO vendor commands (bRequest values)
const SIO_RESET: u8 = 0x00;
const SIO_SET_LATENCY_TIMER: u8 = 0x09;
const SIO_SET_BITMODE: u8 = 0x0B;

// SIO_RESET wValue sub-commands
const SIO_RESET_SIO: u16 = 0;
const SIO_RESET_PURGE_RX: u16 = 1;
const SIO_RESET_PURGE_TX: u16 = 2;

/// Modem status bytes prepended to every USB IN transfer by FTDI chip.
/// Must be stripped from received data.
const MODEM_STATUS_SIZE: usize = 2;

/// USB High-Speed bulk packet size
const USB_HS_PACKET_SIZE: usize = 512;

/// USB interface number (0-indexed, FT232H has only one interface)
const FTDI_IFACE: u8 = 0;
/// FTDI wIndex (1-based: interface_num + 1)
const FTDI_WINDEX: u16 = 1;

/// FT232H default endpoints
const EP_BULK_OUT: u8 = 0x02;
const EP_BULK_IN: u8 = 0x81;

/// Info about a detected FIFO-capable FT232H device
#[derive(Debug, Clone)]
pub struct FifoDeviceInfo {
    pub serial: String,
    pub description: String,
    pub is_known: bool,
}

/// Cached FTDI USB handle to avoid re-opening per operation.
/// The GUI architecture creates a new EmmcConnection per operation.
/// USB open/close/claim/release per operation causes instability —
/// the FTDI reset glitches the parallel FIFO lines, desyncing the FPGA.
/// Caching the handle keeps one persistent USB session (like Python does).
struct CachedFifo {
    handle: DeviceHandle<GlobalContext>,
    name: String,
}

static CACHED_HANDLE: Mutex<Option<CachedFifo>> = Mutex::new(None);

/// Enumerate FT232H devices on USB bus.
/// Returns info for each device, marking known boards by serial number.
pub fn find_fifo_devices() -> Vec<FifoDeviceInfo> {
    tracing::debug!("Scanning USB bus for FT232H devices (VID={:#06x}, PID={:#06x})", FTDI_VID, FTDI_PID_FT232H);
    let devices = match rusb::devices() {
        Ok(d) => d,
        Err(e) => {
            tracing::warn!("Failed to enumerate USB devices: {}", e);
            return Vec::new();
        }
    };

    let mut result = Vec::new();
    for device in devices.iter() {
        let desc = match device.device_descriptor() {
            Ok(d) => d,
            Err(_) => continue,
        };
        if desc.vendor_id() != FTDI_VID || desc.product_id() != FTDI_PID_FT232H {
            continue;
        }
        tracing::debug!("Found FT232H at bus {} addr {}", device.bus_number(), device.address());
        let handle = match device.open() {
            Ok(h) => h,
            Err(e) => {
                tracing::warn!("Cannot open FT232H (bus {} addr {}): {} — check permissions/udev rules",
                    device.bus_number(), device.address(), e);
                continue;
            }
        };
        let serial = handle
            .read_serial_number_string_ascii(&desc)
            .unwrap_or_default();
        let description = handle
            .read_product_string_ascii(&desc)
            .unwrap_or_else(|_| "FT232H".to_string());
        let is_known = serial == FT232H_SERIAL;
        tracing::info!("FT232H detected: {} (SN: {})", description, serial);
        result.push(FifoDeviceInfo {
            serial,
            description,
            is_known,
        });
    }
    tracing::debug!("FIFO scan complete: {} device(s) found", result.len());
    result
}

/// FT245 async FIFO transport over FT232H.
pub struct FifoTransport {
    /// Option to allow take() in Drop for caching
    handle: Option<DeviceHandle<GlobalContext>>,
    timeout: Duration,
    name: String,
    /// Internal read buffer for data left over from USB bulk reads.
    /// FTDI returns data in 512-byte USB packets; protocol reads may request
    /// fewer bytes, so we must buffer the remainder.
    read_buf: Vec<u8>,
    read_pos: usize,
}

impl FifoTransport {
    /// Get the USB handle (always Some except during Drop).
    fn handle(&self) -> &DeviceHandle<GlobalContext> {
        self.handle.as_ref().expect("FIFO handle used after drop")
    }

    /// Open FT232H in async 245 FIFO mode.
    /// Reuses a cached USB handle if available (avoids FTDI reset glitch).
    /// Auto-detects by serial number when multiple FTDI devices are present.
    pub fn open() -> Result<Self> {
        // Try to reuse cached handle first
        if let Ok(mut cache) = CACHED_HANDLE.lock() {
            if let Some(cached) = cache.take() {
                tracing::debug!("Reusing cached FIFO handle ({})", cached.name);
                let transport = Self {
                    handle: Some(cached.handle),
                    timeout: Duration::from_secs(2),
                    name: cached.name,
                    read_buf: Vec::new(),
                    read_pos: 0,
                };
                // Light init: just purge stale data, no FTDI reset/warmup
                transport.ftdi_purge_rx()?;
                transport.ftdi_purge_tx()?;
                // Drain any stale data from FPGA side
                let _ = transport.ftdi_read(4096, Duration::from_millis(20));
                return Ok(transport);
            }
        }

        // First open: full initialization
        tracing::info!("Opening FT232H FIFO transport (first time)...");
        let devices = rusb::devices().context("Failed to enumerate USB devices")?;

        let mut candidates: Vec<_> = devices
            .iter()
            .filter(|d| {
                d.device_descriptor()
                    .map(|desc| {
                        desc.vendor_id() == FTDI_VID
                            && desc.product_id() == FTDI_PID_FT232H
                    })
                    .unwrap_or(false)
            })
            .collect();

        if candidates.is_empty() {
            bail!("No FT232H device found");
        }

        // Disambiguate: prefer known serial number
        let device = if candidates.len() == 1 {
            candidates.remove(0)
        } else {
            let mut found = None;
            for dev in &candidates {
                if let Ok(handle) = dev.open() {
                    if let Ok(desc) = dev.device_descriptor() {
                        if let Ok(sn) = handle.read_serial_number_string_ascii(&desc) {
                            if sn == FT232H_SERIAL {
                                found = Some(dev.clone());
                                break;
                            }
                        }
                    }
                }
            }
            found.unwrap_or_else(|| candidates.remove(0))
        };

        let handle = device.open().context("Failed to open FT232H")?;
        let serial = device
            .device_descriptor()
            .ok()
            .and_then(|desc| handle.read_serial_number_string_ascii(&desc).ok())
            .unwrap_or_default();

        tracing::info!("Using FT232H SN={}", serial);

        // Detach kernel driver (ftdi_sio) if attached
        if handle.kernel_driver_active(FTDI_IFACE).unwrap_or(false) {
            tracing::debug!("Detaching kernel driver from interface {}", FTDI_IFACE);
            handle
                .detach_kernel_driver(FTDI_IFACE)
                .context("Failed to detach kernel driver")?;
        }
        handle
            .claim_interface(FTDI_IFACE)
            .context("Failed to claim FT232H interface")?;
        tracing::debug!("Claimed interface {}, configuring FTDI...", FTDI_IFACE);

        let transport = Self {
            handle: Some(handle),
            timeout: Duration::from_secs(2),
            name: format!("FIFO FT232H ({})", if serial.is_empty() { "unknown" } else { &serial }),
            read_buf: Vec::new(),
            read_pos: 0,
        };

        // Full FTDI init (first time only): reset, bitmode, latency, purge
        transport.ftdi_reset()?;
        transport.ftdi_set_bitmode(0x00, 0x00)?; // Reset = async FIFO from EEPROM
        transport.ftdi_set_latency(2)?; // 2ms latency (minimum for throughput)
        transport.ftdi_purge_rx()?;
        transport.ftdi_purge_tx()?;

        // Warmup: first USB read after open may return empty
        transport.warmup()?;

        Ok(transport)
    }

    // --- FTDI vendor commands ---

    fn ftdi_control(&self, request: u8, value: u16) -> Result<()> {
        self.handle()
            .write_control(
                0x40, // bmRequestType: vendor, device, out
                request,
                value,
                FTDI_WINDEX,
                &[],
                Duration::from_secs(1),
            )
            .context("FTDI control transfer failed")?;
        Ok(())
    }

    fn ftdi_reset(&self) -> Result<()> {
        self.ftdi_control(SIO_RESET, SIO_RESET_SIO)
    }

    fn ftdi_set_bitmode(&self, mask: u8, mode: u8) -> Result<()> {
        self.ftdi_control(SIO_SET_BITMODE, (mode as u16) << 8 | mask as u16)
    }

    fn ftdi_set_latency(&self, ms: u8) -> Result<()> {
        self.ftdi_control(SIO_SET_LATENCY_TIMER, ms as u16)
    }

    fn ftdi_purge_rx(&self) -> Result<()> {
        self.ftdi_control(SIO_RESET, SIO_RESET_PURGE_RX)
    }

    fn ftdi_purge_tx(&self) -> Result<()> {
        self.ftdi_control(SIO_RESET, SIO_RESET_PURGE_TX)
    }

    // --- Raw USB I/O with FTDI modem status stripping ---

    /// Read raw data from FTDI, stripping modem status bytes from each USB packet.
    /// Returns actual payload data (may be empty if no data available).
    fn ftdi_read(&self, max_data: usize, timeout: Duration) -> Result<Vec<u8>> {
        // Each USB HS packet = 512 bytes, first 2 are modem status → 510 data
        let data_per_packet = USB_HS_PACKET_SIZE - MODEM_STATUS_SIZE;
        let packets_needed = (max_data + data_per_packet - 1) / data_per_packet;
        let usb_read_size = packets_needed * USB_HS_PACKET_SIZE;
        // Cap at reasonable size
        let usb_read_size = usb_read_size.min(64 * USB_HS_PACKET_SIZE);

        let mut raw = vec![0u8; usb_read_size];
        let n = match self.handle().read_bulk(EP_BULK_IN, &mut raw, timeout) {
            Ok(n) => n,
            Err(rusb::Error::Timeout) => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };

        if n == 0 {
            return Ok(Vec::new());
        }

        // Strip modem status from each 512-byte USB packet
        let mut result = Vec::with_capacity(n);
        let mut pos = 0;
        while pos < n {
            let chunk_end = (pos + USB_HS_PACKET_SIZE).min(n);
            if chunk_end - pos > MODEM_STATUS_SIZE {
                result.extend_from_slice(&raw[pos + MODEM_STATUS_SIZE..chunk_end]);
            }
            pos += USB_HS_PACKET_SIZE;
        }
        Ok(result)
    }

    /// Write raw data to FTDI TX FIFO.
    fn ftdi_write(&self, data: &[u8]) -> Result<()> {
        let mut offset = 0;
        while offset < data.len() {
            let n = self
                .handle()
                .write_bulk(EP_BULK_OUT, &data[offset..], self.timeout)?;
            offset += n;
        }
        Ok(())
    }

    /// Warmup: send PING and drain response to prime USB pipeline.
    /// Like Python FifoTransport._warmup().
    fn warmup(&self) -> Result<()> {
        let ping_crc = crc8(&[0x01, 0x00, 0x00]);
        let ping_packet = [0xAA, 0x01, 0x00, 0x00, ping_crc];

        std::thread::sleep(Duration::from_millis(50));
        let _ = self.ftdi_read(512, Duration::from_millis(50)); // drain stale

        for _ in 0..5 {
            let _ = self.ftdi_write(&ping_packet);
            for _ in 0..20 {
                std::thread::sleep(Duration::from_millis(5));
                if let Ok(data) = self.ftdi_read(64, Duration::from_millis(10)) {
                    if !data.is_empty() {
                        std::thread::sleep(Duration::from_millis(10));
                        let _ = self.ftdi_read(512, Duration::from_millis(10));
                        return Ok(());
                    }
                }
            }
        }
        // Fallback: drain and continue
        let _ = self.ftdi_read(512, Duration::from_millis(50));
        Ok(())
    }
}

impl FifoTransport {
    /// Consume up to `buf.len()` bytes from internal read buffer.
    /// Returns number of bytes consumed.
    fn consume_buffered(&mut self, buf: &mut [u8]) -> usize {
        let available = self.read_buf.len() - self.read_pos;
        if available == 0 {
            return 0;
        }
        let n = buf.len().min(available);
        buf[..n].copy_from_slice(&self.read_buf[self.read_pos..self.read_pos + n]);
        self.read_pos += n;
        // Compact buffer when fully consumed
        if self.read_pos == self.read_buf.len() {
            self.read_buf.clear();
            self.read_pos = 0;
        }
        n
    }

    /// Fill internal buffer from USB if empty.
    fn fill_buffer(&mut self, hint: usize, timeout: Duration) -> Result<()> {
        let data = self.ftdi_read(hint.max(64), timeout)?;
        if !data.is_empty() {
            // Compact any remaining data
            if self.read_pos > 0 {
                self.read_buf.drain(..self.read_pos);
                self.read_pos = 0;
            }
            self.read_buf.extend_from_slice(&data);
        }
        Ok(())
    }
}

impl Transport for FifoTransport {
    fn write_all(&mut self, data: &[u8]) -> Result<()> {
        self.ftdi_write(data)
    }

    fn flush(&mut self) -> Result<()> {
        Ok(()) // No-op for FIFO
    }

    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        // Try internal buffer first
        let n = self.consume_buffered(buf);
        if n > 0 {
            return Ok(n);
        }
        // Fill from USB
        let deadline = Instant::now() + self.timeout;
        loop {
            self.fill_buffer(buf.len(), Duration::from_millis(50))?;
            let n = self.consume_buffered(buf);
            if n > 0 {
                return Ok(n);
            }
            if Instant::now() > deadline {
                bail!("FIFO read timeout");
            }
            std::thread::sleep(Duration::from_micros(500));
        }
    }

    fn read_exact(&mut self, buf: &mut [u8]) -> Result<()> {
        let deadline = Instant::now() + self.timeout;
        let mut filled = 0;
        while filled < buf.len() {
            let n = self.consume_buffered(&mut buf[filled..]);
            if n > 0 {
                filled += n;
                continue;
            }
            // Need more data from USB
            self.fill_buffer(buf.len() - filled, Duration::from_millis(100))?;
            let n = self.consume_buffered(&mut buf[filled..]);
            if n > 0 {
                filled += n;
            } else if Instant::now() > deadline {
                bail!(
                    "FIFO read timeout: got {}/{} bytes",
                    filled,
                    buf.len()
                );
            } else {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
        Ok(())
    }

    fn set_timeout(&mut self, timeout: Duration) -> Result<()> {
        self.timeout = timeout;
        Ok(())
    }

    fn purge_input(&mut self) -> Result<()> {
        self.read_buf.clear();
        self.read_pos = 0;
        self.ftdi_purge_rx()
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn is_fifo(&self) -> bool {
        true
    }
}

impl Drop for FifoTransport {
    fn drop(&mut self) {
        // Cache the handle for reuse instead of releasing the USB interface.
        // This avoids the FTDI reset/claim/release cycle that causes FPGA desync.
        if let Some(handle) = self.handle.take() {
            if let Ok(mut cache) = CACHED_HANDLE.lock() {
                tracing::debug!("Caching FIFO handle for reuse");
                *cache = Some(CachedFifo {
                    handle,
                    name: self.name.clone(),
                });
                return;
            }
            // If mutex poisoned, release interface normally
            let _ = handle.release_interface(FTDI_IFACE);
        }
    }
}
