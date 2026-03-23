#!/usr/bin/env python3
"""
eMMC Speed Sweep — test all UART baud × eMMC clock combinations.

Measures real throughput for write (CMD25, CHUNK=16) and read (CMD18, CHUNK=64)
across all supported speed configurations on breadboard.

Usage:
    python3 tools/speed_test.py                        # autodetect port
    python3 tools/speed_test.py --port /dev/ttyUSB3    # explicit port
    python3 tools/speed_test.py --sectors 500           # smaller test (250 KB)
    python3 tools/speed_test.py --baud 2000000          # FT2232C clone
"""

import sys
import os
import time
import argparse
import struct

# Add tools/ to path for emmc_tool import
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from emmc_tool import (
    EmmcTool, BAUD_PRESETS, CLK_PRESETS, BAUD_RATE,
    STATUS_OK, CMD_GET_STATUS, EMMC_CLK_FREQ,
)

# Test matrix
UART_PRESETS = [0, 1, 3]        # 3M, 6M, 12M
EMMC_PRESETS = [0, 1, 2, 3, 4]  # 2, 3.75, 6, 10, 15 MHz

WRITE_CHUNK = 16   # sectors per CMD25 packet (matches 16-bank FIFO)

UART_LABELS = {0: "3 Mbaud", 1: "6 Mbaud", 3: "12 Mbaud"}
EMMC_LABELS = {0: "2 MHz", 1: "3.75 MHz", 2: "6 MHz", 3: "10 MHz", 4: "15 MHz"}


def generate_sector(lba: int) -> bytes:
    """Deterministic 512-byte pattern for a given LBA."""
    return bytes((lba * 7 + i) & 0xFF for i in range(512))


def autodetect_port(baud: int) -> str:
    """Try ttyUSB0..ttyUSB3 and ttyACM0, return first that responds to ping."""
    candidates = [f"/dev/ttyUSB{i}" for i in range(4)] + ["/dev/ttyACM0"]
    for port in candidates:
        if not os.path.exists(port):
            continue
        try:
            tool = EmmcTool(port, timeout=1.0, baud=baud)
            ok = tool.ping()
            tool.close()
            if ok:
                return port
        except Exception:
            pass
    return None


def run_write_test(tool: EmmcTool, start_lba: int, num_sectors: int) -> tuple:
    """Write num_sectors with deterministic pattern. Returns (elapsed_sec, error_count)."""
    errors = 0
    t0 = time.monotonic()
    lba = start_lba
    while lba < start_lba + num_sectors:
        chunk = min(WRITE_CHUNK, start_lba + num_sectors - lba)
        data = b"".join(generate_sector(l) for l in range(lba, lba + chunk))
        try:
            tool.write_sectors(lba, data)
        except Exception as e:
            errors += 1
            print(f"    WRITE error at LBA {lba}: {e}")
        lba += chunk
    elapsed = time.monotonic() - t0
    return elapsed, errors


def run_read_test(tool: EmmcTool, start_lba: int, num_sectors: int) -> tuple:
    """Read num_sectors back. Returns (elapsed_sec, error_count, read_data)."""
    read_chunk = tool._safe_read_chunk()
    errors = 0
    data = bytearray()
    t0 = time.monotonic()
    lba = start_lba
    while lba < start_lba + num_sectors:
        chunk = min(read_chunk, start_lba + num_sectors - lba)
        try:
            rd = tool.read_sectors(lba, chunk)
            data.extend(rd)
        except Exception as e:
            errors += 1
            print(f"    READ error at LBA {lba}: {e}")
            # Pad with zeros so verification can report mismatch position
            data.extend(b'\x00' * chunk * 512)
        lba += chunk
    elapsed = time.monotonic() - t0
    return elapsed, errors, bytes(data)


def verify_data(start_lba: int, num_sectors: int, read_data: bytes) -> int:
    """Compare read_data against expected pattern. Returns number of mismatched sectors."""
    mismatches = 0
    for i in range(num_sectors):
        expected = generate_sector(start_lba + i)
        actual = read_data[i * 512:(i + 1) * 512]
        if actual != expected:
            mismatches += 1
    return mismatches


def get_debug_status(tool: EmmcTool) -> dict:
    """Read 12-byte debug status and extract error counters."""
    try:
        _, status, payload = tool._send_command(CMD_GET_STATUS)
        if status != STATUS_OK or len(payload) < 12:
            return {}
        return {
            "cmd_timeout": payload[6],
            "cmd_crc_err": payload[7],
            "dat_rd_err": payload[8],
            "dat_wr_err": payload[9],
        }
    except Exception:
        return {}


