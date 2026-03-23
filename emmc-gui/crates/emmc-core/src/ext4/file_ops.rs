use super::checksum;
use super::directory;
use super::inode::{self, Extent, ExtentNodeContents, Inode};
use super::{Ext4DirEntry, Ext4Fs};
use anyhow::{bail, Result};

impl<'a> Ext4Fs<'a> {
    /// Read inode by number
    pub fn read_inode(&mut self, ino: u32) -> Result<Inode> {
        let group = ((ino - 1) / self.sb.inodes_per_group) as usize;
        let index = ((ino - 1) % self.sb.inodes_per_group) as usize;

        if group >= self.group_descs.len() {
            bail!("Inode {} group {} out of range", ino, group);
        }

        let inode_table_block = self.group_descs[group].inode_table;
        let inode_offset = index * self.sb.inode_size as usize;
        let block_offset = inode_offset / self.sb.block_size as usize;
        let offset_in_block = inode_offset % self.sb.block_size as usize;

        let block_data = self.read_block(inode_table_block + block_offset as u64)?;
        let end = (offset_in_block + self.sb.inode_size as usize).min(block_data.len());
        let inode = inode::parse_inode(&block_data[offset_in_block..end], ino, self.sb.inode_size)?;

        if self.sb.metadata_csum && inode.raw.len() >= 128 {
            let computed = checksum::inode_checksum(
                self.sb.csum_seed,
                ino,
                inode.i_generation,
                &inode.raw,
                self.sb.inode_size,
            );
            let stored_lo = u16::from_le_bytes(inode.raw[124..126].try_into().unwrap()) as u32;
            let stored = if self.sb.inode_size > 128 && inode.raw.len() > 132 {
                stored_lo
                    | ((u16::from_le_bytes(inode.raw[130..132].try_into().unwrap()) as u32) << 16)
            } else {
                stored_lo
            };
            if stored != computed {
                tracing::warn!(
                    "Inode {} checksum mismatch: stored=0x{:08x}, computed=0x{:08x}",
                    ino,
                    stored,
                    computed
                );
            }
        }

        Ok(inode)
    }

    /// Get data block numbers for an inode using extent tree.
    /// Handles multi-level extent trees (depth > 0) by reading index nodes from disk.
    /// Retries read from eMMC if extent magic is corrupted (breadboard CRC noise).
    /// Falls back to force-parsing when extent magic is corrupted but EXT4_EXTENTS_FL is set.
    pub fn get_extents(&mut self, inode: &Inode) -> Result<Vec<Extent>> {
        if !inode.has_extents() {
            bail!("Inode does not use extent trees (legacy block pointers not supported)");
        }

        // Parse the root node from inode's i_block
        let root = inode::parse_extent_node(&inode.i_block)?;
        match root {
            ExtentNodeContents::Leaves(extents) if !extents.is_empty() => {
                return Ok(extents);
            }
            ExtentNodeContents::Indices(indices) => {
                return self.resolve_extent_indices(&indices);
            }
            _ => {}
        }

        // Empty result — retry with fresh reads from eMMC
        for retry in 0..3 {
            tracing::info!("Retrying inode {} read (attempt {})", inode.ino, retry + 1);
            match self.read_inode(inode.ino) {
                Ok(fresh_inode) => {
                    let retried = inode::parse_extent_node(&fresh_inode.i_block)?;
                    match retried {
                        ExtentNodeContents::Leaves(extents) if !extents.is_empty() => {
                            return Ok(extents);
                        }
                        ExtentNodeContents::Indices(indices) => {
                            return self.resolve_extent_indices(&indices);
                        }
                        _ => {}
                    }
                }
                Err(e) => {
                    tracing::warn!("Inode {} re-read failed: {}", inode.ino, e);
                }
            }
        }

        // All retries failed with normal parsing. If inode has EXT4_EXTENTS_FL,
        // force-parse despite corrupted magic — the extent data may still be valid
        // even if magic bytes were corrupted (common on breadboard eMMC setups).
        tracing::warn!(
            "Inode {} extent magic corrupted after retries, force-parsing",
            inode.ino
        );
        let forced = inode::parse_extent_node_force(&inode.i_block)?;
        match forced {
            ExtentNodeContents::Leaves(extents) if !extents.is_empty() => Ok(extents),
            ExtentNodeContents::Indices(indices) => self.resolve_extent_indices(&indices),
            _ => Ok(Vec::new()),
        }
    }

