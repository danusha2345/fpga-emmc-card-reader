#!/usr/bin/env python3
"""
FT232H Async 245 FIFO transport layer.

Drop-in replacement for serial.Serial when FT232H is configured
for async 245 FIFO mode (via EEPROM). Provides the same read()/write()/close()
interface used by emmc_tool.py.

Requirements:
  pip install pyftdi

EEPROM setup (one-time):
  Must be set to "245 FIFO" mode using ftdi_eeprom or FT_PROG.
"""

import time


class FifoTransport:
    """FT232H async 245 FIFO transport (replaces serial.Serial)"""

    # Serial number of the FT232H FIFO adapter.
    # When multiple FTDI devices are on the bus,
    # we disambiguate by serial number to avoid opening the wrong one.
    FT232H_SERIAL = "FTBMGALQ"

    def __init__(self, vid=0x0403, pid=0x6014, interface=1, serial=None):
        """
        Open FTDI device in async 245 FIFO mode.

        Args:
            vid: USB vendor ID (default: FTDI 0x0403)
            pid: USB product ID (default: FT232H 0x6014, FT2232H 0x6010)
            interface: USB interface number (1 = FT232H, 2 = FT2232H Channel B)
            serial: USB serial number string (default: auto-detect)
        """
        try:
            from pyftdi.ftdi import Ftdi
        except ImportError:
            raise ImportError(
                "pyftdi is required for FIFO transport.\n"
                "Install with: pip install pyftdi"
            )

        self.ftdi = Ftdi()
        target_sn = serial or self._find_fifo_device(Ftdi, vid, pid)
        if target_sn:
            url = f"ftdi://0x{vid:04x}:0x{pid:04x}:{target_sn}/{interface}"
            self.ftdi.open_from_url(url)
        else:
            self.ftdi.open(vendor=vid, product=pid, interface=interface)
        # Set bitmode to async 245 FIFO (0x00 = reset, then async FIFO)
        # Bitmode 0x00 = reset to default (async FIFO when EEPROM configured)
        self.ftdi.set_bitmode(0x00, Ftdi.BitMode.RESET)
        # Purge buffers
        self.ftdi.purge_buffers()
        # Set latency timer to 2ms (minimum for throughput)
        self.ftdi.set_latency_timer(2)
        # Set USB timeouts via property
        self.ftdi.timeouts = (500, 500)
        # Warmup: first read after open may return empty (USB init latency)
        self._warmup()
        self.timeout = 2.0  # read timeout in seconds (serial.Serial compat)
        self.port = f"ftdi://0x{vid:04x}:0x{pid:04x}/{interface}"

    @staticmethod
    def _find_fifo_device(Ftdi, vid, pid):
        """Find the FT232H FIFO adapter among multiple FTDI devices."""
        try:
            devices = Ftdi.list_devices()
        except Exception:
            return None
        # If only one device, no disambiguation needed
        if len(devices) <= 1:
            return None
        # Look for known FT232H by serial number
        for url_desc, _ in devices:
            if (url_desc.vid == vid and url_desc.pid == pid
                    and url_desc.sn == FifoTransport.FT232H_SERIAL):
                return url_desc.sn
        return None

    def _warmup(self):
        """Send a dummy PING to prime the USB read pipeline.

        The first read_data() after open() often returns 0 bytes. Send a PING
        and drain the response to ensure subsequent commands work reliably.
        """
        # CRC-8 (poly 0x07) of PING header [0x01, 0x00, 0x00]
        ping_packet = bytes([0xAA, 0x01, 0x00, 0x00, 0x6B])
        time.sleep(0.05)
        self.ftdi.read_data(512)  # drain stale data
        # Send PINGs until we get a response (usually 1-2 attempts)
        for attempt in range(5):
            self.ftdi.write_data(ping_packet)
            for _ in range(20):
                time.sleep(0.005)
                resp = self.ftdi.read_data(64)
                if resp:
                    time.sleep(0.01)
                    self.ftdi.read_data(512)  # drain remainder
                    return
        # Fallback: drain and continue
        self.ftdi.read_data(512)

    @property
    def in_waiting(self):
        """Number of bytes available to read (for compatibility)."""
        # pyftdi doesn't expose this directly; return 0 as conservative estimate
        return 0

    def write(self, data: bytes) -> int:
        """
        Write data to FT232H TX FIFO.

        Args:
            data: bytes to write

        Returns:
            Number of bytes written
        """
        written = self.ftdi.write_data(data)
        return written

    def read(self, size: int) -> bytes:
        """
        Read up to `size` bytes from FT232H RX FIFO.
        Blocks until at least 1 byte is available or timeout expires.
        Compatible with serial.Serial.read() behavior.

        Args:
            size: maximum number of bytes to read

        Returns:
            bytes read (empty bytes on timeout)
        """
        buf = bytearray()
        deadline = time.monotonic() + self.timeout
        while len(buf) < size:
            remaining = size - len(buf)
            chunk = self.ftdi.read_data(remaining)
            if chunk:
                buf.extend(chunk)
                # Return as soon as we have data (like serial.Serial)
                if len(buf) >= size:
                    break
            else:
                if time.monotonic() > deadline:
                    break
                time.sleep(0.0005)
        return bytes(buf)

    def flush(self):
        """No-op for compatibility with serial.Serial.flush()."""
        pass

    def read_all(self, size: int, timeout: float = 5.0) -> bytes:
        """
        Read exactly `size` bytes, blocking until all received or timeout.

        Args:
            size: exact number of bytes to read
            timeout: timeout in seconds

        Returns:
            bytes read

        Raises:
            TimeoutError: if not all bytes received within timeout
        """
        buf = bytearray()
        deadline = time.monotonic() + timeout
        while len(buf) < size:
            remaining = size - len(buf)
            chunk = self.ftdi.read_data(remaining)
            if chunk:
                buf.extend(chunk)
            else:
                if time.monotonic() > deadline:
                    raise TimeoutError(
                        f"FIFO read timeout: got {len(buf)}/{size} bytes"
                    )
                time.sleep(0.001)
        return bytes(buf)

    def reset_input_buffer(self):
        """Purge RX buffer."""
        self.ftdi.purge_rx_buffer()

    def reset_output_buffer(self):
        """Purge TX buffer."""
        self.ftdi.purge_tx_buffer()

    def close(self):
        """Close the FTDI device."""
        if self.ftdi:
            self.ftdi.close()
            self.ftdi = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def __repr__(self):
        return f"FifoTransport(FT232H async 245 FIFO)"