def format_speed(bytes_count: int, elapsed: float) -> str:
    """Format throughput as KB/s."""
    if elapsed <= 0:
        return "N/A"
    kbps = bytes_count / elapsed / 1024
    return f"{kbps:.0f} KB/s"


def print_table(title: str, results: dict, num_sectors: int):
    """Print a formatted results table."""
    total_bytes = num_sectors * 512

    # Column widths
    col_w = 10
    label_w = 10

    print(f"\n{title} ({num_sectors} sectors, {total_bytes // 1024} KB):")

    # Header
    header = f"{'UART':<{label_w}}|"
    sep = "-" * label_w + "|"
    for ep in EMMC_PRESETS:
        header += f"{EMMC_LABELS[ep]:>{col_w}}|"
        sep += "-" * col_w + "|"
    print(header)
    print(sep)

    # Rows
    for up in UART_PRESETS:
        row = f"{UART_LABELS[up]:<{label_w}}|"
        for ep in EMMC_PRESETS:
            key = (up, ep)
            if key in results:
                elapsed, errors = results[key]
                speed = format_speed(total_bytes, elapsed)
                if errors > 0:
                    speed += f"*{errors}"
                row += f"{speed:>{col_w}}|"
            else:
                row += f"{'SKIP':>{col_w}}|"
        print(row)


