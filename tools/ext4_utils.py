#!/usr/bin/env python3
"""
ext4 filesystem reader/writer for eMMC sector-based I/O.

Supports: superblock parsing, inode lookup, extent trees, directory traversal,
file read/write/create with metadata_csum (CRC-32C) checksum support.

Designed for FPGA-based eMMC card reader (sector-level access only).
"""

import struct
import time

SECTOR_SIZE = 512

# ext4 feature flags
COMPAT_HAS_JOURNAL = 0x04
INCOMPAT_FILETYPE = 0x02
INCOMPAT_EXTENTS = 0x40
INCOMPAT_64BIT = 0x80
INCOMPAT_CSUM_SEED = 0x2000
RO_COMPAT_LARGE_FILE = 0x02
RO_COMPAT_METADATA_CSUM = 0x400

# Inode flags
EXT4_EXTENTS_FL = 0x80000

# Directory file types
FT_REG_FILE = 1
FT_DIR = 2
FT_SYMLINK = 7

# Inode mode
S_IFMT = 0xF000
S_IFDIR = 0x4000
S_IFREG = 0x8000

# Extent magic
EXT4_EXT_MAGIC = 0xF30A

# Good old inode size (before extra fields)
EXT4_GOOD_OLD_INODE_SIZE = 128


# ─── CRC-32C (Castagnoli) ───

def _make_crc32c_table():
    """Generate CRC-32C lookup table (reflected polynomial 0x82F63B78)."""
    table = []
    for i in range(256):
        crc = i
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0x82F63B78
            else:
                crc >>= 1
        table.append(crc)
    return table

_CRC32C_TABLE = _make_crc32c_table()


def crc32c_raw(data: bytes, crc: int = 0xFFFFFFFF) -> int:
    """Raw CRC-32C update (no final XOR) — for chaining like Linux kernel's ext4_chksum()."""
    for byte in data:
        crc = (crc >> 8) ^ _CRC32C_TABLE[(crc ^ byte) & 0xFF]
    return crc


def align4(n: int) -> int:
    return (n + 3) & ~3


