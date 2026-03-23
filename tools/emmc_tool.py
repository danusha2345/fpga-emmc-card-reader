#!/usr/bin/env python3
"""
eMMC Card Reader Tool
PC-side utility for Tang Nano 9K eMMC Card Reader

Usage:
    emmc_tool.py ping                           - Test connection
    emmc_tool.py info                           - Read eMMC CID/CSD
    emmc_tool.py read <lba> <count> <outfile>   - Read sectors to file
    emmc_tool.py write <lba> <infile>           - Write file to sectors
    emmc_tool.py dump <outfile>                 - Full eMMC dump
    emmc_tool.py hexdump <lba> [count]           - Hex dump sectors
    emmc_tool.py verify <lba> <infile>          - Verify eMMC vs file
    emmc_tool.py status                         - Controller status
    emmc_tool.py partitions                     - Show partition table
    emmc_tool.py mount <part_num> <mountpoint>  - Dump partition & loop-mount
    emmc_tool.py umount <mountpoint>            - Unmount & cleanup
    emmc_tool.py ext4-info [partition]          - Show ext4 filesystem info
    emmc_tool.py ext4-ls [path]                - List directory on ext4
    emmc_tool.py ext4-cat <path>               - Read file from ext4
    emmc_tool.py ext4-write <path> --data-hex  - Overwrite file on ext4
    emmc_tool.py ext4-create <dir> <name>      - Create file on ext4
"""

import sys
import struct
import time
import argparse
import os
import json
import subprocess
import uuid
import hmac
import hashlib
import serial

# ext4 filesystem support
try:
    from ext4_utils import Ext4
    HAS_EXT4 = True
except ImportError:
    try:
        import sys as _sys
        _sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from ext4_utils import Ext4
        HAS_EXT4 = True
    except ImportError:
        HAS_EXT4 = False

# Optional: tqdm for progress bars
try:
    from tqdm import tqdm
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False
    tqdm = None

# Protocol constants
HEADER_TX = 0xAA  # PC -> FPGA
HEADER_RX = 0x55  # FPGA -> PC
BAUD_RATE = 3_000_000  # Default 3 Mbaud (use --baud 2000000 if unstable)
SECTOR_SIZE = 512

# Command IDs
CMD_PING          = 0x01
CMD_GET_INFO      = 0x02
CMD_READ_SECTOR   = 0x03
CMD_WRITE_SECTOR  = 0x04
CMD_ERASE         = 0x05
CMD_GET_STATUS    = 0x06
CMD_GET_EXT_CSD   = 0x07  # Read 512-byte Extended CSD
CMD_SET_PARTITION  = 0x08  # Switch partition (0=user, 1=boot0, 2=boot1)
CMD_WRITE_EXT_CSD  = 0x09  # Write ExtCSD byte (generic CMD6 SWITCH)
CMD_GET_CARD_STATUS = 0x0A  # CMD13 SEND_STATUS (Card Status Register)
CMD_REINIT         = 0x0B  # Full re-initialization (CMD0 + init sequence)
CMD_SECURE_ERASE   = 0x0C  # Secure Erase (CMD38 arg=0x80000000)
CMD_SET_CLK_DIV    = 0x0D  # Runtime eMMC clock speed switching (preset index)
CMD_SEND_RAW       = 0x0E  # Send arbitrary eMMC command
CMD_SET_BAUD       = 0x0F  # Set UART baud rate preset (0=3M, 1=6M, 3=12M)
CMD_SET_RPMB_MODE  = 0x10  # RPMB mode: force CMD25/CMD18 for count=1
CMD_SET_BUS_WIDTH  = 0x11  # Set eMMC bus width: 0=1-bit, 1=4-bit

# Clock speed presets: index → (divider, frequency string)
# At 60 MHz sys_clk: freq = 60M / (divider * 2)
CLK_PRESETS = {
    0: (15, "2 MHz"),
    1: (8,  "3.75 MHz"),
    2: (5,  "6 MHz"),
    3: (3,  "10 MHz"),
    4: (2,  "15 MHz"),
    5: (2,  "15 MHz"),
    6: (1,  "30 MHz"),
}

# eMMC clock frequency by preset (Hz), derived from 60 MHz / (2*divisor)
EMMC_CLK_FREQ = {
    0: 2_000_000,
    1: 3_750_000,
    2: 6_000_000,
    3: 10_000_000,
    4: 15_000_000,
    5: 15_000_000,
    6: 30_000_000,
}

# UART baud rate presets: index → (baud_rate, description)
# Preset 2 (9M) removed: FT2232HL fractional divisor causes ~11% baud error
BAUD_PRESETS = {
    0: (3_000_000,  "3 Mbaud"),
    1: (6_000_000,  "6 Mbaud"),
    3: (12_000_000, "12 Mbaud"),
}

# Status codes
STATUS_OK       = 0x00
STATUS_ERR_CRC  = 0x01
STATUS_ERR_CMD  = 0x02
STATUS_ERR_EMMC = 0x03
STATUS_BUSY     = 0x04

STATUS_NAMES = {
    STATUS_OK: "OK",
    STATUS_ERR_CRC: "CRC Error",
    STATUS_ERR_CMD: "Unknown Command",
    STATUS_ERR_EMMC: "eMMC Error",
    STATUS_BUSY: "Busy",
}

# RPMB test key (hardcoded)
RPMB_TEST_KEY = bytes([
    0xD3, 0xEB, 0x3E, 0xC3, 0x6E, 0x33, 0x4C, 0x9F,
    0x98, 0x8C, 0xE2, 0xC0, 0xB8, 0x59, 0x54, 0x61,
    0x0D, 0x2B, 0xCF, 0x86, 0x64, 0x84, 0x4D, 0xF2,
    0xAB, 0x56, 0xC9, 0xB4, 0x1B, 0xB7, 0x01, 0xE4,
])

RPMB_RESULT_NAMES = {
    0x0000: "OK",
    0x0001: "General failure",
    0x0002: "Authentication failure",
    0x0003: "Counter failure",
    0x0004: "Address failure",
    0x0005: "Write failure",
    0x0006: "Read failure",
    0x0007: "Authentication key not yet programmed",
}


def build_rpmb_frame(req_type, address=0, block_count=0, nonce=None, data=None, mac=None):
    """Build a 512-byte RPMB request frame.

    Frame layout (512 bytes):
      [196:228] - MAC (32 bytes, HMAC-SHA256)
      [228:484] - Data (256 bytes)
      [484:500] - Nonce (16 bytes)
      [500:504] - Write Counter (4 bytes, big-endian)
      [504:506] - Address (2 bytes, big-endian)
      [506:508] - Block Count (2 bytes, big-endian)
      [508:510] - Result (2 bytes, big-endian)
      [510:512] - Request/Response Type (2 bytes, big-endian)
    """
    frame = bytearray(512)
    if mac:
        frame[196:228] = mac[:32]
    if data:
        frame[228:484] = data[:256]
    if nonce:
        frame[484:500] = nonce[:16]
    struct.pack_into('>H', frame, 504, address)
    struct.pack_into('>H', frame, 506, block_count)
    struct.pack_into('>H', frame, 510, req_type)
    return bytes(frame)


def parse_rpmb_frame(frame):
    """Parse a 512-byte RPMB response frame."""
    return {
        'mac':           frame[196:228],
        'data':          frame[228:484],
        'nonce':         frame[484:500],
        'write_counter': struct.unpack('>I', frame[500:504])[0],
        'address':       struct.unpack('>H', frame[504:506])[0],
        'block_count':   struct.unpack('>H', frame[506:508])[0],
        'result':        struct.unpack('>H', frame[508:510])[0],
        'req_resp_type': struct.unpack('>H', frame[510:512])[0],
    }


def rpmb_calc_mac(frame_bytes, key=None):
    """Calculate HMAC-SHA256 MAC for RPMB frame.

    MAC covers bytes 228..511 of each frame (data + nonce + counter + addr +
    count + result + type = 284 bytes).
    """
    if key is None:
        key = RPMB_TEST_KEY
    return hmac.new(key, frame_bytes[228:512], hashlib.sha256).digest()


def rpmb_verify_mac(frame_bytes, key=None):
    """Verify HMAC-SHA256 MAC in RPMB response frame. Returns True if valid."""
    expected = rpmb_calc_mac(frame_bytes, key)
    return frame_bytes[196:228] == expected


def crc8(data: bytes) -> int:
    """CRC-8 with polynomial 0x07."""
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