    /// Recursively resolve extent index entries by reading child blocks from disk.
    /// Each child block is another extent tree node that may contain leaves or more indices.
    fn resolve_extent_indices(&mut self, indices: &[inode::ExtentIdx]) -> Result<Vec<Extent>> {
        let mut all_extents = Vec::new();
        for idx in indices {
            let child_data = self.read_block(idx.child_block)?;
            let child_node = inode::parse_extent_node(&child_data)?;
            match child_node {
                ExtentNodeContents::Leaves(extents) => {
                    all_extents.extend(extents);
                }
                ExtentNodeContents::Indices(sub_indices) => {
                    // Deeper tree level — recurse
                    let sub_extents = self.resolve_extent_indices(&sub_indices)?;
                    all_extents.extend(sub_extents);
                }
                ExtentNodeContents::Empty => {
                    tracing::warn!("Empty extent node at block {}, skipping", idx.child_block);
                }
            }
        }
        Ok(all_extents)
    }

    /// Read directory entries from an inode
    pub fn read_dir_entries(&mut self, inode: &Inode) -> Result<Vec<Ext4DirEntry>> {
        let extents = self.get_extents(inode)?;
        let mut entries = Vec::new();

        for ext in &extents {
            for i in 0..ext.length as u64 {
                let block_data = self.read_block(ext.physical_block + i)?;

                if self.sb.metadata_csum {
                    let tail_offset = self.sb.block_size as usize - 12;
                    if block_data.len() >= tail_offset + 12 && block_data[tail_offset + 7] == 0xDE {
                        let stored = u32::from_le_bytes(
                            block_data[tail_offset + 8..tail_offset + 12]
                                .try_into()
                                .unwrap(),
                        );
                        let computed = checksum::dir_block_checksum(
                            self.sb.csum_seed,
                            inode.ino,
                            inode.i_generation,
                            &block_data,
                            self.sb.block_size,
                        );
                        if stored != computed {
                            tracing::warn!(
                                "Dir block {} checksum mismatch (inode {}): stored=0x{:08x}, computed=0x{:08x}",
                                ext.physical_block + i, inode.ino, stored, computed
                            );
                        }
                    }
                }

                let dir_entries = directory::parse_dir_entries(&block_data, self.sb.block_size);
                entries.extend(dir_entries);
            }
        }

        Ok(entries)
    }

    /// Read file data from an inode
    pub fn read_file_data(&mut self, inode: &Inode) -> Result<Vec<u8>> {
        let extents = self.get_extents(inode)?;
        let file_size = inode.i_size as usize;
        let mut data = Vec::with_capacity(file_size);

        for ext in &extents {
            for i in 0..ext.length as u64 {
                let block_data = self.read_block(ext.physical_block + i)?;
                data.extend_from_slice(&block_data);
                if data.len() >= file_size {
                    data.truncate(file_size);
                    return Ok(data);
                }
            }
        }

        data.truncate(file_size);
        Ok(data)
    }

    /// Overwrite file data in-place (must fit existing allocation)
    pub fn overwrite_file_data(&mut self, inode: &Inode, new_data: &[u8]) -> Result<()> {
        let extents = self.get_extents(inode)?;

        // Calculate total allocated space
        let total_blocks: u64 = extents.iter().map(|e| e.length as u64).sum();
        let total_space = total_blocks * self.sb.block_size as u64;

        if new_data.len() as u64 > total_space {
            bail!(
                "New data ({} bytes) exceeds allocated space ({} bytes)",
                new_data.len(),
                total_space
            );
        }

        // Write data block by block
        let mut written = 0usize;
        for ext in &extents {
            for i in 0..ext.length as u64 {
                if written >= new_data.len() {
                    // Zero-fill remaining blocks
                    let zeros = vec![0u8; self.sb.block_size as usize];
                    self.write_block(ext.physical_block + i, &zeros)?;
                } else {
                    let end = (written + self.sb.block_size as usize).min(new_data.len());
                    let mut block = vec![0u8; self.sb.block_size as usize];
                    block[..end - written].copy_from_slice(&new_data[written..end]);
                    self.write_block(ext.physical_block + i, &block)?;
                    written = end;
                }
            }
        }

        // Update inode size if changed
        if new_data.len() as u64 != inode.i_size {
            self.update_inode_size(inode, new_data.len() as u64)?;
        }

        Ok(())
    }