def main():
    parser = argparse.ArgumentParser(description="eMMC Speed Sweep")
    parser.add_argument("--port", help="Serial port (autodetect if not specified)")
    parser.add_argument("--baud", type=int, default=BAUD_RATE,
                        help=f"Initial baud rate (default {BAUD_RATE})")
    parser.add_argument("--sectors", type=int, default=2000,
                        help="Number of sectors per test (default 2000 = 1 MB)")
    parser.add_argument("--start-lba", type=int, default=0,
                        help="Starting LBA for tests (default 0)")
    parser.add_argument("--timeout", type=float, default=10.0,
                        help="Per-chunk timeout in seconds (default 10)")
    parser.add_argument("--skip-write", action="store_true",
                        help="Skip write tests")
    parser.add_argument("--skip-read", action="store_true",
                        help="Skip read tests")
    parser.add_argument("--cache", action="store_true",
                        help="Enable eMMC write cache (async flash programming)")
    args = parser.parse_args()

    num_sectors = args.sectors
    start_lba = args.start_lba

    # Find port
    port = args.port
    if not port:
        print("Autodetecting port...", end=" ", flush=True)
        port = autodetect_port(args.baud)
        if not port:
            print("FAILED — no FPGA found on ttyUSB0-3 / ttyACM0")
            sys.exit(1)
        print(f"found {port}")

    # Connect
    tool = EmmcTool(port, timeout=args.timeout, baud=args.baud, multi_sector=True)

    if not tool.ping():
        print(f"ERROR: FPGA not responding on {port}")
        sys.exit(1)

    # Card info
    try:
        info = tool.get_info()
        card_name = f"0x{info['manufacturer_id']:02X} {info['product_name']}"
    except Exception:
        card_name = "(unknown)"

    print(f"\n=== eMMC Speed Sweep ===")
    print(f"Port: {port}, FPGA: PONG OK")
    print(f"Card: {card_name}")
    print(f"Test: {num_sectors} sectors ({num_sectors * 512 // 1024} KB), "
          f"LBA {start_lba}..{start_lba + num_sectors - 1}")
    print(f"Write chunk: {WRITE_CHUNK}, Read chunk: adaptive")

    # Reinit to clean state
    print("\nReinit eMMC...", end=" ", flush=True)
    tool.reinit()
    print("OK")

    # Enable write cache if requested
    cache_enabled = False
    if args.cache:
        try:
            cache_enabled = tool.enable_cache()
            if cache_enabled:
                print("Write cache: ENABLED (async flash programming)")
            else:
                print("Write cache: NOT SUPPORTED by this card")
        except Exception as e:
            print(f"Write cache: FAILED ({e})")

    write_results = {}  # (uart_preset, emmc_preset) -> (elapsed, errors)
    read_results = {}
    verify_results = {}  # (uart_preset, emmc_preset) -> mismatch_count
    error_details = []

    current_baud_preset = 0  # we start at 3M (default)

    for up in UART_PRESETS:
        baud_label = UART_LABELS[up]

        # Switch UART baud if needed
        if up != current_baud_preset:
            print(f"\n--- Switching UART to {baud_label} ---")
            try:
                tool.set_baud(up)
                current_baud_preset = up
                print(f"  UART baud set to {baud_label}, ping OK")
            except Exception as e:
                print(f"  FAILED to switch UART to {baud_label}: {e}")
                print(f"  Skipping all tests at {baud_label}")
                # Try to recover to 3M
                try:
                    tool.close()
                    tool = EmmcTool(port, timeout=args.timeout, baud=args.baud,
                                    multi_sector=True)
                    current_baud_preset = 0
                except Exception:
                    pass
                continue

        for ep in EMMC_PRESETS:
            emmc_label = EMMC_LABELS[ep]
            combo = f"({baud_label}, {emmc_label})"
            print(f"\n  [{baud_label} + {emmc_label}]")

            # Set eMMC clock
            try:
                tool.set_clk_speed(ep)
            except Exception as e:
                print(f"    eMMC clock set FAILED: {e}")
                error_details.append(f"{combo}: eMMC clock failed: {e}")
                continue

            # WRITE test
            if not args.skip_write:
                print(f"    WRITE {num_sectors} sectors...", end=" ", flush=True)
                wr_elapsed, wr_errors = run_write_test(tool, start_lba, num_sectors)
                wr_speed = format_speed(num_sectors * 512, wr_elapsed)
                print(f"{wr_speed} ({wr_elapsed:.1f}s, errors={wr_errors})")
                write_results[(up, ep)] = (wr_elapsed, wr_errors)
                # Flush cache after write to ensure data reaches flash before verify
                if cache_enabled:
                    try:
                        tool.flush_cache()
                    except Exception:
                        pass

            # READ test
            if not args.skip_read:
                rd_chunk = tool._safe_read_chunk()
                print(f"    READ  {num_sectors} sectors (chunk={rd_chunk})...", end=" ", flush=True)
                rd_elapsed, rd_errors, rd_data = run_read_test(tool, start_lba, num_sectors)
                rd_speed = format_speed(num_sectors * 512, rd_elapsed)
                print(f"{rd_speed} ({rd_elapsed:.1f}s, errors={rd_errors})")
                read_results[(up, ep)] = (rd_elapsed, rd_errors)

                # Verify (only if we also wrote)
                if not args.skip_write:
                    mismatches = verify_data(start_lba, num_sectors, rd_data)
                    verify_results[(up, ep)] = mismatches
                    if mismatches > 0:
                        print(f"    VERIFY: {mismatches}/{num_sectors} sectors MISMATCH!")
                    else:
                        print(f"    VERIFY: OK")

            # Get FPGA error counters
            dbg = get_debug_status(tool)
            if dbg and any(v > 0 for v in dbg.values()):
                print(f"    FPGA counters: {dbg}")

            # Reinit to reset error counters for next test
            try:
                tool.reinit()
            except Exception as e:
                print(f"    reinit failed: {e}")

        # Restore eMMC clock to default before changing UART baud
        try:
            tool.set_clk_speed(0)
        except Exception:
            pass

    # Restore UART to default baud
    if current_baud_preset != 0:
        print(f"\n--- Restoring UART to {UART_LABELS[0]} ---")
        try:
            tool.set_baud(0)
            print("  OK")
        except Exception as e:
            print(f"  Failed: {e}")

    tool.close()

    # ===== Summary tables =====
    print("\n" + "=" * 70)
    print("=== SUMMARY ===")

    if write_results:
        print_table("WRITE", write_results, num_sectors)

    if read_results:
        print_table("READ", read_results, num_sectors)

    # Error summary
    print("\nERRORS:")
    any_errors = False
    for up in UART_PRESETS:
        for ep in EMMC_PRESETS:
            key = (up, ep)
            parts = []
            if key in write_results:
                _, we = write_results[key]
                if we > 0:
                    parts.append(f"write:{we}")
            if key in read_results:
                _, re_ = read_results[key]
                if re_ > 0:
                    parts.append(f"read:{re_}")
            if key in verify_results:
                vm = verify_results[key]
                if vm > 0:
                    parts.append(f"verify:{vm}/{num_sectors}")
            if parts:
                any_errors = True
                combo = f"({UART_LABELS[up]}, {EMMC_LABELS[ep]})"
                print(f"  {combo}: {', '.join(parts)}")

    if not any_errors:
        print("  None — all tests clean")

    # Data integrity
    if verify_results:
        failed = sum(1 for v in verify_results.values() if v > 0)
        total = len(verify_results)
        if failed == 0:
            print(f"\nDATA INTEGRITY: ALL {total} TESTS PASSED")
        else:
            print(f"\nDATA INTEGRITY: {failed}/{total} TESTS FAILED")


if __name__ == "__main__":
    main()