class EmmcTool:
    def __init__(self, port: str, timeout: float = 2.0, baud: int = BAUD_RATE,
                 ignore_crc: bool = False, multi_sector: bool = False,
                 use_fifo: bool = False):
        self._use_fifo = use_fifo
        if use_fifo:
            # FT245 async FIFO mode via FT232H
            from fifo_transport import FifoTransport
            self.ser = FifoTransport()
            print("Using FT245 FIFO transport (FT232H)")
        else:
            # Traditional UART serial port
            # FT2232C clones need a warm-up: open/close at 3M baud first,
            # otherwise Channel B stays inactive after driver load.
            if "ttyUSB" in port:
                try:
                    s = serial.Serial(port, 3000000, timeout=0.1)
                    s.close()
                    time.sleep(0.05)
                except serial.SerialException:
                    pass
            self.ser = serial.Serial(port, baud, timeout=timeout)
            self.ser.reset_input_buffer()
        self.max_retries = 0
        self.ignore_crc = ignore_crc
        self._use_multi_sector = multi_sector
        self._current_baud = baud
        self._current_emmc_freq = EMMC_CLK_FREQ[0]  # default 2 MHz

    def close(self):
        self.ser.close()

    def _safe_read_chunk(self) -> int:
        """CMD18 chunk size — always 64 with FPGA CLK gating backpressure."""
        return 64

    def enable_cache(self) -> bool:
        """Enable eMMC write cache (ExtCSD[33]). Returns True if enabled."""
        ext_csd = self.get_ext_csd()
        cache_size = struct.unpack_from('<I', ext_csd, 249)[0]  # CACHE_SIZE
        if cache_size == 0:
            return False  # card doesn't support cache
        if ext_csd[33] == 1:
            return True  # already enabled
        self.write_ext_csd(33, 1)  # CACHE_CTRL = 1
        return True

    def flush_cache(self):
        """Flush eMMC write cache to flash (ExtCSD[32])."""
        self.write_ext_csd(32, 1)  # FLUSH_CACHE = 1

    def _with_retry(self, func, *args, **kwargs):
        """Execute func with exponential backoff retry."""
        last_err = None
        for attempt in range(self.max_retries + 1):
            try:
                return func(*args, **kwargs)
            except Exception as e:
                last_err = e
                if attempt < self.max_retries:
                    delay = 0.1 * (2 ** attempt)
                    print(f"  Retry {attempt + 1}/{self.max_retries} after {delay:.1f}s: {e}")
                    time.sleep(delay)
                    self.ser.reset_input_buffer()
        raise last_err

    def _send_command(self, cmd_id: int, payload: bytes = b"") -> tuple:
        """Send command and receive response.

        Returns: (status, payload_bytes)
        """
        length = len(payload)
        # Build packet: [0xAA] [CMD] [LEN_H] [LEN_L] [PAYLOAD] [CRC8]
        # CRC covers CMD + LEN_H + LEN_L + PAYLOAD
        crc_data = struct.pack(">BH", cmd_id, length) + payload
        checksum = crc8(crc_data)

        packet = bytes([HEADER_TX]) + struct.pack(">BH", cmd_id, length) + payload + bytes([checksum])
        self.ser.write(packet)
        self.ser.flush()

        return self._recv_response()

    def _recv_response(self) -> tuple:
        """Receive response packet.

        Returns: (cmd_id, status, payload_bytes)
        """
        # Wait for header byte 0x55
        while True:
            b = self.ser.read(1)
            if len(b) == 0:
                raise TimeoutError("No response from FPGA")
            if b[0] == HEADER_RX:
                break

        # Read CMD_ID, STATUS, LEN_H, LEN_L
        hdr = self.ser.read(4)
        if len(hdr) < 4:
            raise TimeoutError("Incomplete response header")

        cmd_id = hdr[0]
        status = hdr[1]
        length = (hdr[2] << 8) | hdr[3]

        # Read payload
        payload = b""
        if length > 0:
            payload = self.ser.read(length)
            if len(payload) < length:
                raise TimeoutError(f"Incomplete payload: got {len(payload)}/{length}")

        # Read CRC
        crc_byte = self.ser.read(1)
        if len(crc_byte) == 0:
            raise TimeoutError("Missing CRC byte")

        # Verify CRC
        crc_data = struct.pack(">BBH", cmd_id, status, length) + payload
        expected_crc = crc8(crc_data)
        if crc_byte[0] != expected_crc:
            msg = f"CRC mismatch (got 0x{crc_byte[0]:02X}, expected 0x{expected_crc:02X})"
            if self.ignore_crc:
                print(f"Warning: {msg} (ignored)")
            else:
                raise RuntimeError(msg)

        return cmd_id, status, payload

    def ping(self) -> bool:
        """Test connection."""
        _, status, _ = self._send_command(CMD_PING)
        return status == STATUS_OK

    def get_info(self) -> dict:
        """Read CID and CSD registers."""
        _, status, payload = self._send_command(CMD_GET_INFO)
        if status != STATUS_OK:
            raise RuntimeError(f"GET_INFO failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")
        if len(payload) < 32:
            raise RuntimeError(f"Short info payload: {len(payload)} bytes")

        cid = payload[0:16]
        csd = payload[16:32]
        return self._parse_info(cid, csd)

    def _parse_info(self, cid_raw: bytes, csd_raw: bytes) -> dict:
        """Parse CID and CSD fields."""
        info = {
            "cid_raw": cid_raw.hex(),
            "csd_raw": csd_raw.hex(),
        }
        # CID fields (eMMC)
        info["manufacturer_id"] = cid_raw[0]
        info["device_type"] = (cid_raw[1] << 8) | cid_raw[2]  # CBX + OID
        info["product_name"] = cid_raw[3:9].decode("ascii", errors="replace").strip()
        info["product_rev"] = f"{cid_raw[9] >> 4}.{cid_raw[9] & 0xF}"
        info["serial_number"] = struct.unpack(">I", cid_raw[10:14])[0]
        info["mfg_date"] = f"{2013 + (cid_raw[14] >> 4)}-{cid_raw[14] & 0xF:02d}"

        # CSD parsing
        csd_structure = (csd_raw[0] >> 6) & 0x03
        read_bl_len = csd_raw[5] & 0x0F
        c_size = ((csd_raw[6] & 0x03) << 10) | (csd_raw[7] << 2) | (csd_raw[8] >> 6)
        c_size_mult = ((csd_raw[9] & 0x03) << 1) | (csd_raw[10] >> 7)
        info["csd_structure"] = csd_structure
        if c_size == 0xFFF:
            info["capacity_note"] = ">= 2 GB (need EXT_CSD for exact size)"
        else:
            blocks = (c_size + 1) * (1 << (c_size_mult + 2))
            info["capacity_bytes"] = blocks * (1 << read_bl_len)

        return info

    def _send_command_no_recv(self, cmd_id: int, payload: bytes = b""):
        """Send command without waiting for response."""
        length = len(payload)
        crc_data = struct.pack(">BH", cmd_id, length) + payload
        checksum = crc8(crc_data)

        packet = bytes([HEADER_TX]) + struct.pack(">BH", cmd_id, length) + payload + bytes([checksum])
        self.ser.write(packet)
        self.ser.flush()

    def read_sectors(self, lba: int, count: int) -> bytes:
        """Read sectors from eMMC."""
        return self._with_retry(self._read_sectors_impl, lba, count)

    @staticmethod
    def _validate_lba_range(lba: int, count: int):
        """Validate LBA + count fits in 32-bit and count fits in 16-bit."""
        if count > 0xFFFF:
            raise ValueError(f"count {count} exceeds 16-bit max (65535)")
        if lba > 0xFFFFFFFF:
            raise ValueError(f"LBA 0x{lba:X} exceeds 32-bit max")
        if lba + count > 0xFFFFFFFF:
            raise ValueError(f"LBA range 0x{lba:X}+{count} overflows 32-bit address space")

    def _read_sectors_impl(self, lba: int, count: int) -> bytes:
        self._validate_lba_range(lba, count)

        if count == 0:
            return b""

        if not self._use_multi_sector:
            return self._read_sectors_single(lba, count)

        # Multi-sector read: one command, N+1 responses
        payload = struct.pack(">IH", lba, count)
        self._send_command_no_recv(CMD_READ_SECTOR, payload)

        data = b""
        for i in range(count):
            _, status, sector_data = self._recv_response()
            if status != STATUS_OK:
                raise RuntimeError(
                    f"Read error at sector {i}/{count} (LBA {lba + i}): "
                    f"{STATUS_NAMES.get(status, f'0x{status:02X}')}")
            if len(sector_data) != SECTOR_SIZE:
                raise RuntimeError(
                    f"Short sector data at {i}/{count}: {len(sector_data)} bytes")
            data += sector_data

        # Receive final completion packet (0-byte payload)
        _, final_status, _ = self._recv_response()
        if final_status != STATUS_OK:
            raise RuntimeError(
                f"Multi-read completion error: "
                f"{STATUS_NAMES.get(final_status, f'0x{final_status:02X}')}")

        return data

    def _read_sectors_single(self, lba: int, count: int) -> bytes:
        """Single-sector reads (CMD17), one command per sector.
        FPGA sends 2 packets per single read: 512B sector data + 0B completion."""
        data = b""
        for i in range(count):
            payload = struct.pack(">IH", lba + i, 1)
            self._send_command_no_recv(CMD_READ_SECTOR, payload)
            # Packet 1: sector data (512 bytes)
            _, status, sector_data = self._recv_response()
            if status != STATUS_OK:
                raise RuntimeError(f"Read error at LBA {lba + i}: {STATUS_NAMES.get(status, f'0x{status:02X}')}")
            # Packet 2: completion (0 bytes)
            _, final_status, _ = self._recv_response()
            if final_status != STATUS_OK:
                raise RuntimeError(f"Read completion error at LBA {lba + i}: {STATUS_NAMES.get(final_status, f'0x{final_status:02X}')}")
            data += sector_data
        return data

    def write_sectors(self, lba: int, data: bytes):
        """Write sectors to eMMC. Uses multi-sector CMD25 if enabled and count > 1."""
        if len(data) % SECTOR_SIZE != 0:
            # Pad to sector boundary
            data += b'\x00' * (SECTOR_SIZE - len(data) % SECTOR_SIZE)

        count = len(data) // SECTOR_SIZE
        if self._use_multi_sector and count > 1:
            self._with_retry(self._write_sectors_multi, lba, data)
        else:
            for i in range(count):
                sector = data[i * SECTOR_SIZE:(i + 1) * SECTOR_SIZE]
                self._with_retry(self._write_single_sector, lba + i, sector)

    def _write_single_sector(self, lba: int, sector: bytes):
        self._validate_lba_range(lba, 1)
        payload = struct.pack(">IH", lba, 1) + sector
        _, status, _ = self._send_command(CMD_WRITE_SECTOR, payload)
        if status != STATUS_OK:
            raise RuntimeError(f"Write error at LBA {lba}: {STATUS_NAMES.get(status, f'0x{status:02X}')}")

    def _write_sectors_multi(self, lba: int, data: bytes):
        """Multi-sector write (CMD25): one UART packet with N*512 bytes payload."""
        count = len(data) // SECTOR_SIZE
        self._validate_lba_range(lba, count)
        payload = struct.pack(">IH", lba, count) + data
        _, status, _ = self._send_command(CMD_WRITE_SECTOR, payload)
        if status != STATUS_OK:
            raise RuntimeError(f"Multi-write error at LBA {lba}, count={count}: "
                               f"{STATUS_NAMES.get(status, f'0x{status:02X}')}")

    def get_status(self) -> int:
        """Get controller status."""
        _, status, payload = self._send_command(CMD_GET_STATUS)
        if status != STATUS_OK:
            raise RuntimeError(f"GET_STATUS failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")
        return payload[0] if payload else 0

    def get_ext_csd(self) -> bytes:
        """Read 512-byte Extended CSD register.
        FPGA sends 2 packets: 512B sector data + 0B completion."""
        self._send_command_no_recv(CMD_GET_EXT_CSD)
        # Packet 1: sector data (512 bytes)
        _, status, payload = self._recv_response()
        if status != STATUS_OK:
            raise RuntimeError(f"GET_EXT_CSD failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")
        if len(payload) < 512:
            raise RuntimeError(f"Short ExtCSD: {len(payload)} bytes")
        # Packet 2: completion (0 bytes) — drain to keep protocol in sync
        _, final_status, _ = self._recv_response()
        if final_status != STATUS_OK:
            raise RuntimeError(f"GET_EXT_CSD completion error: {STATUS_NAMES.get(final_status, f'0x{final_status:02X}')}")
        return payload[:512]

    def parse_ext_csd(self, ext_csd: bytes) -> dict:
        """Parse important fields from Extended CSD."""
        info = {}
        # Device life time estimation (bytes 267-269)
        info["life_time_est_a"] = ext_csd[267]  # Type A (SLC)
        info["life_time_est_b"] = ext_csd[268]  # Type B (MLC)
        info["pre_eol_info"] = ext_csd[269]     # Pre-EOL info

        # Capacity (bytes 212-215, SEC_COUNT)
        sec_count = struct.unpack_from("<I", ext_csd, 212)[0]
        info["sec_count"] = sec_count
        info["capacity_bytes"] = sec_count * 512

        # Boot partition size (byte 226, BOOT_SIZE_MULTI)
        boot_size_multi = ext_csd[226]
        info["boot_partition_size"] = boot_size_multi * 128 * 1024  # in bytes

        # RPMB size (byte 168, RPMB_SIZE_MULT)
        rpmb_size_mult = ext_csd[168]
        info["rpmb_size"] = rpmb_size_mult * 128 * 1024  # in bytes

        # Current partition config (byte 179, PARTITION_CONFIG)
        part_config = ext_csd[179]
        info["boot_ack"] = (part_config >> 6) & 0x01
        info["boot_partition"] = (part_config >> 3) & 0x07
        info["partition_access"] = part_config & 0x07

        # Device type (byte 196)
        device_type = ext_csd[196]
        info["hs_support"] = bool(device_type & 0x01)
        info["hs52_support"] = bool(device_type & 0x02)
        info["ddr_support"] = bool(device_type & 0x04)

        # Firmware version (bytes 254-261)
        info["fw_version"] = ext_csd[254:262].hex()

        return info

    def set_partition(self, partition: int) -> bool:
        """Switch eMMC partition access.

        Args:
            partition: 0=user, 1=boot0, 2=boot1, 3=RPMB

        Returns: True if successful
        """
        payload = bytes([partition & 0x07])
        _, status, _ = self._send_command(CMD_SET_PARTITION, payload)
        if status != STATUS_OK:
            raise RuntimeError(f"SET_PARTITION failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")
        return True

    def erase(self, lba: int, count: int):
        """Erase sectors on eMMC (CMD35 → CMD36 → CMD38)."""
        self._validate_lba_range(lba, count)
        payload = struct.pack(">IH", lba, count)
        _, status, _ = self._send_command(CMD_ERASE, payload)
        if status != STATUS_OK:
            raise RuntimeError(f"ERASE failed at LBA {lba}: {STATUS_NAMES.get(status, f'0x{status:02X}')}")

    def secure_erase(self, lba: int, count: int):
        """Secure erase sectors on eMMC (CMD35 → CMD36 → CMD38 arg=0x80000000)."""
        self._validate_lba_range(lba, count)
        payload = struct.pack(">IH", lba, count)
        _, status, _ = self._send_command(CMD_SECURE_ERASE, payload)
        if status != STATUS_OK:
            raise RuntimeError(f"SECURE ERASE failed at LBA {lba}: {STATUS_NAMES.get(status, f'0x{status:02X}')}")

    def write_ext_csd(self, index: int, value: int):
        """Write a byte to ExtCSD via CMD6 SWITCH.

        Args:
            index: ExtCSD byte index (0-511)
            value: New value (0-255)
        """
        payload = bytes([index & 0xFF, value & 0xFF])
        _, status, _ = self._send_command(CMD_WRITE_EXT_CSD, payload)
        if status != STATUS_OK:
            raise RuntimeError(f"WRITE_EXT_CSD failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")

    def get_card_status(self) -> int:
        """Read Card Status Register via CMD13 SEND_STATUS.

        Returns:
            32-bit Card Status Register value.
        """
        _, status, data = self._send_command(CMD_GET_CARD_STATUS)
        if status != STATUS_OK:
            raise RuntimeError(f"GET_CARD_STATUS failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")
        if len(data) != 4:
            raise RuntimeError(f"GET_CARD_STATUS: expected 4 bytes, got {len(data)}")
        return int.from_bytes(data, 'big')

    def reinit(self) -> None:
        """Full re-initialization: CMD0 + init sequence.

        This resets the eMMC card and runs the full init sequence
        (CMD0→CMD1→CMD2→CMD3→CMD7→CMD6). Useful for error recovery.
        """
        old_timeout = self.ser.timeout
        self.ser.timeout = 5  # init can take up to ~1s
        try:
            _, status, _ = self._send_command(CMD_REINIT)
        finally:
            self.ser.timeout = old_timeout
        if status != STATUS_OK:
            raise RuntimeError(f"REINIT failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")

    def set_clk_speed(self, preset: int) -> None:
        """Set eMMC clock speed by preset index (0-6)."""
        if preset < 0 or preset > 6:
            raise ValueError(f"Invalid preset {preset}, must be 0-6")
        payload = struct.pack('B', preset)
        _, status, _ = self._send_command(CMD_SET_CLK_DIV, payload)
        if status != STATUS_OK:
            raise RuntimeError(f"SET_CLK_DIV failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")
        self._current_emmc_freq = EMMC_CLK_FREQ.get(preset, EMMC_CLK_FREQ[0])

    def set_baud(self, preset: int) -> None:
        """Switch UART baud rate. FPGA switches after response is fully transmitted.
        In FIFO mode, this is a no-op (baud rate is irrelevant for parallel FIFO).

        Args:
            preset: 0=3M, 1=6M, 3=12M (preset 2 rejected by FPGA — 9M broken with FT2232HL)
        """
        if self._use_fifo:
            return  # FIFO mode: baud rate is irrelevant
        if preset not in BAUD_PRESETS:
            raise ValueError(f"Invalid baud preset {preset}, valid: {list(BAUD_PRESETS.keys())}")

        new_baud, name = BAUD_PRESETS[preset]
        payload = struct.pack('B', preset)
        _, status, _ = self._send_command(CMD_SET_BAUD, payload)
        if status != STATUS_OK:
            raise RuntimeError(f"SET_BAUD failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")

        # FPGA switches baud after fully transmitting the response.
        # Wait for FTDI chip to drain its TX buffer and FPGA to apply new rate.
        time.sleep(0.02)

        # Reopen serial at new baud
        port_name = self.ser.port
        timeout_val = self.ser.timeout
        self.ser.close()
        time.sleep(0.05)

        # FT2232C warm-up for ttyUSB ports (same logic as __init__)
        if "ttyUSB" in port_name:
            try:
                warmup = serial.Serial(port_name, new_baud, timeout=0.1)
                warmup.close()
                time.sleep(0.05)
            except serial.SerialException:
                pass

        self.ser = serial.Serial(port_name, new_baud, timeout=timeout_val)
        self.ser.reset_input_buffer()

        # Verify connection at new baud
        if not self.ping():
            raise RuntimeError(f"Ping failed at {name} — baud switch may have failed")
        self._current_baud = new_baud

    def send_raw_cmd(self, cmd_index: int, argument: int,
                     resp_expected: bool = True, resp_long: bool = False,
                     check_busy: bool = False) -> tuple:
        """Send arbitrary eMMC command.

        Args:
            cmd_index: eMMC CMD index (0-63)
            argument: 32-bit argument
            resp_expected: expect response (R1 or R2)
            resp_long: expect R2 (128-bit) response
            check_busy: poll DAT0 busy after response

        Returns: (status, response_data_bytes)
        """
        flags = (int(resp_expected)) | (int(resp_long) << 1) | (int(check_busy) << 2)
        payload = bytes([cmd_index & 0x3F]) + struct.pack('>I', argument) + bytes([flags])
        _, status, data = self._send_command(CMD_SEND_RAW, payload)
        return status, data

    def set_rpmb_mode(self, enable: bool):
        """Enable/disable RPMB mode (force CMD25/CMD18 for count=1)."""
        payload = bytes([1 if enable else 0])
        _, status, _ = self._send_command(CMD_SET_RPMB_MODE, payload)
        if status != STATUS_OK:
            raise RuntimeError(
                f"SET_RPMB_MODE failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")

    def set_bus_width(self, width: int):
        """Set eMMC bus width (1 or 4). Sends CMD6 SWITCH to ExtCSD[183]."""
        if width not in (1, 4):
            raise ValueError(f"Bus width must be 1 or 4, got {width}")
        payload = bytes([1 if width == 4 else 0])
        _, status, _ = self._send_command(CMD_SET_BUS_WIDTH, payload)
        if status != STATUS_OK:
            raise RuntimeError(
                f"SET_BUS_WIDTH failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")
        print(f"Bus width set to {width}-bit")

    def rpmb_read_counter(self):
        """Read RPMB Write Counter. Returns (response_dict, is_mac_valid).

        FPGA handles CMD23 internally (MC_RPMB_CMD23 state) when
        force_multi_block is set, so we only need WRITE_SECTOR + READ_SECTOR.
        """
        nonce = os.urandom(16)
        req_frame = build_rpmb_frame(req_type=0x0002, nonce=nonce)

        self.set_rpmb_mode(True)
        try:
            self.set_partition(3)
            try:
                # FPGA sends CMD23(0x80000001) + CMD25 internally
                self.write_sectors(0, req_frame)

                # FPGA sends CMD23(0x00000001) + CMD18 internally
                resp_data = self.read_sectors(0, 1)

            finally:
                self.set_partition(0)
        finally:
            self.set_rpmb_mode(False)

        resp = parse_rpmb_frame(resp_data)
        mac_valid = rpmb_verify_mac(resp_data)
        return resp, mac_valid

    def rpmb_read_data(self, address, count=1):
        """Authenticated RPMB read at given half-sector address.

        FPGA handles CMD23 internally (MC_RPMB_CMD23 state).
        Returns: (parsed_response_dict, is_mac_valid, raw_response_bytes)
        """
        nonce = os.urandom(16)
        req_frame = build_rpmb_frame(
            req_type=0x0004, address=address, block_count=count, nonce=nonce)

        self.set_rpmb_mode(True)
        try:
            self.set_partition(3)
            try:
                # FPGA sends CMD23(0x80000001) + CMD25 internally
                self.write_sectors(0, req_frame)

                # FPGA sends CMD23(0x00000001) + CMD18 internally
                resp_data = self.read_sectors(0, 1)
            finally:
                self.set_partition(0)
        finally:
            self.set_rpmb_mode(False)

        resp = parse_rpmb_frame(resp_data)
        mac_valid = rpmb_verify_mac(resp_data)
        return resp, mac_valid, resp_data