    /// Update inode size field on disk
    fn update_inode_size(&mut self, inode: &Inode, new_size: u64) -> Result<()> {
        let group = ((inode.ino - 1) / self.sb.inodes_per_group) as usize;
        let index = ((inode.ino - 1) % self.sb.inodes_per_group) as usize;
        let inode_table_block = self.group_descs[group].inode_table;
        let inode_offset = index * self.sb.inode_size as usize;
        let block_offset = inode_offset / self.sb.block_size as usize;
        let offset_in_block = inode_offset % self.sb.block_size as usize;

        let mut block_data = self.read_block(inode_table_block + block_offset as u64)?;

        // Update i_size (offset 4, 4 bytes LE)
        let size_lo = (new_size & 0xFFFFFFFF) as u32;
        block_data[offset_in_block + 4..offset_in_block + 8]
            .copy_from_slice(&size_lo.to_le_bytes());

        // Update size_hi (offset 108) for regular files
        if (inode.i_mode >> 12) & 0xF == 0x8 {
            let size_hi = (new_size >> 32) as u32;
            block_data[offset_in_block + 108..offset_in_block + 112]
                .copy_from_slice(&size_hi.to_le_bytes());
        }

        // Recompute inode checksum if metadata_csum
        if self.sb.metadata_csum {
            let inode_raw =
                &block_data[offset_in_block..offset_in_block + self.sb.inode_size as usize];
            let csum = checksum::inode_checksum(
                self.sb.csum_seed,
                inode.ino,
                inode.i_generation,
                inode_raw,
                self.sb.inode_size,
            );

            // Write checksum_lo at offset 124
            let lo = (csum & 0xFFFF) as u16;
            block_data[offset_in_block + 124..offset_in_block + 126]
                .copy_from_slice(&lo.to_le_bytes());

            // Write checksum_hi at offset 130 for large inodes
            if self.sb.inode_size > 128 {
                let hi = ((csum >> 16) & 0xFFFF) as u16;
                block_data[offset_in_block + 130..offset_in_block + 132]
                    .copy_from_slice(&hi.to_le_bytes());
            }
        }

        self.write_block(inode_table_block + block_offset as u64, &block_data)?;
        Ok(())
    }

    /// Write raw inode data to disk with checksum
    fn write_inode_raw(&mut self, ino: u32, mut inode_raw: Vec<u8>) -> Result<()> {
        // Compute inode checksum before writing
        if self.sb.metadata_csum {
            let generation = u32::from_le_bytes(inode_raw[100..104].try_into().unwrap_or([0; 4]));
            let csum = checksum::inode_checksum(
                self.sb.csum_seed,
                ino,
                generation,
                &inode_raw,
                self.sb.inode_size,
            );

            let lo = (csum & 0xFFFF) as u16;
            inode_raw[124..126].copy_from_slice(&lo.to_le_bytes());
            if self.sb.inode_size > 128 && inode_raw.len() > 132 {
                let hi = ((csum >> 16) & 0xFFFF) as u16;
                inode_raw[130..132].copy_from_slice(&hi.to_le_bytes());
            }
        }

        let group = ((ino - 1) / self.sb.inodes_per_group) as usize;
        let index = ((ino - 1) % self.sb.inodes_per_group) as usize;
        let inode_table_block = self.group_descs[group].inode_table;
        let inode_offset = index * self.sb.inode_size as usize;
        let block_offset = inode_offset / self.sb.block_size as usize;
        let offset_in_block = inode_offset % self.sb.block_size as usize;

        let mut block_data = self.read_block(inode_table_block + block_offset as u64)?;
        let end = (offset_in_block + self.sb.inode_size as usize).min(block_data.len());
        let copy_len = (end - offset_in_block).min(inode_raw.len());
        block_data[offset_in_block..offset_in_block + copy_len]
            .copy_from_slice(&inode_raw[..copy_len]);

        self.write_block(inode_table_block + block_offset as u64, &block_data)
    }