class Ext4:
    """ext4 filesystem operations via sector-based eMMC I/O."""

    def __init__(self, tool, part_start_lba: int):
        """
        Args:
            tool: object with read_sectors(lba, count)->bytes and write_sectors(lba, data)
            part_start_lba: starting LBA of the ext4 partition
        """
        self.tool = tool
        self.part_start = part_start_lba
        self._sb_raw = None
        self._read_superblock()

    # ─── Low-level I/O ───

    def _read_bytes(self, offset: int, length: int) -> bytes:
        """Read bytes from partition at byte offset."""
        start_sector = offset // SECTOR_SIZE
        end_sector = (offset + length - 1) // SECTOR_SIZE
        count = end_sector - start_sector + 1
        data = self.tool.read_sectors(self.part_start + start_sector, count)
        local = offset % SECTOR_SIZE
        return data[local:local + length]

    def _write_bytes(self, offset: int, data: bytes):
        """Write bytes at partition byte offset (read-modify-write sectors)."""
        start_sector = offset // SECTOR_SIZE
        end_sector = (offset + len(data) - 1) // SECTOR_SIZE
        count = end_sector - start_sector + 1
        existing = bytearray(self.tool.read_sectors(self.part_start + start_sector, count))
        local = offset % SECTOR_SIZE
        existing[local:local + len(data)] = data
        self.tool.write_sectors(self.part_start + start_sector, bytes(existing))

    def _read_block(self, block_num: int) -> bytes:
        """Read one filesystem block."""
        return self._read_bytes(block_num * self.block_size, self.block_size)

    def _write_block(self, block_num: int, data: bytes):
        """Write one filesystem block."""
        if len(data) != self.block_size:
            raise ValueError(f"Block data must be {self.block_size} bytes, got {len(data)}")
        self._write_bytes(block_num * self.block_size, data)

    # ─── Superblock ───

    def _read_superblock(self):
        """Parse ext4 superblock at offset 1024."""
        sb = self._read_bytes(1024, 1024)
        self._sb_raw = bytearray(sb)

        magic = struct.unpack_from('<H', sb, 56)[0]
        if magic != 0xEF53:
            raise RuntimeError(f"Not ext4: magic=0x{magic:04X} (expected 0xEF53)")

        self.s_inodes_count = struct.unpack_from('<I', sb, 0)[0]
        self.s_blocks_count_lo = struct.unpack_from('<I', sb, 4)[0]
        self.s_free_blocks_lo = struct.unpack_from('<I', sb, 12)[0]
        self.s_free_inodes = struct.unpack_from('<I', sb, 16)[0]
        self.s_first_data_block = struct.unpack_from('<I', sb, 20)[0]
        self.s_log_block_size = struct.unpack_from('<I', sb, 24)[0]
        self.block_size = 1024 << self.s_log_block_size
        self.s_blocks_per_group = struct.unpack_from('<I', sb, 32)[0]
        self.s_inodes_per_group = struct.unpack_from('<I', sb, 40)[0]
        self.s_first_ino = struct.unpack_from('<I', sb, 84)[0]
        self.s_inode_size = struct.unpack_from('<H', sb, 88)[0]
        self.s_feature_compat = struct.unpack_from('<I', sb, 92)[0]
        self.s_feature_incompat = struct.unpack_from('<I', sb, 96)[0]
        self.s_feature_ro_compat = struct.unpack_from('<I', sb, 100)[0]
        self.s_uuid = bytes(sb[104:120])

        # Volume name (16 bytes at offset 120)
        self.s_volume_name = sb[120:136].split(b'\x00')[0].decode('utf-8', errors='replace')

        # 64-bit support
        self.is_64bit = bool(self.s_feature_incompat & INCOMPAT_64BIT)
        if self.is_64bit:
            self.s_desc_size = struct.unpack_from('<H', sb, 254)[0]
            if self.s_desc_size < 32:
                self.s_desc_size = 32
        else:
            self.s_desc_size = 32

        # Metadata checksum support
        self.has_metadata_csum = bool(self.s_feature_ro_compat & RO_COMPAT_METADATA_CSUM)
        if self.has_metadata_csum:
            if self.s_feature_incompat & INCOMPAT_CSUM_SEED:
                self.csum_seed = struct.unpack_from('<I', sb, 0x170)[0]
            else:
                self.csum_seed = crc32c_raw(self.s_uuid)
        else:
            self.csum_seed = 0

        # Extra inode size
        if self.s_inode_size > EXT4_GOOD_OLD_INODE_SIZE:
            self.s_want_extra_isize = struct.unpack_from('<H', sb, 274)[0]
            if self.s_want_extra_isize == 0:
                self.s_want_extra_isize = 32
        else:
            self.s_want_extra_isize = 0

        # Number of block groups
        self.num_groups = (self.s_blocks_count_lo + self.s_blocks_per_group - 1) // self.s_blocks_per_group

        # GDT start block
        if self.block_size == 1024:
            self.gdt_block = 2
        else:
            self.gdt_block = 1

    def _write_superblock(self):
        """Write superblock back to disk."""
        self._write_bytes(1024, bytes(self._sb_raw))

    def _update_sb_free_inodes(self, delta: int):
        """Update superblock free inode count."""
        self.s_free_inodes += delta
        struct.pack_into('<I', self._sb_raw, 16, self.s_free_inodes)
        self._write_superblock()

    def _update_sb_free_blocks(self, delta: int):
        """Update superblock free block count."""
        self.s_free_blocks_lo += delta
        struct.pack_into('<I', self._sb_raw, 12, self.s_free_blocks_lo)
        self._write_superblock()

    # ─── Checksums ───

    def _inode_csum_seed(self, inode_num: int, generation: int) -> int:
        """Compute per-inode checksum seed."""
        seed = crc32c_raw(struct.pack('<I', inode_num), self.csum_seed)
        seed = crc32c_raw(struct.pack('<I', generation), seed)
        return seed

    def _compute_gd_checksum(self, group: int, raw: bytearray) -> int:
        """Compute group descriptor checksum (metadata_csum)."""
        if not self.has_metadata_csum:
            return 0
        GD_CSUM_OFFSET = 30
        crc = crc32c_raw(struct.pack('<I', group), self.csum_seed)
        crc = crc32c_raw(bytes(raw[:GD_CSUM_OFFSET]), crc)
        crc = crc32c_raw(b'\x00\x00', crc)  # zeroed checksum field
        if self.s_desc_size > GD_CSUM_OFFSET + 2:
            crc = crc32c_raw(bytes(raw[GD_CSUM_OFFSET + 2:self.s_desc_size]), crc)
        return crc & 0xFFFF

    def _compute_inode_checksum(self, inode_num: int, raw: bytes) -> int:
        """Compute inode checksum (metadata_csum). Returns full 32-bit CRC."""
        if not self.has_metadata_csum:
            return 0
        generation = struct.unpack_from('<I', raw, 100)[0]
        seed = self._inode_csum_seed(inode_num, generation)

        CSUM_LO_OFFSET = 124  # i_checksum_lo in osd2
        crc = crc32c_raw(raw[:CSUM_LO_OFFSET], seed)
        crc = crc32c_raw(b'\x00\x00', crc)
        crc = crc32c_raw(raw[CSUM_LO_OFFSET + 2:EXT4_GOOD_OLD_INODE_SIZE], crc)

        if self.s_inode_size > EXT4_GOOD_OLD_INODE_SIZE:
            CSUM_HI_OFFSET = 130  # i_checksum_hi (offset 2 in extra area)
            crc = crc32c_raw(raw[EXT4_GOOD_OLD_INODE_SIZE:CSUM_HI_OFFSET], crc)
            if self.s_inode_size > CSUM_HI_OFFSET + 2:
                crc = crc32c_raw(b'\x00\x00', crc)
                crc = crc32c_raw(raw[CSUM_HI_OFFSET + 2:self.s_inode_size], crc)

        return crc

    def _compute_dirblock_checksum(self, inode_num: int, generation: int,
                                    block_data: bytes) -> int:
        """Compute directory block checksum (metadata_csum)."""
        if not self.has_metadata_csum:
            return 0
        seed = self._inode_csum_seed(inode_num, generation)
        # Checksum covers block data minus the 12-byte tail
        crc = crc32c_raw(block_data[:self.block_size - 12], seed)
        return crc

    def _compute_bitmap_checksum(self, bitmap_data: bytes, count_bits: int) -> int:
        """Compute bitmap checksum (metadata_csum)."""
        if not self.has_metadata_csum:
            return 0
        nbytes = (count_bits + 7) // 8
        crc = crc32c_raw(bitmap_data[:nbytes], self.csum_seed)
        return crc

    # ─── Group Descriptors ───

    def _gd_offset(self, group: int) -> int:
        """Byte offset of group descriptor within partition."""
        return self.gdt_block * self.block_size + group * self.s_desc_size

    def _read_group_desc(self, group: int) -> dict:
        """Read and parse block group descriptor."""
        offset = self._gd_offset(group)
        raw = self._read_bytes(offset, self.s_desc_size)

        gd = {'_raw': bytearray(raw)}
        gd['bg_block_bitmap_lo'] = struct.unpack_from('<I', raw, 0)[0]
        gd['bg_inode_bitmap_lo'] = struct.unpack_from('<I', raw, 4)[0]
        gd['bg_inode_table_lo'] = struct.unpack_from('<I', raw, 8)[0]
        gd['bg_free_blocks_lo'] = struct.unpack_from('<H', raw, 12)[0]
        gd['bg_free_inodes_lo'] = struct.unpack_from('<H', raw, 14)[0]
        gd['bg_used_dirs_lo'] = struct.unpack_from('<H', raw, 16)[0]

        if self.is_64bit and self.s_desc_size >= 64:
            hi_bb = struct.unpack_from('<I', raw, 32)[0]
            hi_ib = struct.unpack_from('<I', raw, 36)[0]
            hi_it = struct.unpack_from('<I', raw, 40)[0]
            gd['inode_table'] = gd['bg_inode_table_lo'] | (hi_it << 32)
            gd['inode_bitmap'] = gd['bg_inode_bitmap_lo'] | (hi_ib << 32)
            gd['block_bitmap'] = gd['bg_block_bitmap_lo'] | (hi_bb << 32)
        else:
            gd['inode_table'] = gd['bg_inode_table_lo']
            gd['inode_bitmap'] = gd['bg_inode_bitmap_lo']
            gd['block_bitmap'] = gd['bg_block_bitmap_lo']

        return gd

    def _write_group_desc(self, group: int, gd: dict):
        """Write group descriptor with checksum update."""
        raw = gd['_raw']
        struct.pack_into('<H', raw, 12, gd['bg_free_blocks_lo'])
        struct.pack_into('<H', raw, 14, gd['bg_free_inodes_lo'])
        struct.pack_into('<H', raw, 16, gd['bg_used_dirs_lo'])

        if self.has_metadata_csum:
            struct.pack_into('<H', raw, 30, 0)  # zero checksum before computing
            csum = self._compute_gd_checksum(group, raw)
            struct.pack_into('<H', raw, 30, csum)

        self._write_bytes(self._gd_offset(group), bytes(raw))

    # ─── Inodes ───

    def _inode_offset(self, inode_num: int) -> tuple:
        """Return (group, index, byte_offset) for an inode."""
        group = (inode_num - 1) // self.s_inodes_per_group
        index = (inode_num - 1) % self.s_inodes_per_group
        gd = self._read_group_desc(group)
        offset = gd['inode_table'] * self.block_size + index * self.s_inode_size
        return group, index, offset

    def _read_inode(self, inode_num: int) -> dict:
        """Read an inode by number (1-based)."""
        _, _, offset = self._inode_offset(inode_num)
        raw = self._read_bytes(offset, self.s_inode_size)

        inode = {}
        inode['i_mode'] = struct.unpack_from('<H', raw, 0)[0]
        inode['i_uid'] = struct.unpack_from('<H', raw, 2)[0]
        inode['i_size_lo'] = struct.unpack_from('<I', raw, 4)[0]
        inode['i_atime'] = struct.unpack_from('<I', raw, 8)[0]
        inode['i_ctime'] = struct.unpack_from('<I', raw, 12)[0]
        inode['i_mtime'] = struct.unpack_from('<I', raw, 16)[0]
        inode['i_dtime'] = struct.unpack_from('<I', raw, 20)[0]
        inode['i_gid'] = struct.unpack_from('<H', raw, 24)[0]
        inode['i_links_count'] = struct.unpack_from('<H', raw, 26)[0]
        inode['i_blocks_lo'] = struct.unpack_from('<I', raw, 28)[0]
        inode['i_flags'] = struct.unpack_from('<I', raw, 32)[0]
        inode['i_generation'] = struct.unpack_from('<I', raw, 100)[0]
        inode['i_block'] = raw[40:100]  # 60 bytes

        # Size for large files
        if self.s_feature_ro_compat & RO_COMPAT_LARGE_FILE:
            hi = struct.unpack_from('<I', raw, 108)[0]
            inode['i_size'] = inode['i_size_lo'] | (hi << 32)
        else:
            inode['i_size'] = inode['i_size_lo']

        inode['_raw'] = bytes(raw)
        inode['_num'] = inode_num
        return inode

    def _write_inode_raw(self, inode_num: int, data: bytes):
        """Write raw inode data with checksum computation."""
        data = bytearray(data)

        if self.has_metadata_csum:
            crc = self._compute_inode_checksum(inode_num, bytes(data))
            struct.pack_into('<H', data, 124, crc & 0xFFFF)  # i_checksum_lo
            if self.s_inode_size > 130:
                struct.pack_into('<H', data, 130, (crc >> 16) & 0xFFFF)  # i_checksum_hi

        _, _, offset = self._inode_offset(inode_num)
        self._write_bytes(offset, bytes(data))

    # ─── Extent Tree ───

    def _get_data_blocks(self, inode: dict) -> list:
        """Get list of (logical_block, physical_block, count) from inode.
        Works for both extent-based and legacy block-pointer inodes."""
        if inode['i_flags'] & EXT4_EXTENTS_FL:
            result = self._parse_extent_tree(inode['i_block'])
            if not result:
                # Extent magic may be corrupted on eMMC — force-parse
                result = self._parse_extent_tree(inode['i_block'], force=True)
            return result

        # Legacy block pointers (i_block[0..11] = direct, [12]=indirect, etc.)
        blocks = []
        for i in range(12):
            blk = struct.unpack_from('<I', inode['i_block'], i * 4)[0]
            if blk:
                blocks.append((i, blk, 1))
        # Indirect blocks not implemented (rare in ext4)
        return blocks

    def _parse_extent_tree(self, data: bytes, force: bool = False) -> list:
        """Parse ext4 extent tree (recursive for depth > 0).
        If force=True, parse despite invalid magic (for corrupted eMMC)."""
        if len(data) < 12:
            return []
        magic = struct.unpack_from('<H', data, 0)[0]
        if magic != EXT4_EXT_MAGIC:
            if not force:
                return []
            # Force-parse: magic corrupted but caller knows this is an extent inode

        entries = struct.unpack_from('<H', data, 2)[0]
        depth = struct.unpack_from('<H', data, 6)[0]
        result = []

        if depth == 0:
            for i in range(entries):
                off = 12 + i * 12
                if off + 12 > len(data):
                    break
                ee_block = struct.unpack_from('<I', data, off)[0]
                ee_len = struct.unpack_from('<H', data, off + 4)[0]
                ee_start_hi = struct.unpack_from('<H', data, off + 6)[0]
                ee_start_lo = struct.unpack_from('<I', data, off + 8)[0]
                phys = ee_start_lo | (ee_start_hi << 32)
                length = ee_len & 0x7FFF
                result.append((ee_block, phys, length))
        else:
            for i in range(entries):
                off = 12 + i * 12
                if off + 12 > len(data):
                    break
                ei_leaf_lo = struct.unpack_from('<I', data, off + 4)[0]
                ei_leaf_hi = struct.unpack_from('<H', data, off + 8)[0]
                child_block = ei_leaf_lo | (ei_leaf_hi << 32)
                child_data = self._read_block(child_block)
                result.extend(self._parse_extent_tree(child_data))

        return result

    # ─── File Data I/O ───

    def read_file_data(self, inode: dict, max_size: int = None) -> bytes:
        """Read file data from inode."""
        size = inode['i_size']
        if max_size and size > max_size:
            size = max_size
        if size == 0:
            return b''

        extents = self._get_data_blocks(inode)
        data = b''
        remaining = size

        for logical, physical, length in sorted(extents):
            for i in range(length):
                if remaining <= 0:
                    break
                block_data = self._read_block(physical + i)
                to_read = min(remaining, self.block_size)
                data += block_data[:to_read]
                remaining -= to_read
            if remaining <= 0:
                break

        return data[:size]

    def overwrite_file_data(self, inode: dict, new_data: bytes):
        """Overwrite existing file's data blocks (must fit in existing allocation)."""
        extents = self._get_data_blocks(inode)
        if not extents and len(new_data) > 0:
            raise RuntimeError("File has no data blocks — cannot overwrite")

        # Calculate total allocated space
        total_blocks = sum(count for _, _, count in extents)
        total_space = total_blocks * self.block_size
        if len(new_data) > total_space:
            raise RuntimeError(
                f"New data ({len(new_data)}B) exceeds allocated space ({total_space}B)")

        remaining = len(new_data)
        offset = 0

        for logical, physical, length in sorted(extents):
            for i in range(length):
                if remaining <= 0:
                    break
                to_write = min(remaining, self.block_size)
                if to_write < self.block_size:
                    # Partial block — pad with zeros
                    block_data = new_data[offset:offset + to_write]
                    block_data += b'\x00' * (self.block_size - to_write)
                else:
                    block_data = new_data[offset:offset + self.block_size]
                self._write_block(physical + i, block_data)
                remaining -= to_write
                offset += to_write

        # Update inode size and timestamps
        inode_raw = bytearray(inode['_raw'])
        struct.pack_into('<I', inode_raw, 4, len(new_data) & 0xFFFFFFFF)
        if self.s_feature_ro_compat & RO_COMPAT_LARGE_FILE:
            struct.pack_into('<I', inode_raw, 108, (len(new_data) >> 32) & 0xFFFFFFFF)
        now = int(time.time())
        struct.pack_into('<I', inode_raw, 12, now)  # i_ctime
        struct.pack_into('<I', inode_raw, 16, now)  # i_mtime
        self._write_inode_raw(inode['_num'], bytes(inode_raw))

    # ─── Directory Operations ───

    def _read_dir_entries(self, inode: dict) -> list:
        """Read directory entries from a directory inode.
        Recovers from corrupted rec_len values (bitrot on eMMC)."""
        data = self.read_file_data(inode)
        entries = []
        pos = 0

        while pos < len(data):
            if pos + 8 > len(data):
                break
            d_inode = struct.unpack_from('<I', data, pos)[0]
            d_rec_len = struct.unpack_from('<H', data, pos + 4)[0]
            d_name_len = data[pos + 6]
            d_file_type = data[pos + 7]

            if d_rec_len == 0:
                break

            # Recover corrupted rec_len: if smaller than minimum for this entry,
            # use the minimum (bitrot can flip bits to smaller values)
            min_rec_len = align4(8 + d_name_len)
            effective_rec_len = d_rec_len
            if d_inode != 0 and d_name_len > 0 and d_rec_len < min_rec_len:
                effective_rec_len = min_rec_len

            if pos + effective_rec_len > len(data):
                break

            if d_inode != 0 and d_name_len > 0:
                name = data[pos + 8:pos + 8 + d_name_len].decode('utf-8', errors='replace')
                # Skip tail entries (metadata_csum: file_type == 0xDE, inode == 0)
                if d_file_type != 0xDE:
                    entries.append({
                        'inode': d_inode,
                        'name': name,
                        'file_type': d_file_type,
                        'rec_len': effective_rec_len,
                        '_offset': pos,
                    })

            pos += effective_rec_len

        return entries

    def _add_dir_entry(self, parent_inode_num: int, child_inode_num: int,
                        name: str, file_type: int = FT_REG_FILE):
        """Add a directory entry to parent directory."""
        parent = self._read_inode(parent_inode_num)
        if (parent['i_mode'] & S_IFMT) != S_IFDIR:
            raise RuntimeError("Parent is not a directory")

        name_bytes = name.encode('utf-8')
        needed = align4(8 + len(name_bytes))

        # Determine if directory blocks have a tail entry (metadata_csum)
        has_tail = self.has_metadata_csum
        usable_size = self.block_size - (12 if has_tail else 0)

        # Read all directory data blocks
        extents = self._get_data_blocks(parent)
        dir_data = self.read_file_data(parent)

        # Try to find space in existing blocks
        for logical, physical, count in sorted(extents):
            for bi in range(count):
                block_start = (logical + bi) * self.block_size
                block_end = block_start + usable_size

                if block_start >= len(dir_data):
                    break

                # Scan entries in this block to find the last one
                pos = block_start
                last_entry_pos = None
                while pos < block_end and pos < len(dir_data):
                    if pos + 8 > len(dir_data):
                        break
                    d_rec_len = struct.unpack_from('<H', dir_data, pos + 4)[0]
                    if d_rec_len == 0:
                        break
                    last_entry_pos = pos
                    next_pos = pos + d_rec_len
                    if next_pos >= block_end:
                        break
                    pos = next_pos

                if last_entry_pos is None:
                    continue

                # Check if last entry has enough slack space
                last_inode = struct.unpack_from('<I', dir_data, last_entry_pos)[0]
                last_rec_len = struct.unpack_from('<H', dir_data, last_entry_pos + 4)[0]
                last_name_len = dir_data[last_entry_pos + 6]

                if last_inode != 0:
                    last_actual = align4(8 + last_name_len)
                else:
                    last_actual = 0  # Empty entry, all space is free

                free_space = last_rec_len - last_actual
                if free_space < needed:
                    continue

                # Found space! Modify block data
                block = bytearray(self._read_block(physical + bi))
                block_offset = last_entry_pos - block_start

                if last_inode != 0:
                    # Shrink existing entry
                    struct.pack_into('<H', block, block_offset + 4, last_actual)

                    # Write new entry after it
                    new_offset = block_offset + last_actual
                    new_rec_len = last_rec_len - last_actual
                    struct.pack_into('<I', block, new_offset, child_inode_num)
                    struct.pack_into('<H', block, new_offset + 4, new_rec_len)
                    block[new_offset + 6] = len(name_bytes)
                    block[new_offset + 7] = file_type
                    block[new_offset + 8:new_offset + 8 + len(name_bytes)] = name_bytes
                else:
                    # Reuse empty entry
                    struct.pack_into('<I', block, block_offset, child_inode_num)
                    # rec_len stays the same
                    block[block_offset + 6] = len(name_bytes)
                    block[block_offset + 7] = file_type
                    block[block_offset + 8:block_offset + 8 + len(name_bytes)] = name_bytes

                # Update directory block checksum tail
                if has_tail:
                    tail_offset = self.block_size - 12
                    crc = self._compute_dirblock_checksum(
                        parent_inode_num, parent['i_generation'], bytes(block))
                    struct.pack_into('<I', block, tail_offset, 0)       # det_reserved_zero1
                    struct.pack_into('<H', block, tail_offset + 4, 12)  # det_rec_len
                    block[tail_offset + 6] = 0   # det_reserved_zero2
                    block[tail_offset + 7] = 0xDE  # det_reserved_ft
                    struct.pack_into('<I', block, tail_offset + 8, crc)

                self._write_block(physical + bi, bytes(block))

                # Update parent directory mtime
                parent_raw = bytearray(parent['_raw'])
                now = int(time.time())
                struct.pack_into('<I', parent_raw, 12, now)  # i_ctime
                struct.pack_into('<I', parent_raw, 16, now)  # i_mtime
                self._write_inode_raw(parent_inode_num, bytes(parent_raw))

                return

        raise RuntimeError("No free space in directory — block allocation not implemented")

    def rename_entry(self, parent_inode_num: int, old_name: str, new_name: str):
        """Rename a directory entry (same-length names only).

        Overwrites d_name bytes in-place without changing rec_len/name_len.
        Updates metadata_csum tail if present.

        Args:
            parent_inode_num: inode number of the parent directory
            old_name: existing entry name to rename
            new_name: new name (must be same length as old_name)
        """
        old_bytes = old_name.encode('utf-8')
        new_bytes = new_name.encode('utf-8')
        if len(old_bytes) != len(new_bytes):
            raise ValueError(
                f"rename_entry: names must be same length "
                f"(old={len(old_bytes)}, new={len(new_bytes)})")

        parent = self._read_inode(parent_inode_num)
        if (parent['i_mode'] & S_IFMT) != S_IFDIR:
            raise RuntimeError("Parent is not a directory")

        extents = self._get_data_blocks(parent)
        has_tail = self.has_metadata_csum

        for logical, physical, count in sorted(extents):
            for bi in range(count):
                block = bytearray(self._read_block(physical + bi))
                pos = 0
                found = False

                while pos < len(block):
                    if pos + 8 > len(block):
                        break
                    d_inode = struct.unpack_from('<I', block, pos)[0]
                    d_rec_len = struct.unpack_from('<H', block, pos + 4)[0]
                    d_name_len = block[pos + 6]
                    d_file_type = block[pos + 7]

                    if d_rec_len == 0:
                        break

                    if (d_inode != 0 and d_name_len == len(old_bytes)
                            and d_file_type != 0xDE
                            and block[pos + 8:pos + 8 + d_name_len] == old_bytes):
                        # Found — overwrite name bytes
                        block[pos + 8:pos + 8 + d_name_len] = new_bytes
                        found = True
                        break

                    pos += d_rec_len

                if found:
                    # Update checksum tail if needed
                    if has_tail:
                        tail_offset = self.block_size - 12
                        crc = self._compute_dirblock_checksum(
                            parent_inode_num, parent['i_generation'], bytes(block))
                        struct.pack_into('<I', block, tail_offset, 0)
                        struct.pack_into('<H', block, tail_offset + 4, 12)
                        block[tail_offset + 6] = 0
                        block[tail_offset + 7] = 0xDE
                        struct.pack_into('<I', block, tail_offset + 8, crc)

                    self._write_block(physical + bi, bytes(block))
                    return

        raise FileNotFoundError(f"Directory entry '{old_name}' not found")

    # ─── Allocation ───

    def _alloc_inode(self, preferred_group: int = 0) -> int:
        """Allocate a free inode. Returns inode number (1-based)."""
        for g_offset in range(self.num_groups):
            group = (preferred_group + g_offset) % self.num_groups
            gd = self._read_group_desc(group)
            if gd['bg_free_inodes_lo'] == 0:
                continue

            bitmap_block = gd['inode_bitmap']
            bitmap = bytearray(self._read_block(bitmap_block))

            # Skip reserved inodes in group 0
            start_bit = 0
            if group == 0:
                start_bit = self.s_first_ino  # First usable inode (typically 11)

            for byte_idx in range(start_bit // 8, (self.s_inodes_per_group + 7) // 8):
                if bitmap[byte_idx] == 0xFF:
                    continue
                for bit_idx in range(8):
                    abs_bit = byte_idx * 8 + bit_idx
                    if abs_bit < start_bit:
                        continue
                    if abs_bit >= self.s_inodes_per_group:
                        break
                    if not (bitmap[byte_idx] & (1 << bit_idx)):
                        # Found free inode
                        bitmap[byte_idx] |= (1 << bit_idx)
                        self._write_block(bitmap_block, bytes(bitmap))

                        # Update bitmap checksum in GD
                        if self.has_metadata_csum:
                            bcsum = self._compute_bitmap_checksum(
                                bytes(bitmap), self.s_inodes_per_group)
                            struct.pack_into('<H', gd['_raw'], 26, bcsum & 0xFFFF)
                            if self.s_desc_size >= 60:
                                struct.pack_into('<H', gd['_raw'], 58, (bcsum >> 16) & 0xFFFF)

                        # Update free count
                        gd['bg_free_inodes_lo'] -= 1
                        self._write_group_desc(group, gd)

                        # Update superblock
                        self._update_sb_free_inodes(-1)

                        inode_num = group * self.s_inodes_per_group + abs_bit + 1
                        return inode_num

        raise RuntimeError("No free inodes on filesystem")

    def _alloc_block(self, preferred_group: int = 0) -> int:
        """Allocate a free data block. Returns block number."""
        for g_offset in range(self.num_groups):
            group = (preferred_group + g_offset) % self.num_groups
            gd = self._read_group_desc(group)
            if gd['bg_free_blocks_lo'] == 0:
                continue

            bitmap_block = gd['block_bitmap']
            bitmap = bytearray(self._read_block(bitmap_block))

            for byte_idx in range(len(bitmap)):
                if bitmap[byte_idx] == 0xFF:
                    continue
                for bit_idx in range(8):
                    abs_bit = byte_idx * 8 + bit_idx
                    if abs_bit >= self.s_blocks_per_group:
                        break
                    if not (bitmap[byte_idx] & (1 << bit_idx)):
                        bitmap[byte_idx] |= (1 << bit_idx)
                        self._write_block(bitmap_block, bytes(bitmap))

                        # Update bitmap checksum in GD
                        if self.has_metadata_csum:
                            bcsum = self._compute_bitmap_checksum(
                                bytes(bitmap), self.s_blocks_per_group)
                            struct.pack_into('<H', gd['_raw'], 24, bcsum & 0xFFFF)
                            if self.s_desc_size >= 58:
                                struct.pack_into('<H', gd['_raw'], 56, (bcsum >> 16) & 0xFFFF)

                        gd['bg_free_blocks_lo'] -= 1
                        self._write_group_desc(group, gd)
                        self._update_sb_free_blocks(-1)

                        block_num = group * self.s_blocks_per_group + abs_bit
                        block_num += self.s_first_data_block
                        return block_num

        raise RuntimeError("No free blocks on filesystem")

    # ─── File Creation ───

    def _init_new_inode(self, inode_num: int, mode: int, size: int,
                         data_block: int = None, uid: int = 0, gid: int = 0) -> bytes:
        """Create raw inode data for a new file."""
        raw = bytearray(self.s_inode_size)
        now = int(time.time())

        struct.pack_into('<H', raw, 0, mode)          # i_mode
        struct.pack_into('<H', raw, 2, uid & 0xFFFF)  # i_uid
        struct.pack_into('<I', raw, 4, size)           # i_size_lo
        struct.pack_into('<I', raw, 8, now)            # i_atime
        struct.pack_into('<I', raw, 12, now)           # i_ctime
        struct.pack_into('<I', raw, 16, now)           # i_mtime
        struct.pack_into('<I', raw, 20, 0)             # i_dtime
        struct.pack_into('<H', raw, 24, gid & 0xFFFF) # i_gid
        struct.pack_into('<H', raw, 26, 1)             # i_links_count

        if data_block:
            # i_blocks_lo: count of 512-byte blocks
            struct.pack_into('<I', raw, 28, self.block_size // 512)

        # i_flags
        use_extents = bool(self.s_feature_incompat & INCOMPAT_EXTENTS)
        flags = EXT4_EXTENTS_FL if use_extents else 0
        struct.pack_into('<I', raw, 32, flags)

        # i_generation: use inode_num as simple generation seed
        struct.pack_into('<I', raw, 100, inode_num)

        # i_block area (60 bytes at offset 40)
        if use_extents:
            # Extent header
            struct.pack_into('<H', raw, 40, EXT4_EXT_MAGIC)  # eh_magic
            if data_block:
                struct.pack_into('<H', raw, 42, 1)  # eh_entries = 1
            else:
                struct.pack_into('<H', raw, 42, 0)  # eh_entries = 0
            struct.pack_into('<H', raw, 44, 4)      # eh_max
            struct.pack_into('<H', raw, 46, 0)      # eh_depth = 0

            if data_block:
                # Extent entry at offset 52
                struct.pack_into('<I', raw, 52, 0)    # ee_block = 0
                struct.pack_into('<H', raw, 56, 1)    # ee_len = 1
                struct.pack_into('<H', raw, 58, (data_block >> 32) & 0xFFFF)
                struct.pack_into('<I', raw, 60, data_block & 0xFFFFFFFF)
        elif data_block:
            # Legacy block pointer
            struct.pack_into('<I', raw, 40, data_block)

        # Extra inode size (offset 128)
        if self.s_inode_size > EXT4_GOOD_OLD_INODE_SIZE:
            struct.pack_into('<H', raw, 128, self.s_want_extra_isize)

        return bytes(raw)

    def create_file(self, parent_path: str, filename: str, data: bytes = b'',
                    mode: int = 0o100644, uid: int = 0, gid: int = 0) -> int:
        """Create a new file. Returns the new inode number.

        Args:
            parent_path: directory path (e.g. '/')
            filename: name of the new file
            data: file content (empty for zero-length file)
            mode: inode mode (default: regular file 0644)
            uid/gid: owner
        """
        # Check parent exists and is a directory
        parent = self.lookup(parent_path)
        if (parent['i_mode'] & S_IFMT) != S_IFDIR:
            raise RuntimeError(f"{parent_path} is not a directory")

        # Check file doesn't already exist
        entries = self._read_dir_entries(parent)
        for e in entries:
            if e['name'] == filename:
                raise FileExistsError(f"'{filename}' already exists in {parent_path}")

        # Determine group (same as parent for locality)
        parent_group = (parent['_num'] - 1) // self.s_inodes_per_group

        # Allocate inode
        new_ino = self._alloc_inode(preferred_group=parent_group)

        # Allocate data block if needed
        data_block = None
        if data:
            if len(data) > self.block_size:
                raise RuntimeError(
                    f"File data ({len(data)}B) exceeds single block ({self.block_size}B) — "
                    "multi-block create not implemented")
            data_block = self._alloc_block(preferred_group=parent_group)

        # Initialize and write inode
        inode_raw = self._init_new_inode(new_ino, mode, len(data), data_block, uid, gid)
        self._write_inode_raw(new_ino, inode_raw)

        # Write file data
        if data and data_block:
            block_data = data + b'\x00' * (self.block_size - len(data))
            self._write_block(data_block, block_data)

        # Add directory entry
        self._add_dir_entry(parent['_num'], new_ino, filename, FT_REG_FILE)

        return new_ino

    # ─── High-level API ───

    def info(self) -> dict:
        """Return filesystem information."""
        return {
            'block_size': self.block_size,
            'block_count': self.s_blocks_count_lo,
            'free_blocks': self.s_free_blocks_lo,
            'inode_count': self.s_inodes_count,
            'free_inodes': self.s_free_inodes,
            'inode_size': self.s_inode_size,
            'inodes_per_group': self.s_inodes_per_group,
            'blocks_per_group': self.s_blocks_per_group,
            'num_groups': self.num_groups,
            'first_inode': self.s_first_ino,
            'volume_name': self.s_volume_name,
            'uuid': '-'.join([
                self.s_uuid[0:4].hex(), self.s_uuid[4:6].hex(),
                self.s_uuid[6:8].hex(), self.s_uuid[8:10].hex(),
                self.s_uuid[10:16].hex()
            ]),
            '64bit': self.is_64bit,
            'metadata_csum': self.has_metadata_csum,
            'has_extents': bool(self.s_feature_incompat & INCOMPAT_EXTENTS),
            'has_journal': bool(self.s_feature_compat & COMPAT_HAS_JOURNAL),
            'desc_size': self.s_desc_size,
        }

    def lookup(self, path: str) -> dict:
        """Look up a file/directory by path. Returns inode dict."""
        parts = [p for p in path.strip('/').split('/') if p]
        current = self._read_inode(2)  # root inode

        for part in parts:
            if (current['i_mode'] & S_IFMT) != S_IFDIR:
                raise FileNotFoundError(f"Not a directory in path: {path}")
            entries = self._read_dir_entries(current)
            found = False
            for e in entries:
                if e['name'] == part:
                    current = self._read_inode(e['inode'])
                    found = True
                    break
            if not found:
                raise FileNotFoundError(f"Not found: '{part}' in {path}")

        return current

    def ls(self, path: str = '/') -> list:
        """List directory contents. Returns list of dicts with name, inode, type."""
        inode = self.lookup(path)
        if (inode['i_mode'] & S_IFMT) != S_IFDIR:
            raise RuntimeError(f"{path} is not a directory")
        return self._read_dir_entries(inode)

    def cat(self, path: str) -> bytes:
        """Read file contents."""
        inode = self.lookup(path)
        if (inode['i_mode'] & S_IFMT) == S_IFDIR:
            raise RuntimeError(f"{path} is a directory")
        return self.read_file_data(inode)

    def write(self, path: str, data: bytes):
        """Overwrite an existing file's data."""
        inode = self.lookup(path)
        if (inode['i_mode'] & S_IFMT) == S_IFDIR:
            raise RuntimeError(f"{path} is a directory")
        self.overwrite_file_data(inode, data)

    def exists(self, path: str) -> bool:
        """Check if a path exists."""
        try:
            self.lookup(path)
            return True
        except FileNotFoundError:
            return False

    def file_type_name(self, ft: int) -> str:
        """Human-readable name for directory entry file_type."""
        names = {0: '?', 1: 'f', 2: 'd', 3: 'c', 4: 'b', 5: 'p', 6: 's', 7: 'l'}
        return names.get(ft, '?')