MOUNT_INFO_PATH = "/tmp/emmc_mount_info.json"

# Well-known GPT partition type GUIDs
GPT_TYPE_NAMES = {
    "c12a7328-f81f-11d2-ba4b-00a0c93ec93b": "EFI System",
    "0fc63daf-8483-4772-8e79-3d69d8477de4": "Linux",
    "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7": "FAT/NTFS",
    "e3c9e316-0b5c-4db8-817d-f92df00215ae": "MS Reserved",
    "de94bba4-06d1-4d40-a16a-bfd50179d6ac": "Windows Recovery",
    "024dee41-33e7-11d3-9d69-0008c781f39f": "MBR Partition",
}

# MBR partition type IDs
MBR_TYPE_NAMES = {
    0x00: "Empty",
    0x01: "FAT12",
    0x04: "FAT16 <32M",
    0x05: "Extended",
    0x06: "FAT16",
    0x07: "NTFS/exFAT",
    0x0B: "FAT32",
    0x0C: "FAT32 LBA",
    0x0E: "FAT16 LBA",
    0x0F: "Extended LBA",
    0x82: "Linux swap",
    0x83: "Linux",
    0xEE: "GPT Protective",
}


def read_mbr(tool: EmmcTool) -> bytes:
    """Read sector 0 (MBR)."""
    return tool.read_sectors(0, 1)


def parse_mbr(mbr: bytes) -> list:
    """Parse MBR partition entries. Returns list of dicts."""
    if len(mbr) < 512 or mbr[510] != 0x55 or mbr[511] != 0xAA:
        raise RuntimeError("Invalid MBR signature")

    partitions = []
    for i in range(4):
        offset = 446 + i * 16
        entry = mbr[offset:offset + 16]
        part_type = entry[4]
        if part_type == 0x00:
            continue
        start_lba = struct.unpack_from("<I", entry, 8)[0]
        size_sectors = struct.unpack_from("<I", entry, 12)[0]
        partitions.append({
            "num": i + 1,
            "type_id": part_type,
            "type_name": MBR_TYPE_NAMES.get(part_type, f"0x{part_type:02X}"),
            "start_lba": start_lba,
            "size_sectors": size_sectors,
            "name": "",
        })
    return partitions


def parse_gpt_entries(data: bytes) -> list:
    """Parse GPT partition entries (128 bytes each)."""
    partitions = []
    num = 0
    for i in range(len(data) // 128):
        entry = data[i * 128:(i + 1) * 128]
        type_guid_raw = entry[0:16]
        # Check if entry is empty (all zeros)
        if type_guid_raw == b'\x00' * 16:
            continue
        num += 1
        # Parse mixed-endian GUID
        type_guid = _parse_guid(type_guid_raw)
        start_lba = struct.unpack_from("<Q", entry, 32)[0]
        end_lba = struct.unpack_from("<Q", entry, 40)[0]
        # Name is UTF-16LE at offset 56, 72 bytes (36 chars)
        name = entry[56:128].decode("utf-16-le", errors="replace").rstrip('\x00')
        partitions.append({
            "num": num,
            "type_guid": type_guid,
            "type_name": GPT_TYPE_NAMES.get(type_guid, type_guid),
            "start_lba": start_lba,
            "end_lba": end_lba,
            "size_sectors": end_lba - start_lba + 1,
            "name": name,
        })
    return partitions


def _parse_guid(raw: bytes) -> str:
    """Parse mixed-endian GUID from 16 raw bytes to string."""
    # First 3 components are little-endian, last 2 are big-endian
    p1 = struct.unpack_from("<IHH", raw, 0)
    p2 = raw[8:16]
    return f"{p1[0]:08x}-{p1[1]:04x}-{p1[2]:04x}-{p2[0]:02x}{p2[1]:02x}-{p2[2]:02x}{p2[3]:02x}{p2[4]:02x}{p2[5]:02x}{p2[6]:02x}{p2[7]:02x}"


def read_gpt(tool: EmmcTool) -> list:
    """Read GPT header + partition entries."""
    # LBA 1 = GPT header
    header = tool.read_sectors(1, 1)
    if header[0:8] != b"EFI PART":
        raise RuntimeError("Invalid GPT header signature")

    entries_start_lba = struct.unpack_from("<Q", header, 72)[0]
    num_entries = struct.unpack_from("<I", header, 80)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]

    # Read partition entry sectors (typically LBA 2..33)
    entries_bytes = num_entries * entry_size
    entries_sectors = (entries_bytes + SECTOR_SIZE - 1) // SECTOR_SIZE
    data = tool.read_sectors(entries_start_lba, entries_sectors)

    return parse_gpt_entries(data[:entries_bytes])


def get_partitions(tool: EmmcTool) -> tuple:
    """Auto-detect MBR/GPT and return (scheme, partitions_list)."""
    mbr = read_mbr(tool)
    entries = parse_mbr(mbr)

    # Check for protective GPT
    is_gpt = any(e["type_id"] == 0xEE for e in entries)
    if is_gpt:
        return "GPT", read_gpt(tool)
    else:
        return "MBR", entries


def format_size(sectors: int) -> str:
    """Format sector count as human-readable size."""
    size_bytes = sectors * SECTOR_SIZE
    if size_bytes >= 1024 ** 3:
        return f"{size_bytes / 1024 ** 3:.1f} GB"
    elif size_bytes >= 1024 ** 2:
        return f"{size_bytes / 1024 ** 2:.0f} MB"
    elif size_bytes >= 1024:
        return f"{size_bytes / 1024:.0f} KB"
    return f"{size_bytes} B"


def _load_mount_info() -> dict:
    """Load mount info from JSON file."""
    if os.path.exists(MOUNT_INFO_PATH):
        with open(MOUNT_INFO_PATH, "r") as f:
            return json.load(f)
    return {}


def _save_mount_info(info: dict):
    """Save mount info to JSON file."""
    with open(MOUNT_INFO_PATH, "w") as f:
        json.dump(info, f, indent=2)


def cmd_partitions(tool: EmmcTool, args):
    scheme, partitions = get_partitions(tool)
    if not partitions:
        print("No partitions found.")
        return

    print(f"=== Partition Table ({scheme}) ===")
    print(f" {'#':>2}  {'Name':<20} {'Type':<16} {'Start LBA':>10}   {'Size':>8}")
    for p in partitions:
        name = p.get("name") or ""
        print(f" {p['num']:>2}  {name:<20} {p['type_name']:<16} {p['start_lba']:>10}   {format_size(p['size_sectors']):>8}")