    /// Allocate a free inode from bitmap. Returns 1-based inode number.
    fn alloc_inode(&mut self, preferred_group: u32) -> Result<u32> {
        let num_groups = self.group_descs.len();
        // First usable inode: typically 11 (s_first_ino in superblock at offset 84)
        // We'll use 11 as the standard ext4 default
        let first_usable_inode = 11u32;

        for g_offset in 0..num_groups {
            let group = ((preferred_group as usize + g_offset) % num_groups) as usize;

            if self.group_descs[group].free_inodes_count == 0 {
                continue;
            }

            let bitmap_block = self.group_descs[group].inode_bitmap;
            let mut bitmap = self.read_block(bitmap_block)?;

            let start_bit = if group == 0 {
                first_usable_inode as usize
            } else {
                0
            };

            let max_bits = self.sb.inodes_per_group as usize;

            for byte_idx in start_bit / 8..(max_bits + 7) / 8 {
                if byte_idx >= bitmap.len() {
                    break;
                }
                if bitmap[byte_idx] == 0xFF {
                    continue;
                }
                for bit_idx in 0..8 {
                    let abs_bit = byte_idx * 8 + bit_idx;
                    if abs_bit < start_bit || abs_bit >= max_bits {
                        continue;
                    }
                    if bitmap[byte_idx] & (1 << bit_idx) == 0 {
                        // Found free inode — mark as allocated
                        bitmap[byte_idx] |= 1 << bit_idx;
                        self.write_block(bitmap_block, &bitmap)?;

                        // Update bitmap checksum in group descriptor
                        self.update_gd_inode_alloc(group, &bitmap)?;

                        let inode_num =
                            group as u32 * self.sb.inodes_per_group + abs_bit as u32 + 1;
                        return Ok(inode_num);
                    }
                }
            }
        }

        bail!("No free inodes on filesystem")
    }

    /// Allocate a free data block from bitmap. Returns block number.
    fn alloc_block(&mut self, preferred_group: u32) -> Result<u64> {
        let num_groups = self.group_descs.len();

        for g_offset in 0..num_groups {
            let group = ((preferred_group as usize + g_offset) % num_groups) as usize;

            if self.group_descs[group].free_blocks_count == 0 {
                continue;
            }

            let bitmap_block = self.group_descs[group].block_bitmap;
            let mut bitmap = self.read_block(bitmap_block)?;

            for byte_idx in 0..bitmap.len() {
                if bitmap[byte_idx] == 0xFF {
                    continue;
                }
                for bit_idx in 0..8 {
                    let abs_bit = byte_idx * 8 + bit_idx;
                    if abs_bit >= self.sb.blocks_per_group as usize {
                        break;
                    }
                    if bitmap[byte_idx] & (1 << bit_idx) == 0 {
                        // Found free block — mark as allocated
                        bitmap[byte_idx] |= 1 << bit_idx;
                        self.write_block(bitmap_block, &bitmap)?;

                        // Update bitmap checksum in group descriptor
                        self.update_gd_block_alloc(group, &bitmap)?;

                        // first_data_block is 1 for 1K blocks, 0 for 4K blocks
                        let first_data_block = if self.sb.block_size == 1024 {
                            1u64
                        } else {
                            0u64
                        };
                        let block_num = group as u64 * self.sb.blocks_per_group as u64
                            + abs_bit as u64
                            + first_data_block;
                        return Ok(block_num);
                    }
                }
            }
        }

        bail!("No free blocks on filesystem")
    }

    /// Update group descriptor after inode allocation
    fn update_gd_inode_alloc(&mut self, group: usize, bitmap: &[u8]) -> Result<()> {
        self.group_descs[group].free_inodes_count =
            self.group_descs[group].free_inodes_count.saturating_sub(1);

        // Update superblock free inodes
        self.sb.free_inodes = self.sb.free_inodes.saturating_sub(1);

        self.write_group_desc_with_bitmap_csum(
            group, bitmap, true, // is_inode_bitmap
        )
    }

    /// Update group descriptor after block allocation
    fn update_gd_block_alloc(&mut self, group: usize, bitmap: &[u8]) -> Result<()> {
        self.group_descs[group].free_blocks_count =
            self.group_descs[group].free_blocks_count.saturating_sub(1);

        // Update superblock free blocks
        self.sb.free_blocks = self.sb.free_blocks.saturating_sub(1);

        self.write_group_desc_with_bitmap_csum(
            group, bitmap, false, // is_block_bitmap
        )
    }

