#!/usr/bin/env python3
"""Re-read zero chunks in a dump at lower speed and patch them in-place."""

import argparse
import os
import sys
import time

# Add parent dir for imports
sys.path.insert(0, os.path.dirname(__file__))
from emmc_tool import EmmcTool, SECTOR_SIZE

CHUNK_SECTORS = 64  # must match emmc_tool read chunk
CHUNK_BYTES = CHUNK_SECTORS * SECTOR_SIZE


def find_zero_chunks(path, base_lba=0):
    """Find all CHUNK_SECTORS-aligned zero chunks in dump."""
    size = os.path.getsize(path)
    chunks = []
    with open(path, 'rb') as f:
        offset = 0
        while offset < size:
            data = f.read(CHUNK_BYTES)
            if not data:
                break
            if data == b'\x00' * len(data):
                lba = base_lba + offset // SECTOR_SIZE
                chunks.append((lba, len(data) // SECTOR_SIZE, offset))
            offset += len(data)
    return chunks


def main():
    parser = argparse.ArgumentParser(description='Repair zero chunks in eMMC dump')
    parser.add_argument('dump', help='Dump file to repair in-place')
    parser.add_argument('--port', default='/dev/ttyUSB1')
    parser.add_argument('--base-lba', type=int, default=0,
                        help='Base LBA of the dump (if dump starts at non-zero LBA)')
    parser.add_argument('--clock', type=int, default=0, choices=[0,1,2,3,4],
                        help='eMMC clock preset (0=2MHz, 1=3.75, 2=6, 3=10MHz). Default: 0 (2 MHz)')
    parser.add_argument('--baud', type=int, default=0, choices=[0,1,3],
                        help='UART baud preset (0=3M, 1=6M, 3=12M). Default: 0 (3M)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Only show what would be re-read')
    parser.add_argument('--skip-partitions', nargs='*', default=[],
                        help='Partition names to skip (known-empty)')
    args = parser.parse_args()

    print(f"Scanning {args.dump} for zero chunks...")
    chunks = find_zero_chunks(args.dump, args.base_lba)

    total_sectors = sum(c[1] for c in chunks)
    total_mb = total_sectors * SECTOR_SIZE / (1024 * 1024)
    print(f"Found {len(chunks)} zero chunks, {total_sectors} sectors ({total_mb:.1f} MB)")

    if not chunks:
        print("Nothing to repair!")
        return

    if args.dry_run:
        print("\nDry run - not reading anything.")
        print(f"Would re-read {len(chunks)} chunks at clock preset {args.clock}")
        return

    # Connect
    tool = EmmcTool(args.port, baud=3000000)
    if not tool.ping():
        print("ERROR: FPGA not responding")
        return

    # Set speeds
    if args.clock > 0:
        tool.set_clk_speed(args.clock)
        print(f"eMMC clock set to preset {args.clock}")
    if args.baud > 0:
        tool.set_baud(args.baud)
        tool.ser.baudrate = [3000000, 6000000, 0, 12000000][args.baud]
        print(f"UART baud set to preset {args.baud}")

    tool._use_multi_sector = True

    patched = 0
    errors = 0
    skipped = 0
    start_time = time.time()

    with open(args.dump, 'r+b') as f:
        for i, (lba, count, file_offset) in enumerate(chunks):
            elapsed = time.time() - start_time
            speed = (i * CHUNK_BYTES) / elapsed / 1024 if elapsed > 0 else 0
            remaining = (len(chunks) - i) * CHUNK_BYTES / (speed * 1024) if speed > 0 else 0
            pct = (i + 1) * 100 / len(chunks)

            print(f"\r[{pct:5.1f}%] LBA {lba} chunk {i+1}/{len(chunks)} "
                  f"patched={patched} err={errors} "
                  f"{speed:.0f} KB/s ETA {remaining/60:.0f}m",
                  end="", flush=True)

            try:
                data = tool.read_sectors(lba, count)
            except Exception as e:
                errors += 1
                continue

            if data != b'\x00' * len(data):
                # Got real data - patch it
                f.seek(file_offset)
                f.write(data)
                patched += 1
            else:
                skipped += 1  # genuinely empty

    elapsed = time.time() - start_time
    print(f"\n\nDone in {elapsed:.0f}s")
    print(f"  Patched: {patched} chunks ({patched * CHUNK_BYTES / 1024 / 1024:.1f} MB)")
    print(f"  Genuinely empty: {skipped} chunks")
    print(f"  Errors: {errors} chunks")

    # Restore defaults
    if args.baud > 0:
        tool.set_baud(0)
        tool.ser.baudrate = 3000000
    if args.clock > 0:
        tool.set_clk_speed(0)
    print("Speeds restored to defaults.")


if __name__ == '__main__':
    main()