def cmd_mount(tool: EmmcTool, args):
    part_num = args.partition
    mountpoint = args.mountpoint

    if not os.path.isdir(mountpoint):
        print(f"Error: mountpoint '{mountpoint}' does not exist or is not a directory")
        sys.exit(1)

    scheme, partitions = get_partitions(tool)
    part = None
    for p in partitions:
        if p["num"] == part_num:
            part = p
            break
    if part is None:
        print(f"Error: partition {part_num} not found")
        print(f"Available partitions: {[p['num'] for p in partitions]}")
        sys.exit(1)

    start_lba = part["start_lba"]
    size_sectors = part["size_sectors"]
    name = part.get("name") or f"part{part_num}"
    img_path = f"/tmp/emmc_part{part_num}.img"

    print(f"Reading partition {part_num} ({name}, {size_sectors} sectors, {format_size(size_sectors)})...")

    CHUNK = tool._safe_read_chunk()
    total_read = 0
    start_time = time.time()

    with open(img_path, "wb") as f:
        current_lba = start_lba
        remaining = size_sectors
        while remaining > 0:
            n = min(remaining, CHUNK)
            data = tool.read_sectors(current_lba, n)
            f.write(data)
            total_read += n
            remaining -= n
            current_lba += n

            pct = total_read * 100 // size_sectors
            bar = '#' * (pct // 2) + '-' * (50 - pct // 2)
            print(f"\r[{bar}] {pct}% ({total_read}/{size_sectors})", end="", flush=True)

    elapsed = time.time() - start_time
    speed = (total_read * SECTOR_SIZE) / elapsed if elapsed > 0 else 0
    print(f"\nDump complete: {format_size(size_sectors)} in {elapsed:.0f}s ({speed / 1024:.0f} KB/s)")

    # Setup loop device
    result = subprocess.run(
        ["losetup", "-f", "--show", img_path],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"Error: losetup failed: {result.stderr.strip()}")
        sys.exit(1)
    loop_dev = result.stdout.strip()

    # Mount
    result = subprocess.run(
        ["mount", loop_dev, mountpoint],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        # Cleanup loop on failure
        subprocess.run(["losetup", "-d", loop_dev], capture_output=True)
        print(f"Error: mount failed: {result.stderr.strip()}")
        sys.exit(1)

    # Save mount info
    info = _load_mount_info()
    info[mountpoint] = {"loop_dev": loop_dev, "img_path": img_path}
    _save_mount_info(info)

    print(f"Mounted at {mountpoint} (loop device: {loop_dev})")
    print(f"Image: {img_path}")


def cmd_umount(tool: EmmcTool, args):
    mountpoint = args.mountpoint

    info = _load_mount_info()
    if mountpoint not in info:
        print(f"Error: no mount info for '{mountpoint}'")
        print("Trying umount anyway...")
        subprocess.run(["umount", mountpoint])
        return

    entry = info[mountpoint]
    loop_dev = entry["loop_dev"]
    img_path = entry["img_path"]

    # Unmount
    result = subprocess.run(["umount", mountpoint], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error: umount failed: {result.stderr.strip()}")
        sys.exit(1)
    print(f"Unmounted {mountpoint}")

    # Detach loop device
    result = subprocess.run(["losetup", "-d", loop_dev], capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Warning: losetup -d failed: {result.stderr.strip()}")
    else:
        print(f"Detached {loop_dev}")

    # Remove image file
    if os.path.exists(img_path):
        os.remove(img_path)
        print(f"Removed {img_path}")

    # Update mount info
    del info[mountpoint]
    _save_mount_info(info)


def cmd_hexdump(tool: EmmcTool, args):
    lba = int(args.lba, 0)
    count = int(args.count, 0) if args.count else 1
    data = tool.read_sectors(lba, count)
    for i in range(count):
        print(f"LBA {lba + i}:")
        sector = data[i * SECTOR_SIZE:(i + 1) * SECTOR_SIZE]
        for off in range(0, len(sector), 16):
            chunk = sector[off:off + 16]
            hex_part = ' '.join(f'{b:02x}' for b in chunk)
            ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
            print(f"{off:08x}  {hex_part:<48s}  |{ascii_part}|")
        print()


def cmd_verify(tool: EmmcTool, args):
    fast_mode = getattr(args, 'fast', False)
    old_preset = None

    if fast_mode:
        print("Fast mode: switching to 10 MHz eMMC + 12 Mbaud UART...")
        old_preset = 0
        tool.set_clk_speed(3)  # preset 3 = 10 MHz (on reliable 3M UART)
        tool.set_baud(3)  # preset 3 = 12M (switch UART last)
        print("eMMC 10 MHz, UART 12 Mbaud.")

    lba = int(args.lba, 0)

    file_size = os.path.getsize(args.infile)
    count = (file_size + SECTOR_SIZE - 1) // SECTOR_SIZE

    # Limit sectors if --count specified
    if getattr(args, 'count', None) is not None:
        max_sectors = int(args.count, 0)
        if max_sectors < count:
            print(f"  Limiting verify to {max_sectors} sectors ({max_sectors * 512 / (1024**3):.2f} GB) of {count} in file")
            count = max_sectors

    print(f"Verifying {count} sectors from LBA {lba}...")

    # Auto-enable multi-sector (CMD18) for verify — same bulk read pattern as dump
    saved_multi = tool._use_multi_sector
    tool._use_multi_sector = True

    CHUNK = tool._safe_read_chunk()
    mismatches = 0
    total_read = 0
    current_lba = lba
    remaining = count

    with open(args.infile, "rb") as f:
        while remaining > 0:
            n = min(remaining, CHUNK)
            file_chunk = f.read(n * SECTOR_SIZE)
            # Pad last chunk to sector boundary
            if len(file_chunk) < n * SECTOR_SIZE:
                file_chunk += b'\x00' * (n * SECTOR_SIZE - len(file_chunk))

            emmc_data = tool.read_sectors(current_lba, n)

            for j in range(n):
                s_off = j * SECTOR_SIZE
                if emmc_data[s_off:s_off + SECTOR_SIZE] != file_chunk[s_off:s_off + SECTOR_SIZE]:
                    print(f"  MISMATCH at LBA {current_lba + j}")
                    mismatches += 1

            total_read += n
            remaining -= n
            current_lba += n

            pct = total_read * 100 // count
            bar = '#' * (pct // 2) + '-' * (50 - pct // 2)
            print(f"\r[{bar}] {pct}%", end="", flush=True)

    tool._use_multi_sector = saved_multi  # restore original setting

    print()
    if mismatches == 0:
        print("OK: all sectors match")
    else:
        print(f"FAIL: {mismatches} sector(s) differ")
        if fast_mode and old_preset is not None:
            tool.set_baud(old_preset)
            tool.set_clk_speed(0)
        sys.exit(1)

    if fast_mode and old_preset is not None:
        print("Restoring default speeds...")
        tool.set_baud(old_preset)  # 3 Mbaud UART (switch UART first)
        tool.set_clk_speed(0)  # 2 MHz eMMC (on reliable 3M UART)
        print("Restored: UART 3 Mbaud, eMMC 2 MHz.")


def cmd_ping(tool: EmmcTool, args):
    if tool.ping():
        print("PONG - Connection OK")
    else:
        print("PING failed!")
        sys.exit(1)


def _is_dead_emmc(info: dict) -> bool:
    """Detect known dead eMMC signature: MID=0x65, Product='M MOR'.

    When eMMC NAND fails (water damage, ESD, wear), the controller cannot read
    the real CID from OTP/NAND and falls back to this hardcoded CID.
    Well-documented on repair forums (UFI Box, Easy JTAG). Not recoverable.
    """
    return info['manufacturer_id'] == 0x65 and info['product_name'].strip().startswith('M MOR')


def cmd_info(tool: EmmcTool, args):
    info = tool.get_info()
    print("=== eMMC Card Info ===")
    print(f"CID: {info['cid_raw']}")
    print(f"CSD: {info['csd_raw']}")
    print(f"Manufacturer: 0x{info['manufacturer_id']:02X}")
    print(f"Product: {info['product_name']}")
    print(f"Revision: {info['product_rev']}")
    print(f"Serial: 0x{info['serial_number']:08X}")
    print(f"Date: {info['mfg_date']}")
    print(f"CSD version: {info['csd_structure']}")

    # Dead eMMC detection
    if _is_dead_emmc(info):
        print()
        print("  *** DEAD eMMC DETECTED ***")
        print("  MID=0x65 + Product='M MOR' is a known dead eMMC fallback CID.")
        print("  The NAND controller cannot read real CID from OTP/NAND.")
        print("  Common causes: water damage, ESD, NAND wear-out.")
        print("  Capacity, manufacturer, and all metadata are INVALID.")
        print("  This chip is NOT recoverable — hardware replacement required.")
        return

    if "capacity_bytes" in info:
        cap = info["capacity_bytes"]
        if cap >= 1024 ** 3:
            print(f"Capacity: {cap / 1024 ** 3:.1f} GB (from CSD)")
        elif cap >= 1024 ** 2:
            print(f"Capacity: {cap / 1024 ** 2:.0f} MB (from CSD)")
        else:
            print(f"Capacity: {cap} bytes (from CSD)")
        if cap < 2 * 1024 ** 3:
            print("  WARNING: CSD capacity < 2 GB — may be unreliable (noise on CMD line)")
            print("  Use 'ext-csd' command for accurate capacity from SEC_COUNT")
    elif "capacity_note" in info:
        print(f"Capacity: {info['capacity_note']}")


def cmd_read(tool: EmmcTool, args):
    lba = int(args.lba, 0)
    count = int(args.count, 0)
    outfile = args.outfile
    fast_mode = getattr(args, 'fast', False)
    old_preset = None

    if fast_mode:
        print("Fast mode: switching to 10 MHz eMMC + 12 Mbaud UART...")
        old_preset = 0
        tool.set_clk_speed(3)  # preset 3 = 10 MHz
        tool.set_baud(3)       # preset 3 = 12M
        print("eMMC 10 MHz, UART 12 Mbaud.")

    total_bytes = count * SECTOR_SIZE
    print(f"Reading {count} sector(s) from LBA {lba} ({total_bytes / (1024**3):.2f} GB)...")

    # Auto-enable multi-sector (CMD18) for large reads
    saved_multi = tool._use_multi_sector
    if count > 1:
        tool._use_multi_sector = True

    CHUNK = tool._safe_read_chunk()  # sectors per request
    total_read = 0
    errors = 0
    start_time = time.time()

    # Setup progress bar
    if HAS_TQDM:
        pbar = tqdm(total=total_bytes, unit='B', unit_scale=True, desc="Reading")
    else:
        pbar = None

    with open(outfile, "wb") as f:
        current_lba = lba
        remaining = count
        while remaining > 0:
            n = min(remaining, CHUNK)
            try:
                data = tool.read_sectors(current_lba, n)
                f.write(data)
            except Exception as e:
                errors += 1
                msg = f"Error at LBA {current_lba}: {e}"
                if pbar:
                    pbar.write(msg)
                else:
                    print(f"\n{msg}")
                # Write zeros for failed sectors and continue
                f.write(b'\x00' * n * SECTOR_SIZE)

            bytes_read = n * SECTOR_SIZE
            total_read += n
            remaining -= n
            current_lba += n

            if pbar:
                pbar.update(bytes_read)
            else:
                elapsed = time.time() - start_time
                speed = (total_read * SECTOR_SIZE) / elapsed if elapsed > 0 else 0
                pct = total_read * 100 / count
                print(f"\r{pct:.1f}% LBA:{current_lba} Speed:{speed/1024:.0f} KB/s", end="", flush=True)

    if pbar:
        pbar.close()

    tool._use_multi_sector = saved_multi

    elapsed = time.time() - start_time
    speed_avg = (total_read * SECTOR_SIZE) / elapsed / 1024 if elapsed > 0 else 0
    print(f"Done. {total_read * SECTOR_SIZE / (1024**3):.2f} GB in {elapsed:.0f}s ({speed_avg:.0f} KB/s) to {outfile}")
    if errors > 0:
        print(f"WARNING: {errors} read errors (sectors filled with zeros)")

    if fast_mode and old_preset is not None:
        print("Restoring default speeds...")
        tool.set_baud(old_preset)
        tool.set_clk_speed(0)
        print("Restored: UART 3 Mbaud, eMMC 2 MHz.")


def _verify_readback(tool, lba, reference_data, label="Verify"):
    """Readback verify: read eMMC and compare with reference bytes. Returns list of mismatched LBAs."""
    saved_multi = tool._use_multi_sector
    saved_retries = tool.max_retries
    tool._use_multi_sector = True
    tool.max_retries = 3

    CHUNK = tool._safe_read_chunk()  # 64
    count = len(reference_data) // SECTOR_SIZE
    mismatches = []
    current_lba = lba
    total_done = 0

    while total_done < count:
        n = min(count - total_done, CHUNK)
        emmc_data = tool.read_sectors(current_lba, n)
        ref_chunk = reference_data[total_done * SECTOR_SIZE:(total_done + n) * SECTOR_SIZE]
        for j in range(n):
            off = j * SECTOR_SIZE
            if emmc_data[off:off + SECTOR_SIZE] != ref_chunk[off:off + SECTOR_SIZE]:
                mismatches.append(current_lba + j)
        total_done += n
        current_lba += n
        pct = total_done * 100 // count
        print(f"\r  {label}: {pct}%", end="", flush=True)

    print()
    tool._use_multi_sector = saved_multi
    tool.max_retries = saved_retries
    return mismatches


def _verify_readback_file(tool, lba, filepath, total_sectors, label="Verify"):
    """Readback verify against file — reads file in chunks, never loads full file into memory.
    Returns list of mismatched LBAs."""
    saved_multi = tool._use_multi_sector
    saved_retries = tool.max_retries
    tool._use_multi_sector = True
    tool.max_retries = 3

    CHUNK = tool._safe_read_chunk()  # 64
    mismatches = []
    current_lba = lba
    total_done = 0

    with open(filepath, 'rb') as f:
        if lba > 0:
            f.seek(lba * SECTOR_SIZE)
        while total_done < total_sectors:
            n = min(total_sectors - total_done, CHUNK)
            file_chunk = f.read(n * SECTOR_SIZE)
            if not file_chunk:
                break
            # Pad last chunk to sector boundary
            if len(file_chunk) < n * SECTOR_SIZE:
                file_chunk += b'\x00' * (n * SECTOR_SIZE - len(file_chunk))

            emmc_data = tool.read_sectors(current_lba, n)
            for j in range(n):
                off = j * SECTOR_SIZE
                if emmc_data[off:off + SECTOR_SIZE] != file_chunk[off:off + SECTOR_SIZE]:
                    mismatches.append(current_lba + j)
            total_done += n
            current_lba += n
            pct = total_done * 100 // total_sectors
            print(f"\r  {label}: {pct}%", end="", flush=True)

    print()
    tool._use_multi_sector = saved_multi
    tool.max_retries = saved_retries
    return mismatches


def cmd_write(tool: EmmcTool, args):
    lba = int(args.lba, 0)
    infile = args.infile
    fast_mode = getattr(args, 'fast', False)
    old_preset = None

    if fast_mode:
        print("Fast mode: switching to 10 MHz eMMC + 12 Mbaud UART...")
        old_preset = 0  # remember to switch back to 3M
        tool.set_clk_speed(3)  # preset 3 = 10 MHz (on reliable 3M UART)
        tool.set_baud(3)       # preset 3 = 12M (switch UART last)
        print("eMMC 10 MHz, UART 12 Mbaud.")

    with open(infile, "rb") as f:
        data = f.read()

    count = (len(data) + SECTOR_SIZE - 1) // SECTOR_SIZE
    print(f"Writing {count} sector(s) to LBA {lba}...")

    # Auto-enable multi-sector writes for bulk operations
    saved_multi = tool._use_multi_sector
    if count > 1:
        tool._use_multi_sector = True

    CHUNK = 16  # sectors per CMD25 packet (16-bank FIFO hw limit)
    total_written = 0

    offset = 0
    remaining = count
    current_lba = lba
    while remaining > 0:
        n = min(remaining, CHUNK)
        chunk_data = data[offset:offset + n * SECTOR_SIZE]
        tool.write_sectors(current_lba, chunk_data)
        total_written += n
        remaining -= n
        current_lba += n
        offset += n * SECTOR_SIZE

        pct = total_written * 100 // count
        bar = '#' * (pct // 2) + '-' * (50 - pct // 2)
        print(f"\r[{bar}] {pct}% ({total_written}/{count})", end="", flush=True)

    tool._use_multi_sector = saved_multi
    print(f"\nDone. Wrote {total_written * SECTOR_SIZE} bytes from {infile}")

    if getattr(args, 'verify', False):
        print("Verifying readback...")
        mismatches = _verify_readback(tool, lba, data)
        if mismatches:
            print(f"VERIFY FAILED: {len(mismatches)} mismatched sector(s): {mismatches}")
        else:
            print(f"Verify OK: all {count} sector(s) match.")

    if fast_mode and old_preset is not None:
        print("Restoring default speeds...")
        tool.set_baud(old_preset)
        tool.set_clk_speed(0)
        print("Restored: UART 3 Mbaud, eMMC 2 MHz.")


def cmd_dump(tool: EmmcTool, args):
    outfile = args.outfile
    fast_mode = getattr(args, 'fast', False)
    old_preset = None

    if fast_mode:
        print("Fast mode: switching to 10 MHz eMMC + 12 Mbaud UART...")
        old_preset = 0  # remember to switch back to 3M
        tool.set_clk_speed(3)  # preset 3 = 10 MHz (on reliable 3M UART)
        tool.set_baud(3)  # preset 3 = 12M (switch UART last)
        print("eMMC 10 MHz, UART 12 Mbaud.")

    # Get card info to determine capacity
    info = tool.get_info()
    print(f"Card: {info['product_name']}, Serial: 0x{info['serial_number']:08X}")

    # Determine capacity: prefer ExtCSD SEC_COUNT over CSD (CSD unreliable on breadboard)
    csd_cap = info.get("capacity_bytes", 0)
    if csd_cap >= 2 * 1024 ** 3:
        total_sectors = csd_cap // SECTOR_SIZE
    else:
        # CSD unreliable (noise on CMD line) — get real capacity from ExtCSD
        try:
            ext_csd = tool.get_ext_csd()
            ext_info = tool.parse_ext_csd(ext_csd)
            total_sectors = ext_info["sec_count"]
            print(f"Note: CSD capacity unreliable ({csd_cap} bytes), using ExtCSD SEC_COUNT")
        except Exception as e:
            total_sectors = 16_777_216  # 8GB fallback
            print(f"Warning: CSD and ExtCSD both failed ({e}), assuming 8 GB")
    
    total_bytes = total_sectors * SECTOR_SIZE
    print(f"Dumping {total_sectors} sectors ({total_bytes / (1024**3):.1f} GB)...")

    # Auto-enable multi-sector (CMD18) for dump — much faster than per-sector CMD17
    saved_multi = tool._use_multi_sector
    tool._use_multi_sector = True

    CHUNK = tool._safe_read_chunk()
    total_read = 0
    start_time = time.time()
    errors = 0

    # Setup progress bar
    if HAS_TQDM:
        pbar = tqdm(total=total_bytes, unit='B', unit_scale=True, desc="Dumping")
    else:
        pbar = None

    with open(outfile, "wb") as f:
        current_lba = 0
        remaining = total_sectors
        while remaining > 0:
            n = min(remaining, CHUNK)
            try:
                data = tool.read_sectors(current_lba, n)
                f.write(data)
            except Exception as e:
                errors += 1
                if pbar:
                    pbar.write(f"Error at LBA {current_lba}: {e}")
                else:
                    print(f"\nError at LBA {current_lba}: {e}")
                # Write zeros for failed sectors and continue
                f.write(b'\x00' * n * SECTOR_SIZE)

            bytes_read = n * SECTOR_SIZE
            total_read += n
            remaining -= n
            current_lba += n

            if pbar:
                pbar.update(bytes_read)
            else:
                elapsed = time.time() - start_time
                speed = (total_read * SECTOR_SIZE) / elapsed if elapsed > 0 else 0
                pct = total_read * 100 / total_sectors
                print(f"\r{pct:.1f}% LBA:{current_lba} Speed:{speed/1024:.0f} KB/s", end="", flush=True)

    if pbar:
        pbar.close()

    elapsed = time.time() - start_time
    speed_avg = (total_read * SECTOR_SIZE) / elapsed / 1024 if elapsed > 0 else 0
    print(f"Done. {total_read * SECTOR_SIZE / (1024**3):.2f} GB in {elapsed:.0f}s ({speed_avg:.0f} KB/s)")
    if errors > 0:
        print(f"WARNING: {errors} read errors (sectors filled with zeros)")

    tool._use_multi_sector = saved_multi  # restore original setting

    if errors == 0 and getattr(args, 'verify', False):
        print("Verifying readback against dump file...")
        mismatches = _verify_readback_file(tool, 0, outfile, total_sectors)
        if mismatches:
            print(f"WARNING: {len(mismatches)} sector(s) differ from dump (may be eMMC noise): {mismatches[:10]}")
        else:
            print(f"Verify OK: all {total_sectors} sector(s) match.")

    if fast_mode and old_preset is not None:
        print("Restoring default speeds...")
        tool.set_baud(old_preset)  # 3 Mbaud UART (switch UART first)
        tool.set_clk_speed(0)  # 2 MHz eMMC (on reliable 3M UART)
        print("Restored: UART 3 Mbaud, eMMC 2 MHz.")


def cmd_restore(tool: EmmcTool, args):
    """Restore eMMC from a dump file."""
    fast_mode = getattr(args, 'fast', False)
    old_preset = None

    if fast_mode:
        print("Fast mode: switching to 10 MHz eMMC + 12 Mbaud UART...")
        old_preset = 0  # remember to switch back to 3M
        tool.set_clk_speed(3)  # preset 3 = 10 MHz (on reliable 3M UART)
        tool.set_baud(3)  # preset 3 = 12M (switch UART last)
        print("eMMC 10 MHz, UART 12 Mbaud.")

    infile = args.infile
    start_lba = int(args.lba, 0) if isinstance(args.lba, str) else args.lba

    file_size = os.path.getsize(infile)
    if file_size == 0:
        print("Error: input file is empty")
        sys.exit(1)

    total_sectors = (file_size + 511) // 512
    CHUNK = 16  # sectors per CMD25 packet (FPGA 16-bank FIFO hw limit)
    SECTOR_SIZE = 512

    # Limit sectors if --count specified (count = end LBA, sectors to write = count - start_lba)
    if getattr(args, 'count', None) is not None:
        max_sectors = int(args.count, 0)
        if max_sectors < total_sectors:
            total_sectors = max_sectors
    # Adjust for start_lba: we write from start_lba to total_sectors
    sectors_to_write = total_sectors - start_lba
    if sectors_to_write <= 0:
        print(f"Error: start LBA {start_lba} >= total sectors {total_sectors}")
        sys.exit(1)
    print(f"  Writing {sectors_to_write} sectors ({sectors_to_write * 512 / (1024**3):.2f} GB) from LBA {start_lba} to LBA {total_sectors - 1}")

    # Auto-enable multi-sector writes for restore (CMD25)
    saved_multi = tool._use_multi_sector
    tool._use_multi_sector = True

    # Enable write cache for faster programming (flash writes become async)
    cache_enabled = False
    try:
        cache_enabled = tool.enable_cache()
        if cache_enabled:
            print("  Write cache: enabled (async flash programming)")
    except Exception:
        pass  # card may not support cache — continue without it

    print(f"Restoring {infile} to LBA {start_lba}...")
    print(f"  Multi-sector write: enabled (CMD25, {CHUNK} sectors/packet)")

    pbar = None
    total_bytes = sectors_to_write * SECTOR_SIZE
    if HAS_TQDM:
        pbar = tqdm.tqdm(total=total_bytes, unit='B', unit_scale=True, desc="Restore")

    start_time = time.time()
    total_written = 0
    errors = 0
    current_lba = start_lba

    def _read_chunk(f, n):
        """Read n sectors from file, pad if needed."""
        data = f.read(n * SECTOR_SIZE)
        if not data:
            return None
        if len(data) < n * SECTOR_SIZE:
            pad_bytes = n * SECTOR_SIZE - len(data)
            msg = f"WARNING: last chunk padded with {pad_bytes} zero bytes"
            if pbar:
                pbar.write(msg)
            else:
                print(f"\n{msg}")
            data += b'\x00' * pad_bytes
        return data

    def _send_write_batch(tool, lba, data):
        """Build and send multi-write packet without waiting for response."""
        count = len(data) // SECTOR_SIZE
        tool._validate_lba_range(lba, count)
        payload = struct.pack(">IH", lba, count) + data
        tool._send_command_no_recv(CMD_WRITE_SECTOR, payload)

    def _recv_write_response(tool, lba):
        """Receive response for a previously sent write batch."""
        _, status, _ = tool._recv_response()
        if status != STATUS_OK:
            raise RuntimeError(f"Multi-write error at LBA {lba}: "
                               f"{STATUS_NAMES.get(status, f'0x{status:02X}')}")

    with open(infile, 'rb') as f:
        if start_lba > 0:
            f.seek(start_lba * SECTOR_SIZE)
        remaining = sectors_to_write
        pending_lba = None  # LBA of batch awaiting response
        pending_n = 0

        while remaining > 0:
            n = min(remaining, CHUNK)
            data = _read_chunk(f, n)
            if not data:
                break

            # If previous batch pending, receive its response before sending next
            # (FPGA 16-bank FIFO can hold only one batch; send next immediately
            #  after recv to overlap serial TX with eMMC flash programming)
            if pending_lba is not None:
                try:
                    _recv_write_response(tool, pending_lba)
                except Exception as e:
                    errors += 1
                    if pbar:
                        pbar.write(f"Error at LBA {pending_lba}: {e}")
                    else:
                        print(f"\nError at LBA {pending_lba}: {e}")

                # Account for completed batch
                total_written += pending_n
                if pbar:
                    pbar.update(pending_n * SECTOR_SIZE)
                else:
                    elapsed = time.time() - start_time
                    speed = (total_written * SECTOR_SIZE) / elapsed if elapsed > 0 else 0
                    pct = total_written * 100 / sectors_to_write
                    print(f"\r{pct:.1f}% LBA:{current_lba} Speed:{speed/1024:.0f} KB/s", end="", flush=True)

            # Send this batch (non-blocking)
            try:
                _send_write_batch(tool, current_lba, data)
                pending_lba = current_lba
                pending_n = n
            except Exception as e:
                errors += 1
                pending_lba = None
                pending_n = 0
                if pbar:
                    pbar.write(f"Send error at LBA {current_lba}: {e}")
                else:
                    print(f"\nSend error at LBA {current_lba}: {e}")

            remaining -= n
            current_lba += n

        # Receive response for the last batch
        if pending_lba is not None:
            try:
                _recv_write_response(tool, pending_lba)
            except Exception as e:
                errors += 1
                if pbar:
                    pbar.write(f"Error at LBA {pending_lba}: {e}")
                else:
                    print(f"\nError at LBA {pending_lba}: {e}")
            total_written += pending_n
            if pbar:
                pbar.update(pending_n * SECTOR_SIZE)

    if pbar:
        pbar.close()

    tool._use_multi_sector = saved_multi  # restore original setting

    # Flush write cache to ensure all data reaches flash
    if cache_enabled:
        try:
            tool.flush_cache()
            print("  Cache flushed to flash.")
        except Exception as e:
            print(f"  WARNING: cache flush failed: {e}")

    elapsed = time.time() - start_time
    speed_avg = (total_written * SECTOR_SIZE) / elapsed / 1024 if elapsed > 0 else 0
    print(f"Done. {total_written * SECTOR_SIZE / (1024**3):.2f} GB in {elapsed:.0f}s ({speed_avg:.0f} KB/s)")
    if errors > 0:
        print(f"WARNING: {errors} write errors")

    if getattr(args, 'verify', False):
        print("Verifying readback against source file...")
        mismatches = _verify_readback_file(tool, start_lba, infile, sectors_to_write)
        if mismatches:
            print(f"VERIFY FAILED: {len(mismatches)} sector(s) differ: {mismatches[:10]}")
        else:
            print(f"Verify OK: all {sectors_to_write} sector(s) match.")

    if fast_mode and old_preset is not None:
        print("Restoring default speeds...")
        tool.set_baud(old_preset)  # 3 Mbaud UART (switch UART first)
        tool.set_clk_speed(0)  # 2 MHz eMMC (on reliable 3M UART)
        print("Restored: UART 3 Mbaud, eMMC 2 MHz.")


def cmd_status(tool: EmmcTool, args):
    _, status, payload = tool._send_command(CMD_GET_STATUS)
    if status != STATUS_OK:
        print(f"GET_STATUS failed: {STATUS_NAMES.get(status, f'0x{status:02X}')}")
        return
    if len(payload) >= 4:
        init_state_names = {
            0: "IDLE", 1: "RST_LOW", 2: "RST_HIGH", 3: "CMD0",
            4: "CMD1", 5: "CMD1_WAIT", 6: "CMD2", 7: "CMD3",
            8: "CMD9", 9: "CMD7", 10: "DELAY", 11: "CMD16",
            12: "DONE", 13: "ERROR", 14: "WAIT_CMD", 15: "PRE_IDLE",
        }
        mc_state_names = {
            0: "IDLE", 1: "INIT", 2: "READY", 3: "READ_CMD",
            4: "READ_DAT", 5: "READ_DONE", 6: "WRITE_CMD",
            7: "WRITE_DAT", 8: "WRITE_DONE", 9: "STOP_CMD",
            10: "ERROR", 11: "STOP_WAIT", 12: "EXT_CSD_CMD",
            13: "EXT_CSD_DAT", 14: "SWITCH_CMD", 15: "SWITCH_WAIT",
            16: "ERASE_START", 17: "ERASE_END", 18: "ERASE_CMD",
            19: "STATUS_CMD",
        }
        b0, b1, b2, b3 = payload[0], payload[1], payload[2], payload[3]
        init_st = (b1 >> 4) & 0x0F
        mc_st = ((b1 & 0x07) << 2) | ((b2 >> 6) & 0x03)
        info_valid = (b2 >> 5) & 1
        cmd_ready = (b2 >> 4) & 1
        cmd_pin = (b3 >> 7) & 1
        dat0_pin = (b3 >> 6) & 1
        init_name = init_state_names.get(init_st, f"?{init_st}")
        mc_name = mc_state_names.get(mc_st, f"?{mc_st}")
        print(f"resp_status=0x{b0:02X}")
        print(f"init={init_st}({init_name}) mc={mc_st}({mc_name}) "
              f"info_valid={info_valid} cmd_ready={cmd_ready} "
              f"CMD={cmd_pin} DAT0={dat0_pin}")

        # Extended 12-byte status (bytes 4-11)
        if len(payload) >= 12:
            cmd_fsm_names = {0: "IDLE", 1: "SEND", 2: "WAIT", 3: "RECV", 4: "DONE"}
            dat_fsm_names = {
                0: "IDLE", 1: "RD_WAIT", 2: "RD_DATA", 3: "RD_CRC",
                4: "RD_END", 5: "WR_PRE", 6: "WR_START", 7: "WR_DATA",
                8: "WR_CRC", 9: "WR_END", 10: "WR_STAT", 11: "WR_BUSY",
                12: "WR_CRC_W", 13: "WR_PRE2",
            }
            b4 = payload[4]
            cmd_fsm = (b4 >> 5) & 0x07
            dat_fsm = (b4 >> 1) & 0x0F
            fast_clk = b4 & 1
            b5 = payload[5]
            partition = (b5 >> 6) & 0x03
            reinit_pending = (b5 >> 5) & 1
            part_names = {0: "user", 1: "boot0", 2: "boot1", 3: "RPMB"}
            cmd_fsm_name = cmd_fsm_names.get(cmd_fsm, f"?{cmd_fsm}")
            dat_fsm_name = dat_fsm_names.get(dat_fsm, f"?{dat_fsm}")
            print(f"cmd_fsm={cmd_fsm}({cmd_fsm_name}) dat_fsm={dat_fsm}({dat_fsm_name}) "
                  f"fast_clk={fast_clk} partition={partition}({part_names.get(partition, '?')}) "
                  f"reinit={reinit_pending}")
            print(f"errors: cmd_timeout={payload[6]} cmd_crc={payload[7]} "
                  f"dat_rd={payload[8]} dat_wr={payload[9]}")
            print(f"init_retries={payload[10]}")
            clk_preset = payload[11] & 0x07
            clk_name = CLK_PRESETS.get(clk_preset, (0, f"?{clk_preset}"))[1]
            print(f"clk_preset={clk_preset} ({clk_name})")
            baud_preset = (payload[11] >> 3) & 0x03
            baud_name = {0: "3 Mbaud", 1: "6 Mbaud", 3: "12 Mbaud"}.get(baud_preset, f"?{baud_preset}")
            print(f"baud_preset={baud_preset} ({baud_name})")
    else:
        print(f"Controller status: 0x{payload[0]:02X}" if payload else "No payload")


def parse_card_status(cs: int):
    """Pretty-print Card Status Register (CMD13 R1 response)."""
    state_names = {
        0: "idle", 1: "ready", 2: "ident", 3: "stby",
        4: "tran", 5: "data", 6: "rcv", 7: "prg",
        8: "dis", 9: "btst", 10: "slp",
    }
    state = (cs >> 9) & 0xF
    print(f"  Card Status Register: 0x{cs:08X}")
    print(f"  CURRENT_STATE:      {state} ({state_names.get(state, 'unknown')})")
    print(f"  READY_FOR_DATA:     {(cs >> 8) & 1}")
    if cs & (1 << 31): print("  ADDRESS_OUT_OF_RANGE")
    if cs & (1 << 30): print("  ADDRESS_MISALIGN")
    if cs & (1 << 29): print("  BLOCK_LEN_ERROR")
    if cs & (1 << 28): print("  ERASE_SEQ_ERROR")
    if cs & (1 << 27): print("  ERASE_PARAM")
    if cs & (1 << 26): print("  WP_VIOLATION")
    if cs & (1 << 25): print("  DEVICE_IS_LOCKED")
    if cs & (1 << 24): print("  LOCK_UNLOCK_FAILED")
    if cs & (1 << 23): print("  COM_CRC_ERROR")
    if cs & (1 << 22): print("  ILLEGAL_COMMAND")
    if cs & (1 << 21): print("  DEVICE_ECC_FAILED")
    if cs & (1 << 20): print("  CC_ERROR")
    if cs & (1 << 19): print("  ERROR")
    if cs & (1 << 16): print("  CSD_OVERWRITE")
    if cs & (1 << 15): print("  WP_ERASE_SKIP")
    if cs & (1 << 7):  print("  SWITCH_ERROR")
    if cs & (1 << 5):  print("  URGENT_BKOPS")


def cmd_card_status(tool: EmmcTool, args):
    """Read and display Card Status Register (CMD13 SEND_STATUS)."""
    cs = tool.get_card_status()
    parse_card_status(cs)


def cmd_reinit(tool: EmmcTool, args):
    """Full re-initialization of eMMC card (CMD0 + init sequence)."""
    print("Re-initializing eMMC card...")
    tool.reinit()
    print("Re-initialization complete.")
    # Re-read card info after reinit
    info = tool.get_info()
    print(f"Card: 0x{info['manufacturer_id']:02X} {info['product_name']}")


def cmd_raw_cmd(tool: EmmcTool, args):
    """Send arbitrary eMMC command."""
    cmd_index = args.index
    argument = int(args.argument, 16) if args.argument.startswith("0x") or args.argument.startswith("0X") \
        else int(args.argument)
    resp_expected = not args.no_resp
    resp_long = args.long
    check_busy = args.busy

    flags_str = []
    if resp_expected:
        flags_str.append("resp_long" if resp_long else "resp_short")
    else:
        flags_str.append("no_resp")
    if check_busy:
        flags_str.append("check_busy")

    print(f"Sending CMD{cmd_index} arg=0x{argument:08X} [{', '.join(flags_str)}]...")
    status, data = tool.send_raw_cmd(cmd_index, argument,
                                     resp_expected=resp_expected,
                                     resp_long=resp_long,
                                     check_busy=check_busy)
    status_name = STATUS_NAMES.get(status, f"0x{status:02X}")
    print(f"Status: {status_name}")

    if data:
        if resp_long:
            print(f"R2 response ({len(data)} bytes): {data.hex().upper()}")
        else:
            if len(data) >= 4:
                card_status = int.from_bytes(data[:4], 'big')
                print(f"R1 response: 0x{card_status:08X}")
            else:
                print(f"Response ({len(data)} bytes): {data.hex().upper()}")
    elif resp_expected and status == STATUS_OK:
        print("(no response data)")


def cmd_recover(tool: EmmcTool, args):
    """Automated eMMC recovery sequence for stuck/mis-identified cards."""
    target_mid = int(args.target_mid, 16) if args.target_mid else None

    def check_mid():
        """Check if MID matches target. Returns True if recovered."""
        try:
            info = tool.get_info()
            mid = info['manufacturer_id']
            name = info['product_name']
            print(f"  Current: MID=0x{mid:02X} name={name}")
            if target_mid and mid == target_mid:
                return True
        except Exception as e:
            print(f"  Info failed: {e}")
        return False

    steps = [
        ("CMD5 SLEEP_AWAKE (sleep + wake cycle)", [
            ("raw", 5, 0x00010001, True, False, True),  # CMD5 SLEEP arg=RCA|1, check_busy
            ("delay", 2.0),
            ("reinit",),
        ]),
        ("CMD62 vendor debug mode (arg=0x96C9D71C)", [
            ("raw", 62, 0x96C9D71C, True, False, False),
            ("delay", 0.5),
            ("reinit",),
        ]),
        ("CMD0 FFU mode (arg=0xFFFFFFFA)", [
            ("raw", 0, 0xFFFFFFFA, False, False, False),
            ("delay", 1.0),
            ("reinit",),
        ]),
        ("CMD0 GO_PRE_IDLE (arg=0xF0F0F0F0)", [
            ("raw", 0, 0xF0F0F0F0, False, False, False),
            ("delay", 2.0),
            ("reinit",),
        ]),
    ]

    print("=== eMMC Recovery Sequence ===")
    if target_mid:
        print(f"Target MID: 0x{target_mid:02X}")
    print()

    # Initial check
    print("Step 0: Initial state")
    if check_mid():
        print("Card already has target MID. No recovery needed.")
        return

    for i, (desc, actions) in enumerate(steps, 1):
        print(f"\nStep {i}: {desc}")
        for action in actions:
            try:
                if action[0] == "raw":
                    _, idx, arg, resp_exp, resp_long, busy = action
                    print(f"  Sending CMD{idx} arg=0x{arg:08X}...")
                    status, data = tool.send_raw_cmd(idx, arg,
                                                     resp_expected=resp_exp,
                                                     resp_long=resp_long,
                                                     check_busy=busy)
                    status_name = STATUS_NAMES.get(status, f"0x{status:02X}")
                    print(f"  Result: {status_name}")
                elif action[0] == "delay":
                    delay = action[1]
                    print(f"  Waiting {delay}s...")
                    time.sleep(delay)
                elif action[0] == "reinit":
                    print("  Re-initializing...")
                    try:
                        tool.reinit()
                        print("  Reinit OK")
                    except Exception as e:
                        print(f"  Reinit failed: {e}")
            except Exception as e:
                print(f"  Action failed: {e}")

        # Check MID after each step
        if check_mid():
            print(f"\n*** SUCCESS: MID recovered to 0x{target_mid:02X}! ***")
            return

    print("\n=== Recovery sequence complete — MID not recovered ===")
    print("Try additional vendor-specific commands or power-cycle the card.")


def cmd_set_clock(tool: EmmcTool, args):
    """Set eMMC clock speed (runtime, no re-synthesis)."""
    speed = args.speed
    # Preset index first (0-6), then MHz values for larger numbers
    mhz_to_preset = {10: 3, 15: 4, 30: 6}
    if 0 <= speed <= 6:
        preset = speed
    elif speed in mhz_to_preset:
        preset = mhz_to_preset[speed]
    else:
        print(f"Invalid speed: {speed}")
        print("Valid presets: 0=2MHz, 1=3.75MHz, 2=6MHz, 3=10MHz, 4=15MHz, 6=30MHz")
        print("Valid MHz: 10, 15, 30")
        return
    name = CLK_PRESETS[preset][1]
    print(f"Setting eMMC clock to preset {preset} ({name})...")
    tool.set_clk_speed(preset)
    print(f"Clock set to {name}.")


def cmd_set_baud(tool: EmmcTool, args):
    """Set UART baud rate (runtime, no re-synthesis)."""
    preset = args.preset
    if preset not in BAUD_PRESETS:
        print(f"Invalid preset: {preset}. Valid: 0=3M, 1=6M, 3=12M")
        return
    baud, name = BAUD_PRESETS[preset]
    print(f"Switching UART to preset {preset} ({name})...")
    tool.set_baud(preset)
    print(f"UART now running at {name}.")


def cmd_extcsd(tool: EmmcTool, args):
    """Read and display Extended CSD information."""
    print("Reading Extended CSD...")
    ext_csd = tool.get_ext_csd()
    info = tool.parse_ext_csd(ext_csd)

    print("=== Extended CSD Info ===")

    # Capacity
    cap = info["capacity_bytes"]
    if cap >= 1024 ** 3:
        print(f"Capacity: {cap / 1024 ** 3:.2f} GB ({info['sec_count']} sectors)")
    else:
        print(f"Capacity: {cap / 1024 ** 2:.0f} MB ({info['sec_count']} sectors)")

    # Partitions
    boot_mb = info["boot_partition_size"] / (1024 * 1024)
    rpmb_kb = info["rpmb_size"] / 1024
    print(f"Boot partition size: {boot_mb:.0f} MB each (boot0/boot1)")
    print(f"RPMB size: {rpmb_kb:.0f} KB")

    # Current partition access
    part_names = {0: "user", 1: "boot0", 2: "boot1", 3: "RPMB"}
    current_part = info["partition_access"]
    print(f"Current partition: {part_names.get(current_part, f'{current_part}')}")

    # Device health
    life_names = {0: "Not defined", 1: "0-10%", 2: "10-20%", 3: "20-30%",
                  4: "30-40%", 5: "40-50%", 6: "50-60%", 7: "60-70%",
                  8: "70-80%", 9: "80-90%", 10: "90-100%", 11: "Exceeded"}
    eol_names = {0: "Not defined", 1: "Normal", 2: "Warning", 3: "Urgent"}
    print(f"\nDevice Health:")
    print(f"  Life time (Type A/SLC): {life_names.get(info['life_time_est_a'], 'Unknown')}")
    print(f"  Life time (Type B/MLC): {life_names.get(info['life_time_est_b'], 'Unknown')}")
    print(f"  Pre-EOL info: {eol_names.get(info['pre_eol_info'], 'Unknown')}")

    # Speed capabilities
    print(f"\nSpeed Support:")
    print(f"  HS26: {'Yes' if info['hs_support'] else 'No'}")
    print(f"  HS52: {'Yes' if info['hs52_support'] else 'No'}")
    print(f"  DDR: {'Yes' if info['ddr_support'] else 'No'}")

    print(f"\nFirmware version: {info['fw_version']}")

    if args.raw:
        print(f"\nRaw ExtCSD (512 bytes):")
        for i in range(0, 512, 32):
            hex_line = ' '.join(f'{b:02x}' for b in ext_csd[i:i+32])
            print(f"  [{i:3d}] {hex_line}")


def cmd_set_partition(tool: EmmcTool, args):
    """Switch eMMC partition access."""
    part_map = {"user": 0, "boot0": 1, "boot1": 2, "rpmb": 3}
    part_name = args.partition.lower()
    if part_name.isdigit():
        part_id = int(part_name)
    elif part_name in part_map:
        part_id = part_map[part_name]
    else:
        print(f"Error: invalid partition '{args.partition}'. Use: user, boot0, boot1, rpmb, or 0-3")
        sys.exit(1)

    if part_id == 3:
        print("WARNING: RPMB partition selected!")
        print("  RPMB requires authenticated frame protocol (CMD23+CMD25+CMD23+CMD18),")
        print("  NOT plain CMD17/CMD24. Our FPGA sends plain block commands.")
        print("  This is a JEDEC protocol violation and can BRICK the eMMC controller.")
        print("  Incident: YMTC 64GB eMMC entered irreversible error state after CMD17 on RPMB.")
        print()
        resp = input("Type 'yes' to proceed at your own risk: ")
        if resp.strip().lower() != 'yes':
            print("Aborted.")
            sys.exit(1)

    print(f"Switching to partition: {part_name} (id={part_id})...")
    tool.set_partition(part_id)
    print("Partition switched successfully.")
    print("Note: Use 'read'/'hexdump' commands to access the new partition.")


def cmd_erase(tool: EmmcTool, args):
    """Erase sectors on eMMC."""
    lba = int(args.lba, 0)
    count = int(args.count, 0)
    print(f"Erasing {count} sectors starting at LBA {lba} (0x{lba:X})...")
    tool.erase(lba, count)
    print(f"Erase completed: LBA {lba}..{lba + count - 1}")


def cmd_secure_erase(tool: EmmcTool, args):
    """Secure erase sectors on eMMC (physical overwrite guaranteed)."""
    lba = int(args.lba, 0)
    count = int(args.count, 0)
    print(f"Secure erasing {count} sectors starting at LBA {lba} (0x{lba:X})...")
    tool.secure_erase(lba, count)
    print(f"Secure erase completed: LBA {lba}..{lba + count - 1}")


def cmd_write_extcsd(tool: EmmcTool, args):
    """Write ExtCSD byte via CMD6 SWITCH."""
    index = int(args.index, 0)
    value = int(args.value, 0)
    if not (0 <= index <= 511):
        print(f"Error: index must be 0-511, got {index}")
        sys.exit(1)
    if not (0 <= value <= 255):
        print(f"Error: value must be 0-255, got {value}")
        sys.exit(1)
    print(f"Writing ExtCSD[{index}] = 0x{value:02X} ({value})...")
    tool.write_ext_csd(index, value)
    print("Write ExtCSD completed.")


def cmd_cache_flush(tool: EmmcTool, args):
    """Enable cache and flush to flash."""
    print("Enabling eMMC cache (ExtCSD[33] = 1)...")
    tool.write_ext_csd(33, 1)
    print("Flushing cache (ExtCSD[32] = 1)...")
    tool.write_ext_csd(32, 1)
    print("Cache flush completed.")


def cmd_boot_config(tool: EmmcTool, args):
    """Configure boot partition in ExtCSD[179]."""
    part_map = {"none": 0, "boot0": 1, "boot1": 2, "user": 7}
    part_name = args.partition.lower()
    if part_name.isdigit():
        boot_part = int(part_name)
    elif part_name in part_map:
        boot_part = part_map[part_name]
    else:
        print(f"Error: invalid partition '{args.partition}'. Use: none, boot0, boot1, user, or 0-7")
        sys.exit(1)

    # ExtCSD[179] PARTITION_CONFIG: bits [5:3] = BOOT_PARTITION_ENABLE
    # Read current value first
    print(f"Reading current ExtCSD...")
    ext_csd = tool.get_ext_csd()
    current = ext_csd[179]
    new_val = (current & 0b11000111) | ((boot_part & 0x07) << 3)
    print(f"ExtCSD[179]: current=0x{current:02X}, new=0x{new_val:02X} (boot_partition={part_name})")
    tool.write_ext_csd(179, new_val)
    print("Boot config updated.")



def cmd_bootinfo(tool: EmmcTool, args):
    """Analyze boot partition (U-Boot header, DTB)."""
    # Switch to boot0 partition
    print("Switching to boot0 partition...")
    tool.set_partition(1)  # boot0
    
    # Read first 8KB
    boot_data = tool.read_sectors(0, 16)
    
    # U-Boot legacy image header
    UBOOT_MAGIC = 0x27051956
    magic = struct.unpack(">I", boot_data[0:4])[0]
    
    print("\nBoot Partition: boot0")
    print("-" * 40)
    
    if magic == UBOOT_MAGIC:
        print("U-Boot Header:")
        print(f"  Magic:      0x{magic:08X} ✓")
        
        timestamp = struct.unpack(">I", boot_data[8:12])[0]
        import datetime
        try:
            dt = datetime.datetime.utcfromtimestamp(timestamp)
            print(f"  Timestamp:  {dt.strftime('%Y-%m-%d %H:%M:%S')} UTC")
        except:
            print(f"  Timestamp:  {timestamp}")
        
        data_size = struct.unpack(">I", boot_data[12:16])[0]
        load_addr = struct.unpack(">I", boot_data[16:20])[0]
        entry_addr = struct.unpack(">I", boot_data[20:24])[0]
        
        print(f"  Data Size:  {data_size} bytes ({data_size/1024:.1f} KB)")
        print(f"  Load Addr:  0x{load_addr:08X}")
        print(f"  Entry:      0x{entry_addr:08X}")
        
        # Image name at offset 32, 32 bytes
        name = boot_data[32:64].decode('ascii', errors='ignore').rstrip('\x00')
        if name:
            print(f"  Name:       {name}")
    else:
        print(f"U-Boot Header: Not found (magic=0x{magic:08X})")
        print("  May be raw binary or different format")
    
    # Look for FDT (Device Tree) magic
    FDT_MAGIC = 0xD00DFEED
    fdt_offset = None
    for i in range(0, len(boot_data) - 4, 4):
        if struct.unpack(">I", boot_data[i:i+4])[0] == FDT_MAGIC:
            fdt_offset = i
            break
    
    if fdt_offset is not None:
        fdt_size = struct.unpack(">I", boot_data[fdt_offset+4:fdt_offset+8])[0]
        print(f"\nDevice Tree:")
        print(f"  Offset:     0x{fdt_offset:X}")
        print(f"  Magic:      0xD00DFEED ✓")
        print(f"  Size:       {fdt_size} bytes ({fdt_size/1024:.1f} KB)")
    else:
        print("\nDevice Tree: Not found in first 8KB")
    
    # Switch back to user partition
    print("\nSwitching back to user partition...")
    tool.set_partition(0)


def find_data_partition(tool: EmmcTool) -> dict:
    """Find the /data (userdata) partition in GPT. Returns partition dict."""
    parts = read_gpt(tool)
    data_names = ["userdata", "data", "USERDATA"]
    for p in parts:
        if p.get("name", "").lower() in [n.lower() for n in data_names]:
            return p
    raise RuntimeError(
        "Partition 'userdata'/'data' not found. "
        f"Available: {', '.join(p.get('name', '?') for p in parts)}")


def open_ext4(tool: EmmcTool, part_name_or_num=None) -> 'Ext4':
    """Open ext4 filesystem on a partition. Auto-detects /data if no argument."""
    if not HAS_EXT4:
        print("Error: ext4_utils.py not found")
        print("Make sure ext4_utils.py is in the same directory as emmc_tool.py")
        sys.exit(1)

    parts = read_gpt(tool)
    part = None

    if part_name_or_num is None:
        part = find_data_partition(tool)
    elif isinstance(part_name_or_num, int):
        for p in parts:
            if p['num'] == part_name_or_num:
                part = p
                break
    else:
        # Try by name
        for p in parts:
            if p.get('name', '').lower() == str(part_name_or_num).lower():
                part = p
                break
        # Try as number
        if part is None:
            try:
                num = int(part_name_or_num)
                for p in parts:
                    if p['num'] == num:
                        part = p
                        break
            except ValueError:
                pass

    if part is None:
        raise RuntimeError(
            f"Partition '{part_name_or_num}' not found. "
            "Available: " + ', '.join(f"{p['num']}:{p.get('name','?')}" for p in parts))

    print(f"Opening ext4 on partition '{part.get('name', '?')}' "
          f"(start_lba={part['start_lba']}, {format_size(part['size_sectors'])})")
    return Ext4(tool, part['start_lba'])


def cmd_ext4_info(tool: EmmcTool, args):
    """Show ext4 filesystem info."""
    fs = open_ext4(tool, getattr(args, 'partition', None))
    info = fs.info()
    print(f"\n=== ext4 Filesystem Info ===")
    print(f"  Volume:       {info['volume_name'] or '(none)'}")
    print(f"  UUID:         {info['uuid']}")
    print(f"  Block size:   {info['block_size']} bytes")
    print(f"  Blocks:       {info['block_count']} ({info['free_blocks']} free)")
    print(f"  Inodes:       {info['inode_count']} ({info['free_inodes']} free)")
    print(f"  Inode size:   {info['inode_size']} bytes")
    print(f"  Groups:       {info['num_groups']}")
    print(f"  Desc size:    {info['desc_size']} bytes")
    print(f"  64-bit:       {info['64bit']}")
    print(f"  Extents:      {info['has_extents']}")
    print(f"  Journal:      {info['has_journal']}")
    print(f"  Metadata CRC: {info['metadata_csum']}")
    cap = info['block_count'] * info['block_size']
    free = info['free_blocks'] * info['block_size']
    used = cap - free
    print(f"  Capacity:     {cap / 1024 / 1024:.0f} MB "
          f"(used {used / 1024 / 1024:.0f} MB, free {free / 1024 / 1024:.0f} MB)")


def cmd_ext4_ls(tool: EmmcTool, args):
    """List directory contents on ext4 partition."""
    fs = open_ext4(tool, getattr(args, 'partition', None))
    path = getattr(args, 'path', '/')
    entries = fs.ls(path)

    print(f"\n=== {path} ({len(entries)} entries) ===")
    for e in entries:
        ft = fs.file_type_name(e['file_type'])
        # Read inode for size info
        try:
            inode = fs._read_inode(e['inode'])
            size = inode['i_size']
            mode = inode['i_mode']
            mode_str = f"{mode:06o}"
        except Exception:
            size = 0
            mode_str = "??????"
        print(f"  {ft} {mode_str} {size:>10}  {e['name']}")


def cmd_ext4_cat(tool: EmmcTool, args):
    """Read and display file from ext4 partition."""
    fs = open_ext4(tool, getattr(args, 'partition', None))
    path = args.path
    outfile = getattr(args, 'outfile', None)

    try:
        data = fs.cat(path)
    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)

    print(f"File: {path} ({len(data)} bytes)")

    if outfile:
        with open(outfile, 'wb') as f:
            f.write(data)
        print(f"Written to: {outfile}")
    else:
        # Show hex dump for binary, text for ASCII
        is_text = all(b == 0 or 32 <= b < 127 or b in (9, 10, 13) for b in data[:256])
        if is_text and data:
            print("--- content ---")
            print(data.decode('utf-8', errors='replace'))
            print("--- end ---")
        else:
            print("--- hex dump ---")
            for off in range(0, min(len(data), 512), 16):
                chunk = data[off:off + 16]
                hex_part = ' '.join(f'{b:02x}' for b in chunk)
                ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
                print(f"  {off:08x}  {hex_part:<48s}  |{ascii_part}|")
            if len(data) > 512:
                print(f"  ... ({len(data) - 512} more bytes)")


def cmd_ext4_write(tool: EmmcTool, args):
    """Overwrite existing file on ext4 partition."""
    confirm = getattr(args, 'confirm', False)
    fs = open_ext4(tool, getattr(args, 'partition', None))
    path = args.path

    # Get data from hex string or file
    if hasattr(args, 'data_hex') and args.data_hex:
        data = bytes.fromhex(args.data_hex)
    elif hasattr(args, 'infile') and args.infile:
        with open(args.infile, 'rb') as f:
            data = f.read()
    else:
        print("Error: specify --data-hex or --infile")
        sys.exit(1)

    try:
        inode = fs.lookup(path)
    except FileNotFoundError:
        print(f"Error: file not found: {path}")
        sys.exit(1)

    print(f"File: {path}")
    print(f"  Current size: {inode['i_size']} bytes")
    print(f"  New data:     {len(data)} bytes")
    print(f"  New data hex: {data.hex()}")

    if not confirm:
        print("\nDRY RUN — use --confirm to write")
        return

    fs.overwrite_file_data(inode, data)
    print("\nWritten successfully!")


def cmd_ext4_create(tool: EmmcTool, args):
    """Create a new file on ext4 partition."""
    confirm = getattr(args, 'confirm', False)
    fs = open_ext4(tool, getattr(args, 'partition', None))
    parent = args.parent_path
    name = args.filename

    # Get data
    data = b''
    if hasattr(args, 'data_hex') and args.data_hex:
        data = bytes.fromhex(args.data_hex)

    print(f"Create: {parent.rstrip('/')}/{name}")
    print(f"  Data: {len(data)} bytes ({data.hex() if data else 'empty'})")

    if fs.exists(f"{parent.rstrip('/')}/{name}"):
        print(f"\nFile already exists!")
        sys.exit(1)

    if not confirm:
        print("\nDRY RUN — use --confirm to create")
        return

    ino = fs.create_file(parent, name, data)
    print(f"\nCreated successfully! Inode: {ino}")


def cmd_bus_width(tool, args):
    """Set eMMC bus width (1 or 4)."""
    try:
        tool.set_bus_width(args.width)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


def cmd_rpmb_counter(tool, args):
    """Read RPMB Write Counter."""
    print("Reading RPMB Write Counter...")
    try:
        resp, mac_valid = tool.rpmb_read_counter()
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

    print(f"  Response type: 0x{resp['req_resp_type']:04X}")
    result_name = RPMB_RESULT_NAMES.get(resp['result'], f"Unknown (0x{resp['result']:04X})")
    print(f"  Result: {result_name}")
    print(f"  Write Counter: {resp['write_counter']}")
    print(f"  MAC: {'VALID' if mac_valid else 'INVALID'} (HMAC-SHA256, test key)")
    print(f"  Nonce: {resp['nonce'].hex()}")


def cmd_rpmb_read(tool, args):
    """Read RPMB data at given address."""
    address = int(args.address, 0)
    print(f"Reading RPMB address {address}...")
    try:
        resp, mac_valid, raw = tool.rpmb_read_data(address)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

    result_name = RPMB_RESULT_NAMES.get(resp['result'], f"Unknown (0x{resp['result']:04X})")
    print(f"  Result: {result_name}")
    print(f"  Write Counter: {resp['write_counter']}")
    print(f"  MAC: {'VALID' if mac_valid else 'INVALID'}")

    if hasattr(args, 'hex') and args.hex:
        data = resp['data']
        for i in range(0, len(data), 16):
            hex_part = ' '.join(f'{b:02X}' for b in data[i:i + 16])
            ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[i:i + 16])
            print(f"  {i:04X}: {hex_part:<48s}  {ascii_part}")
    else:
        data = resp['data']
        if data == b'\x00' * 256:
            print("  Data: all zeros (256 bytes)")
        elif data == b'\xff' * 256:
            print("  Data: all 0xFF (256 bytes, erased)")
        else:
            print(f"  Data (first 32 bytes): {data[:32].hex()}")
            print(f"  (use --hex for full dump)")


def cmd_rpmb_dump(tool, args):
    """Dump entire RPMB partition to file."""
    ext_csd = tool.get_ext_csd()
    rpmb_size_mult = ext_csd[168]
    rpmb_size = rpmb_size_mult * 128 * 1024  # bytes
    rpmb_blocks = rpmb_size // 256  # RPMB blocks are 256 bytes (half-sectors)

    print(f"RPMB size: {rpmb_size // 1024} KB ({rpmb_blocks} blocks of 256 bytes)")
    print(f"Output: {args.outfile}")

    data = bytearray()
    errors = 0
    for addr in range(rpmb_blocks):
        try:
            resp, mac_valid, raw = tool.rpmb_read_data(addr)
            if resp['result'] != 0:
                result_name = RPMB_RESULT_NAMES.get(resp['result'], f"0x{resp['result']:04X}")
                print(f"  Block {addr}: result={result_name}, skipping")
                data += b'\x00' * 256
                errors += 1
            else:
                data += resp['data']
                if not mac_valid:
                    print(f"  Block {addr}: MAC INVALID")
                    errors += 1
        except Exception as e:
            print(f"  Block {addr}: error: {e}")
            data += b'\x00' * 256
            errors += 1

        if (addr + 1) % 16 == 0 or addr == rpmb_blocks - 1:
            print(f"\r  Progress: {addr + 1}/{rpmb_blocks} blocks", end='', flush=True)

    print()

    with open(args.outfile, 'wb') as f:
        f.write(data)

    print(f"Done. {len(data)} bytes written to {args.outfile}")
    if errors > 0:
        print(f"  WARNING: {errors} blocks had errors")


def main():
    parser = argparse.ArgumentParser(description="eMMC Card Reader Tool")
    parser.add_argument("-p", "--port", default="/dev/ttyACM0", help="Serial port (default: /dev/ttyACM0)")
    parser.add_argument("-t", "--timeout", type=float, default=5.0, help="Timeout in seconds")
    parser.add_argument("-b", "--baud", type=int, default=BAUD_RATE,
                        help=f"Baud rate (default: {BAUD_RATE}, try 2000000 if unstable)")
    parser.add_argument("--retry", type=int, default=0, metavar="N",
                        help="Retry failed operations N times with exponential backoff")
    parser.add_argument("--ignore-crc", action="store_true",
                        help="Warn on CRC mismatch instead of raising an error (debug only)")
    parser.add_argument("--multi", action="store_true",
                        help="Use multi-sector reads (CMD18) instead of single-sector (CMD17)")
    parser.add_argument("--fifo", action="store_true",
                        help="Use FT245 FIFO transport instead of UART (requires FT232H EEPROM config)")

    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("ping", help="Test connection")
    subparsers.add_parser("info", help="Read eMMC CID/CSD")

    p_read = subparsers.add_parser("read", help="Read sectors")
    p_read.add_argument("lba", help="Start LBA (decimal or 0x hex)")
    p_read.add_argument("count", help="Number of sectors")
    p_read.add_argument("outfile", help="Output file")
    p_read.add_argument("--fast", action="store_true",
                        help="Auto-switch to 12M baud + 10 MHz eMMC for faster reading")

    p_write = subparsers.add_parser("write", help="Write sectors")
    p_write.add_argument("lba", help="Start LBA (decimal or 0x hex)")
    p_write.add_argument("infile", help="Input file")
    p_write.add_argument("--fast", action="store_true",
                         help="Auto-switch to 12M baud + 10 MHz eMMC for faster writing")
    p_write.add_argument("--verify", action="store_true",
                         help="Verify written data by reading back and comparing")

    p_dump = subparsers.add_parser("dump", help="Full eMMC dump")
    p_dump.add_argument("outfile", help="Output file")
    p_dump.add_argument("--fast", action="store_true",
                        help="Auto-switch to 12M baud for faster dumping (requires FT232H)")
    p_dump.add_argument("--verify", action="store_true",
                        help="Verify dump by reading back eMMC and comparing to output file")

    p_restore = subparsers.add_parser("restore", help="Restore eMMC from file")
    p_restore.add_argument("infile", help="Input dump file")
    p_restore.add_argument("--lba", default="0", help="Start LBA (default: 0)")
    p_restore.add_argument("--count", type=str, default=None,
                           help="Max sectors to write (default: entire file)")
    p_restore.add_argument("--fast", action="store_true",
                           help="Auto-switch to 12M baud for faster restore (requires FT232H)")
    p_restore.add_argument("--verify", action="store_true",
                           help="Verify restored data by reading back and comparing to source file")

    subparsers.add_parser("status", help="Controller status")

    subparsers.add_parser("partitions", help="Show partition table")

    p_mount = subparsers.add_parser("mount", help="Dump partition & loop-mount")
    p_mount.add_argument("partition", type=int, help="Partition number")
    p_mount.add_argument("mountpoint", help="Mount point directory")

    p_umount = subparsers.add_parser("umount", help="Unmount & cleanup")
    p_umount.add_argument("mountpoint", help="Mount point to unmount")

    p_hexdump = subparsers.add_parser("hexdump", help="Hex dump sectors")
    p_hexdump.add_argument("lba", help="Start LBA (decimal or 0x hex)")
    p_hexdump.add_argument("count", nargs="?", default="1", help="Number of sectors (default: 1)")

    p_verify = subparsers.add_parser("verify", help="Verify eMMC data against file")
    p_verify.add_argument("lba", help="Start LBA (decimal or 0x hex)")
    p_verify.add_argument("infile", help="File to compare against")
    p_verify.add_argument("--count", type=str, default=None,
                           help="Max sectors to verify (default: entire file)")
    p_verify.add_argument("--fast", action="store_true",
                           help="Use 12M baud + 10 MHz eMMC for faster verify")

    p_extcsd = subparsers.add_parser("extcsd", help="Read Extended CSD (512-byte info)")
    p_extcsd.add_argument("--raw", action="store_true", help="Show raw bytes")

    p_setpart = subparsers.add_parser("setpart", help="Switch partition (user/boot0/boot1/rpmb)")
    p_setpart.add_argument("partition", help="Partition: user, boot0, boot1, rpmb, or 0-3")

    p_erase = subparsers.add_parser("erase", help="Erase sectors on eMMC")
    p_erase.add_argument("lba", help="Start LBA (decimal or 0x hex)")
    p_erase.add_argument("count", help="Number of sectors to erase")

    p_serase = subparsers.add_parser("secure-erase", help="Secure erase (physical overwrite)")
    p_serase.add_argument("lba", help="Start LBA (decimal or 0x hex)")
    p_serase.add_argument("count", help="Number of sectors to erase")

    p_wextcsd = subparsers.add_parser("write-extcsd", help="Write ExtCSD byte via CMD6 SWITCH")
    p_wextcsd.add_argument("index", help="ExtCSD byte index (0-511)")
    p_wextcsd.add_argument("value", help="New value (0-255)")

    subparsers.add_parser("card-status", help="Read Card Status Register (CMD13 SEND_STATUS)")

    subparsers.add_parser("reinit", help="Full re-initialization (CMD0 + init sequence)")

    p_setclk = subparsers.add_parser("set-clock", help="Set eMMC clock speed (MHz or preset 0-6)")
    p_setclk.add_argument("speed", type=int, help="Speed in MHz (2,4,6,9,12,18,36) or preset index (0-6)")

    p_setbaud = subparsers.add_parser("set-baud", help="Set UART baud rate (0=3M, 1=6M, 3=12M)")
    p_setbaud.add_argument("preset", type=int, help="Preset index: 0=3M, 1=6M, 3=12M")

    p_rawcmd = subparsers.add_parser("raw-cmd", help="Send arbitrary eMMC command")
    p_rawcmd.add_argument("index", type=int, help="CMD index (0-63)")
    p_rawcmd.add_argument("argument", type=str, help="32-bit argument (hex: 0x... or decimal)")
    p_rawcmd.add_argument("--no-resp", action="store_true", help="Don't expect response")
    p_rawcmd.add_argument("--long", action="store_true", help="Expect R2 (128-bit) response")
    p_rawcmd.add_argument("--busy", action="store_true", help="Poll DAT0 busy after response")

    p_recover = subparsers.add_parser("recover", help="Automated eMMC recovery sequence")
    p_recover.add_argument("--target-mid", type=str, default=None,
                           help="Target MID in hex (e.g. 0x9B). Stop when MID matches.")

    subparsers.add_parser("cache-flush", help="Enable eMMC cache and flush to flash")

    p_bootcfg = subparsers.add_parser("boot-config", help="Configure boot partition")
    p_bootcfg.add_argument("partition", help="Boot partition: none, boot0, boot1, user, or 0-7")

    subparsers.add_parser("bootinfo", help="Analyze boot partition (U-Boot, DTB)")

    # ext4 filesystem commands
    p_ext4info = subparsers.add_parser("ext4-info", help="Show ext4 filesystem info")
    p_ext4info.add_argument("partition", nargs="?", default=None,
                            help="Partition name or number (default: userdata)")

    p_ext4ls = subparsers.add_parser("ext4-ls", help="List directory on ext4 partition")
    p_ext4ls.add_argument("path", nargs="?", default="/", help="Directory path (default: /)")
    p_ext4ls.add_argument("--partition", "-P", default=None,
                          help="Partition name or number (default: userdata)")

    p_ext4cat = subparsers.add_parser("ext4-cat", help="Read file from ext4 partition")
    p_ext4cat.add_argument("path", help="File path")
    p_ext4cat.add_argument("--outfile", "-o", default=None, help="Save to file")
    p_ext4cat.add_argument("--partition", "-P", default=None,
                           help="Partition name or number (default: userdata)")

    p_ext4write = subparsers.add_parser("ext4-write", help="Overwrite existing file on ext4")
    p_ext4write.add_argument("path", help="File path to overwrite")
    p_ext4write.add_argument("--data-hex", default=None, help="Data as hex string")
    p_ext4write.add_argument("--infile", default=None, help="Data from file")
    p_ext4write.add_argument("--partition", "-P", default=None,
                             help="Partition name or number (default: userdata)")
    p_ext4write.add_argument("--confirm", action="store_true", help="Actually write")

    p_ext4create = subparsers.add_parser("ext4-create", help="Create new file on ext4")
    p_ext4create.add_argument("parent_path", help="Parent directory path")
    p_ext4create.add_argument("filename", help="New file name")
    p_ext4create.add_argument("--data-hex", default=None, help="File data as hex string")
    p_ext4create.add_argument("--partition", "-P", default=None,
                              help="Partition name or number (default: userdata)")
    p_ext4create.add_argument("--confirm", action="store_true", help="Actually create")

    subparsers.add_parser("rpmb-counter", help="Read RPMB Write Counter (tests auth key)")

    p_rpmb_read = subparsers.add_parser("rpmb-read", help="Authenticated RPMB read")
    p_rpmb_read.add_argument("address", help="RPMB block address (0-based, 256-byte blocks)")
    p_rpmb_read.add_argument("--hex", action="store_true", help="Show full hex dump of data")

    p_rpmb_dump = subparsers.add_parser("rpmb-dump", help="Dump entire RPMB to file")
    p_rpmb_dump.add_argument("outfile", help="Output file")

    p_buswidth = subparsers.add_parser("bus-width", help="Set eMMC bus width (1 or 4)")
    p_buswidth.add_argument("width", type=int, choices=[1, 4], help="Bus width: 1 or 4")

    args = parser.parse_args()

    # umount doesn't need FPGA connection
    if args.command == "umount":
        cmd_umount(None, args)
        return

    tool = EmmcTool(args.port, timeout=args.timeout, baud=args.baud,
                    ignore_crc=args.ignore_crc,
                    multi_sector=getattr(args, 'multi', False),
                    use_fifo=args.fifo)
    tool.max_retries = args.retry
    try:
        commands = {
            "ping": cmd_ping,
            "info": cmd_info,
            "read": cmd_read,
            "write": cmd_write,
            "dump": cmd_dump,
            "restore": cmd_restore,
            "status": cmd_status,
            "partitions": cmd_partitions,
            "mount": cmd_mount,
            "hexdump": cmd_hexdump,
            "verify": cmd_verify,
            "extcsd": cmd_extcsd,
            "setpart": cmd_set_partition,
            "erase": cmd_erase,
            "secure-erase": cmd_secure_erase,
            "write-extcsd": cmd_write_extcsd,
            "card-status": cmd_card_status,
            "reinit": cmd_reinit,
            "set-clock": cmd_set_clock,
            "set-baud": cmd_set_baud,
            "raw-cmd": cmd_raw_cmd,
            "recover": cmd_recover,
            "cache-flush": cmd_cache_flush,
            "boot-config": cmd_boot_config,
            "bootinfo": cmd_bootinfo,
            "ext4-info": cmd_ext4_info,
            "ext4-ls": cmd_ext4_ls,
            "ext4-cat": cmd_ext4_cat,
            "ext4-write": cmd_ext4_write,
            "ext4-create": cmd_ext4_create,
            "rpmb-counter": cmd_rpmb_counter,
            "rpmb-read": cmd_rpmb_read,
            "rpmb-dump": cmd_rpmb_dump,
            "bus-width": cmd_bus_width,
        }
        commands[args.command](tool, args)
    finally:
        tool.close()


if __name__ == "__main__":
    main()