    /// Write group descriptor with updated free counts and bitmap checksum
    fn write_group_desc_with_bitmap_csum(
        &mut self,
        group: usize,
        bitmap: &[u8],
        is_inode_bitmap: bool,
    ) -> Result<()> {
        // Re-read the group descriptor block, update counts, write back
        let gd_block = if self.sb.block_size == 1024 {
            2u64
        } else {
            1u64
        };
        let gd_offset = group * self.sb.desc_size as usize;
        let gd_block_offset = gd_offset / self.sb.block_size as usize;
        let offset_in_block = gd_offset % self.sb.block_size as usize;

        let mut block_data = self.read_block(gd_block + gd_block_offset as u64)?;

        // Update free_blocks_count (offset 12, u16)
        let fb = self.group_descs[group].free_blocks_count as u16;
        block_data[offset_in_block + 12..offset_in_block + 14].copy_from_slice(&fb.to_le_bytes());

        // Update free_inodes_count (offset 14, u16)
        let fi = self.group_descs[group].free_inodes_count as u16;
        block_data[offset_in_block + 14..offset_in_block + 16].copy_from_slice(&fi.to_le_bytes());

        // Update bitmap checksum in group descriptor
        if self.sb.metadata_csum {
            let bitmap_csum = checksum::bitmap_checksum(self.sb.csum_seed, bitmap);
            let csum_offset = if is_inode_bitmap { 18 } else { 16 };
            let csum_lo = (bitmap_csum & 0xFFFF) as u16;
            block_data[offset_in_block + csum_offset..offset_in_block + csum_offset + 2]
                .copy_from_slice(&csum_lo.to_le_bytes());

            if self.sb.is_64bit && self.sb.desc_size >= 64 {
                let csum_hi_offset = if is_inode_bitmap { 42 } else { 44 };
                let csum_hi = ((bitmap_csum >> 16) & 0xFFFF) as u16;
                block_data[offset_in_block + csum_hi_offset..offset_in_block + csum_hi_offset + 2]
                    .copy_from_slice(&csum_hi.to_le_bytes());
            }
        }

        // Recompute group descriptor checksum
        if self.sb.metadata_csum {
            let gd_end = offset_in_block + self.sb.desc_size as usize;
            let gd_raw = &block_data[offset_in_block..gd_end.min(block_data.len())];

            // Zero out checksum field before computing
            let mut gd_copy = gd_raw.to_vec();
            if gd_copy.len() > 32 {
                gd_copy[30..32].copy_from_slice(&[0, 0]);
            }

            let csum = checksum::group_desc_checksum(self.sb.csum_seed, group as u32, &gd_copy);

            // Write checksum at offset 30
            block_data[offset_in_block + 30..offset_in_block + 32]
                .copy_from_slice(&csum.to_le_bytes());
        }

        self.write_block(gd_block + gd_block_offset as u64, &block_data)?;

        // Also update superblock free counts
        self.write_superblock_free_counts()
    }

    /// Write superblock free block/inode counts back to disk
    fn write_superblock_free_counts(&mut self) -> Result<()> {
        // Superblock is at byte 1024 = sector 2 relative to partition
        let sb_sector = self.partition_start_lba as u32 + 2;
        let mut sb_data = self.conn.read_sectors(sb_sector, 2)?;

        // s_free_blocks_count (offset 12, 4 bytes)
        let fb_lo = (self.sb.free_blocks & 0xFFFFFFFF) as u32;
        sb_data[12..16].copy_from_slice(&fb_lo.to_le_bytes());

        // s_free_inodes_count (offset 16, 4 bytes)
        sb_data[16..20].copy_from_slice(&self.sb.free_inodes.to_le_bytes());

        // 64-bit free blocks hi (offset 340)
        if self.sb.is_64bit && sb_data.len() >= 344 {
            let fb_hi = ((self.sb.free_blocks >> 32) & 0xFFFFFFFF) as u32;
            sb_data[340..344].copy_from_slice(&fb_hi.to_le_bytes());
        }

        // Recompute superblock CRC-32C (bytes 1020..1024) after modifying free counts
        if self.sb.metadata_csum {
            let computed = checksum::superblock_checksum(&sb_data[..1024]);
            sb_data[1020..1024].copy_from_slice(&computed.to_le_bytes());
        }

        self.conn.write_sectors(sb_sector, &sb_data)
    }

    /// Create new inode raw data
    fn init_new_inode(&self, ino: u32, data_block: Option<u64>, data_size: usize) -> Vec<u8> {
        let inode_size = self.sb.inode_size as usize;
        let mut raw = vec![0u8; inode_size];

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as u32)
            .unwrap_or(0);

        let mode: u16 = 0o100644; // regular file, rw-r--r--
        raw[0..2].copy_from_slice(&mode.to_le_bytes()); // i_mode
                                                        // i_uid = 0 (offset 2)
        raw[4..8].copy_from_slice(&(data_size as u32).to_le_bytes()); // i_size_lo
        raw[8..12].copy_from_slice(&now.to_le_bytes()); // i_atime
        raw[12..16].copy_from_slice(&now.to_le_bytes()); // i_ctime
        raw[16..20].copy_from_slice(&now.to_le_bytes()); // i_mtime
                                                         // i_dtime = 0 (offset 20)
                                                         // i_gid = 0 (offset 24)
        raw[26..28].copy_from_slice(&1u16.to_le_bytes()); // i_links_count = 1

        if data_block.is_some() {
            // i_blocks_lo: count in 512-byte units
            let blocks_512 = self.sb.block_size / 512;
            raw[28..32].copy_from_slice(&blocks_512.to_le_bytes());
        }

        // i_flags: EXT4_EXTENTS_FL if filesystem uses extents
        let flags: u32 = if self.sb.has_extents { 0x00080000 } else { 0 };
        raw[32..36].copy_from_slice(&flags.to_le_bytes());

        // i_generation: use inode number as simple seed
        raw[100..104].copy_from_slice(&ino.to_le_bytes());

        // i_block area (60 bytes at offset 40)
        if self.sb.has_extents {
            // Extent header
            raw[40..42].copy_from_slice(&0xF30Au16.to_le_bytes()); // eh_magic
            let entries: u16 = if data_block.is_some() { 1 } else { 0 };
            raw[42..44].copy_from_slice(&entries.to_le_bytes()); // eh_entries
            raw[44..46].copy_from_slice(&4u16.to_le_bytes()); // eh_max
            raw[46..48].copy_from_slice(&0u16.to_le_bytes()); // eh_depth

            if let Some(block) = data_block {
                // Extent entry at offset 52 (i_block + 12)
                raw[52..56].copy_from_slice(&0u32.to_le_bytes()); // ee_block = 0
                raw[56..58].copy_from_slice(&1u16.to_le_bytes()); // ee_len = 1
                let hi = ((block >> 32) & 0xFFFF) as u16;
                raw[58..60].copy_from_slice(&hi.to_le_bytes()); // ee_start_hi
                let lo = (block & 0xFFFFFFFF) as u32;
                raw[60..64].copy_from_slice(&lo.to_le_bytes()); // ee_start_lo
            }
        } else if let Some(block) = data_block {
            // Legacy block pointer
            raw[40..44].copy_from_slice(&(block as u32).to_le_bytes());
        }

        // Extra inode size (offset 128) for large inodes
        if inode_size > 128 && raw.len() > 130 {
            // s_want_extra_isize: typically 32
            raw[128..130].copy_from_slice(&32u16.to_le_bytes());
        }

        raw
    }

    /// Add a directory entry to parent directory
    fn add_dir_entry(
        &mut self,
        parent_ino: u32,
        child_ino: u32,
        name: &str,
        file_type: u8,
    ) -> Result<()> {
        let parent_inode = self.read_inode(parent_ino)?;
        let extents = self.get_extents(&parent_inode)?;

        let name_bytes = name.as_bytes();
        let needed = align4(8 + name_bytes.len());

        let has_tail = self.sb.metadata_csum;
        let usable_size = self.sb.block_size as usize - if has_tail { 12 } else { 0 };

        // Read directory data via extents
        let dir_data = self.read_file_data(&parent_inode)?;

        for ext in &extents {
            for bi in 0..ext.length as u64 {
                let block_start =
                    (ext.logical_block as u64 + bi) as usize * self.sb.block_size as usize;
                let block_end = block_start + usable_size;

                if block_start >= dir_data.len() {
                    break;
                }

                // Scan entries in this block to find the last one
                let mut pos = block_start;
                let mut last_entry_pos = None;

                while pos < block_end && pos < dir_data.len() {
                    if pos + 8 > dir_data.len() {
                        break;
                    }
                    let d_rec_len =
                        u16::from_le_bytes([dir_data[pos + 4], dir_data[pos + 5]]) as usize;
                    if d_rec_len == 0 {
                        break;
                    }
                    last_entry_pos = Some(pos);
                    let next_pos = pos + d_rec_len;
                    if next_pos >= block_end {
                        break;
                    }
                    pos = next_pos;
                }

                let last_pos = match last_entry_pos {
                    Some(p) => p,
                    None => continue,
                };

                // Check if last entry has enough slack space
                let last_inode =
                    u32::from_le_bytes(dir_data[last_pos..last_pos + 4].try_into().unwrap());
                let last_rec_len =
                    u16::from_le_bytes([dir_data[last_pos + 4], dir_data[last_pos + 5]]) as usize;
                let last_name_len = dir_data[last_pos + 6] as usize;

                let last_actual = if last_inode != 0 {
                    align4(8 + last_name_len)
                } else {
                    0
                };

                let free_space = last_rec_len - last_actual;
                if free_space < needed {
                    continue;
                }

                // Found space! Read the actual block from disk and modify it
                let mut block = self.read_block(ext.physical_block + bi)?;
                let block_offset = last_pos - block_start;

                if last_inode != 0 {
                    // Shrink existing entry
                    block[block_offset + 4..block_offset + 6]
                        .copy_from_slice(&(last_actual as u16).to_le_bytes());

                    // Write new entry after it
                    let new_offset = block_offset + last_actual;
                    let new_rec_len = (last_rec_len - last_actual) as u16;
                    block[new_offset..new_offset + 4].copy_from_slice(&child_ino.to_le_bytes());
                    block[new_offset + 4..new_offset + 6]
                        .copy_from_slice(&new_rec_len.to_le_bytes());
                    block[new_offset + 6] = name_bytes.len() as u8;
                    block[new_offset + 7] = file_type;
                    block[new_offset + 8..new_offset + 8 + name_bytes.len()]
                        .copy_from_slice(name_bytes);
                } else {
                    // Reuse empty entry
                    block[block_offset..block_offset + 4].copy_from_slice(&child_ino.to_le_bytes());
                    block[block_offset + 6] = name_bytes.len() as u8;
                    block[block_offset + 7] = file_type;
                    block[block_offset + 8..block_offset + 8 + name_bytes.len()]
                        .copy_from_slice(name_bytes);
                }

                // Update directory block checksum tail
                if has_tail {
                    let tail_offset = self.sb.block_size as usize - 12;
                    let csum = checksum::dir_block_checksum(
                        self.sb.csum_seed,
                        parent_ino,
                        parent_inode.i_generation,
                        &block,
                        self.sb.block_size,
                    );

                    block[tail_offset..tail_offset + 4].copy_from_slice(&0u32.to_le_bytes());
                    block[tail_offset + 4..tail_offset + 6].copy_from_slice(&12u16.to_le_bytes());
                    block[tail_offset + 6] = 0; // reserved
                    block[tail_offset + 7] = 0xDE; // checksum tail marker
                    block[tail_offset + 8..tail_offset + 12].copy_from_slice(&csum.to_le_bytes());
                }

                self.write_block(ext.physical_block + bi, &block)?;

                // Update parent mtime/ctime
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() as u32)
                    .unwrap_or(0);

                let mut parent_raw = parent_inode.raw.clone();
                parent_raw[12..16].copy_from_slice(&now.to_le_bytes()); // i_ctime
                parent_raw[16..20].copy_from_slice(&now.to_le_bytes()); // i_mtime
                self.write_inode_raw(parent_ino, parent_raw)?;

                return Ok(());
            }
        }

        bail!("No free space in directory — block allocation not implemented")
    }

    /// Rename a directory entry in-place (same-length names only)
    ///
    /// Scans directory blocks of `parent_ino`, finds entry matching `old_name`,
    /// overwrites the name bytes with `new_name`. Updates metadata_csum tail if present.
    pub fn rename_entry(&mut self, parent_ino: u32, old_name: &str, new_name: &str) -> Result<()> {
        let old_bytes = old_name.as_bytes();
        let new_bytes = new_name.as_bytes();
        if old_bytes.len() != new_bytes.len() {
            bail!(
                "rename_entry: names must be same length (old={}, new={})",
                old_bytes.len(),
                new_bytes.len()
            );
        }

        let parent_inode = self.read_inode(parent_ino)?;
        let extents = self.get_extents(&parent_inode)?;

        for ext in &extents {
            for bi in 0..ext.length as u64 {
                let block_num = ext.physical_block + bi;
                let mut block = self.read_block(block_num)?;
                let mut pos = 0usize;
                let block_len = block.len();
                let mut found = false;

                while pos + 8 <= block_len {
                    let d_inode = u32::from_le_bytes(block[pos..pos + 4].try_into().unwrap());
                    let d_rec_len = u16::from_le_bytes([block[pos + 4], block[pos + 5]]) as usize;
                    let d_name_len = block[pos + 6] as usize;
                    let d_file_type = block[pos + 7];

                    if d_rec_len == 0 {
                        break;
                    }

                    if d_inode != 0
                        && d_name_len == old_bytes.len()
                        && d_file_type != 0xDE
                        && pos + 8 + d_name_len <= block_len
                        && &block[pos + 8..pos + 8 + d_name_len] == old_bytes
                    {
                        // Found — overwrite name bytes
                        block[pos + 8..pos + 8 + d_name_len].copy_from_slice(new_bytes);
                        found = true;
                        break;
                    }

                    pos += d_rec_len;
                }

                if found {
                    // Update checksum tail if metadata_csum
                    if self.sb.metadata_csum {
                        let tail_offset = self.sb.block_size as usize - 12;
                        let csum = checksum::dir_block_checksum(
                            self.sb.csum_seed,
                            parent_ino,
                            parent_inode.i_generation,
                            &block,
                            self.sb.block_size,
                        );

                        block[tail_offset..tail_offset + 4].copy_from_slice(&0u32.to_le_bytes());
                        block[tail_offset + 4..tail_offset + 6]
                            .copy_from_slice(&12u16.to_le_bytes());
                        block[tail_offset + 6] = 0; // reserved
                        block[tail_offset + 7] = 0xDE; // checksum tail marker
                        block[tail_offset + 8..tail_offset + 12]
                            .copy_from_slice(&csum.to_le_bytes());
                    }

                    self.write_block(block_num, &block)?;
                    return Ok(());
                }
            }
        }

        bail!("Directory entry '{}' not found", old_name)
    }

    /// Create a new file in a directory
    pub fn create_file(&mut self, parent_path: &str, name: &str, data: &[u8]) -> Result<u32> {
        let parent_inode = self.lookup(parent_path)?;
        if parent_inode.file_type() != inode::FileType::Directory {
            bail!("Not a directory: {}", parent_path);
        }

        // Check file doesn't already exist
        let entries = self.read_dir_entries(&parent_inode)?;
        if entries.iter().any(|e| e.name == name) {
            bail!("File already exists: {}", name);
        }

        // Determine group (same as parent for locality)
        let parent_group = (parent_inode.ino - 1) / self.sb.inodes_per_group;

        // Allocate inode
        let new_ino = self.alloc_inode(parent_group)?;

        // Allocate data block if data is non-empty
        let data_block = if !data.is_empty() {
            if data.len() > self.sb.block_size as usize {
                bail!(
                    "File data ({} bytes) exceeds single block ({} bytes) — multi-block create not implemented",
                    data.len(),
                    self.sb.block_size
                );
            }
            Some(self.alloc_block(parent_group)?)
        } else {
            None
        };

        // Initialize and write inode
        let inode_raw = self.init_new_inode(new_ino, data_block, data.len());
        self.write_inode_raw(new_ino, inode_raw)?;

        // Write file data
        if let Some(block) = data_block {
            let mut block_data = vec![0u8; self.sb.block_size as usize];
            block_data[..data.len()].copy_from_slice(data);
            self.write_block(block, &block_data)?;
        }

        // Add directory entry (file_type = 1 = regular file)
        self.add_dir_entry(parent_inode.ino, new_ino, name, 1)?;

        Ok(new_ino)
    }
}

/// Align to 4-byte boundary
fn align4(n: usize) -> usize {
    (n + 3) & !3
}
