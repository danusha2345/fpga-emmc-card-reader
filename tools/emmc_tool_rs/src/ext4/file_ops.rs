use super::checksum;
use super::directory;
use super::inode::{self, Extent, ExtentNodeContents, Inode};
use super::{Ext4DirEntry, Ext4Fs};
use anyhow::{bail, Result};

impl Ext4Fs<'_> {
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
                self.sb.csum_seed, ino, inode.i_generation, &inode.raw, self.sb.inode_size,
            );
            let stored_lo = u16::from_le_bytes(inode.raw[124..126].try_into().unwrap()) as u32;
            let stored = if self.sb.inode_size > 128 && inode.raw.len() > 132 {
                stored_lo | ((u16::from_le_bytes(inode.raw[130..132].try_into().unwrap()) as u32) << 16)
            } else {
                stored_lo
            };
            if stored != computed {
                eprintln!("Warning: inode {} checksum mismatch: stored=0x{:08x}, computed=0x{:08x}", ino, stored, computed);
            }
        }

        Ok(inode)
    }

    pub fn get_extents(&mut self, inode: &Inode) -> Result<Vec<Extent>> {
        if !inode.has_extents() {
            bail!("Inode does not use extent trees (legacy block pointers not supported)");
        }

        let root = inode::parse_extent_node(&inode.i_block)?;
        match root {
            ExtentNodeContents::Leaves(extents) if !extents.is_empty() => return Ok(extents),
            ExtentNodeContents::Indices(indices) => return self.resolve_extent_indices(&indices),
            _ => {}
        }

        // Retry with fresh reads
        for _ in 0..3 {
            match self.read_inode(inode.ino) {
                Ok(fresh_inode) => {
                    let retried = inode::parse_extent_node(&fresh_inode.i_block)?;
                    match retried {
                        ExtentNodeContents::Leaves(extents) if !extents.is_empty() => return Ok(extents),
                        ExtentNodeContents::Indices(indices) => return self.resolve_extent_indices(&indices),
                        _ => {}
                    }
                }
                Err(_) => {}
            }
        }

        // Force-parse
        let forced = inode::parse_extent_node_force(&inode.i_block)?;
        match forced {
            ExtentNodeContents::Leaves(extents) if !extents.is_empty() => Ok(extents),
            ExtentNodeContents::Indices(indices) => self.resolve_extent_indices(&indices),
            _ => Ok(Vec::new()),
        }
    }

    fn resolve_extent_indices(&mut self, indices: &[inode::ExtentIdx]) -> Result<Vec<Extent>> {
        let mut all_extents = Vec::new();
        for idx in indices {
            let child_data = self.read_block(idx.child_block)?;
            let child_node = inode::parse_extent_node(&child_data)?;
            match child_node {
                ExtentNodeContents::Leaves(extents) => all_extents.extend(extents),
                ExtentNodeContents::Indices(sub_indices) => {
                    let sub_extents = self.resolve_extent_indices(&sub_indices)?;
                    all_extents.extend(sub_extents);
                }
                ExtentNodeContents::Empty => {}
            }
        }
        Ok(all_extents)
    }

    pub fn read_dir_entries(&mut self, inode: &Inode) -> Result<Vec<Ext4DirEntry>> {
        let extents = self.get_extents(inode)?;
        let mut entries = Vec::new();

        for ext in &extents {
            for i in 0..ext.length as u64 {
                let block_data = self.read_block(ext.physical_block + i)?;
                let dir_entries = directory::parse_dir_entries(&block_data, self.sb.block_size);
                entries.extend(dir_entries);
            }
        }

        Ok(entries)
    }

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

    pub fn overwrite_file_data(&mut self, inode: &Inode, new_data: &[u8]) -> Result<()> {
        let extents = self.get_extents(inode)?;
        let total_blocks: u64 = extents.iter().map(|e| e.length as u64).sum();
        let total_space = total_blocks * self.sb.block_size as u64;

        if new_data.len() as u64 > total_space {
            bail!("New data ({} bytes) exceeds allocated space ({} bytes)", new_data.len(), total_space);
        }

        let mut written = 0usize;
        for ext in &extents {
            for i in 0..ext.length as u64 {
                if written >= new_data.len() {
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

        if new_data.len() as u64 != inode.i_size {
            self.update_inode_size(inode, new_data.len() as u64)?;
        }

        Ok(())
    }

    fn update_inode_size(&mut self, inode: &Inode, new_size: u64) -> Result<()> {
        let group = ((inode.ino - 1) / self.sb.inodes_per_group) as usize;
        let index = ((inode.ino - 1) % self.sb.inodes_per_group) as usize;
        let inode_table_block = self.group_descs[group].inode_table;
        let inode_offset = index * self.sb.inode_size as usize;
        let block_offset = inode_offset / self.sb.block_size as usize;
        let offset_in_block = inode_offset % self.sb.block_size as usize;

        let mut block_data = self.read_block(inode_table_block + block_offset as u64)?;

        let size_lo = (new_size & 0xFFFFFFFF) as u32;
        block_data[offset_in_block + 4..offset_in_block + 8].copy_from_slice(&size_lo.to_le_bytes());

        if (inode.i_mode >> 12) & 0xF == 0x8 {
            let size_hi = (new_size >> 32) as u32;
            block_data[offset_in_block + 108..offset_in_block + 112].copy_from_slice(&size_hi.to_le_bytes());
        }

        if self.sb.metadata_csum {
            let inode_raw = &block_data[offset_in_block..offset_in_block + self.sb.inode_size as usize];
            let csum = checksum::inode_checksum(self.sb.csum_seed, inode.ino, inode.i_generation, inode_raw, self.sb.inode_size);
            let lo = (csum & 0xFFFF) as u16;
            block_data[offset_in_block + 124..offset_in_block + 126].copy_from_slice(&lo.to_le_bytes());
            if self.sb.inode_size > 128 {
                let hi = ((csum >> 16) & 0xFFFF) as u16;
                block_data[offset_in_block + 130..offset_in_block + 132].copy_from_slice(&hi.to_le_bytes());
            }
        }

        self.write_block(inode_table_block + block_offset as u64, &block_data)?;
        Ok(())
    }

    fn write_inode_raw(&mut self, ino: u32, mut inode_raw: Vec<u8>) -> Result<()> {
        if self.sb.metadata_csum {
            let generation = u32::from_le_bytes(inode_raw[100..104].try_into().unwrap_or([0; 4]));
            let csum = checksum::inode_checksum(self.sb.csum_seed, ino, generation, &inode_raw, self.sb.inode_size);
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
        block_data[offset_in_block..offset_in_block + copy_len].copy_from_slice(&inode_raw[..copy_len]);

        self.write_block(inode_table_block + block_offset as u64, &block_data)
    }

    fn alloc_inode(&mut self, preferred_group: u32) -> Result<u32> {
        let num_groups = self.group_descs.len();
        let first_usable_inode = 11u32;

        for g_offset in 0..num_groups {
            let group = ((preferred_group as usize + g_offset) % num_groups) as usize;
            if self.group_descs[group].free_inodes_count == 0 { continue; }

            let bitmap_block = self.group_descs[group].inode_bitmap;
            let mut bitmap = self.read_block(bitmap_block)?;
            let start_bit = if group == 0 { first_usable_inode as usize } else { 0 };
            let max_bits = self.sb.inodes_per_group as usize;

            for byte_idx in start_bit / 8..(max_bits + 7) / 8 {
                if byte_idx >= bitmap.len() { break; }
                if bitmap[byte_idx] == 0xFF { continue; }
                for bit_idx in 0..8 {
                    let abs_bit = byte_idx * 8 + bit_idx;
                    if abs_bit < start_bit || abs_bit >= max_bits { continue; }
                    if bitmap[byte_idx] & (1 << bit_idx) == 0 {
                        bitmap[byte_idx] |= 1 << bit_idx;
                        self.write_block(bitmap_block, &bitmap)?;
                        self.update_gd_inode_alloc(group, &bitmap)?;
                        return Ok(group as u32 * self.sb.inodes_per_group + abs_bit as u32 + 1);
                    }
                }
            }
        }

        bail!("No free inodes on filesystem")
    }

    fn alloc_block(&mut self, preferred_group: u32) -> Result<u64> {
        let num_groups = self.group_descs.len();

        for g_offset in 0..num_groups {
            let group = ((preferred_group as usize + g_offset) % num_groups) as usize;
            if self.group_descs[group].free_blocks_count == 0 { continue; }

            let bitmap_block = self.group_descs[group].block_bitmap;
            let mut bitmap = self.read_block(bitmap_block)?;

            for byte_idx in 0..bitmap.len() {
                if bitmap[byte_idx] == 0xFF { continue; }
                for bit_idx in 0..8 {
                    let abs_bit = byte_idx * 8 + bit_idx;
                    if abs_bit >= self.sb.blocks_per_group as usize { break; }
                    if bitmap[byte_idx] & (1 << bit_idx) == 0 {
                        bitmap[byte_idx] |= 1 << bit_idx;
                        self.write_block(bitmap_block, &bitmap)?;
                        self.update_gd_block_alloc(group, &bitmap)?;
                        let first_data_block = if self.sb.block_size == 1024 { 1u64 } else { 0u64 };
                        return Ok(group as u64 * self.sb.blocks_per_group as u64 + abs_bit as u64 + first_data_block);
                    }
                }
            }
        }

        bail!("No free blocks on filesystem")
    }

    fn update_gd_inode_alloc(&mut self, group: usize, bitmap: &[u8]) -> Result<()> {
        self.group_descs[group].free_inodes_count = self.group_descs[group].free_inodes_count.saturating_sub(1);
        self.sb.free_inodes = self.sb.free_inodes.saturating_sub(1);
        self.write_group_desc_with_bitmap_csum(group, bitmap, true)
    }

    fn update_gd_block_alloc(&mut self, group: usize, bitmap: &[u8]) -> Result<()> {
        self.group_descs[group].free_blocks_count = self.group_descs[group].free_blocks_count.saturating_sub(1);
        self.sb.free_blocks = self.sb.free_blocks.saturating_sub(1);
        self.write_group_desc_with_bitmap_csum(group, bitmap, false)
    }

    fn write_group_desc_with_bitmap_csum(&mut self, group: usize, bitmap: &[u8], is_inode_bitmap: bool) -> Result<()> {
        let gd_block = if self.sb.block_size == 1024 { 2u64 } else { 1u64 };
        let gd_offset = group * self.sb.desc_size as usize;
        let gd_block_offset = gd_offset / self.sb.block_size as usize;
        let offset_in_block = gd_offset % self.sb.block_size as usize;

        let mut block_data = self.read_block(gd_block + gd_block_offset as u64)?;

        let fb = self.group_descs[group].free_blocks_count as u16;
        block_data[offset_in_block + 12..offset_in_block + 14].copy_from_slice(&fb.to_le_bytes());
        let fi = self.group_descs[group].free_inodes_count as u16;
        block_data[offset_in_block + 14..offset_in_block + 16].copy_from_slice(&fi.to_le_bytes());

        if self.sb.metadata_csum {
            let bitmap_csum = checksum::bitmap_checksum(self.sb.csum_seed, bitmap);
            let csum_offset = if is_inode_bitmap { 18 } else { 16 };
            let csum_lo = (bitmap_csum & 0xFFFF) as u16;
            block_data[offset_in_block + csum_offset..offset_in_block + csum_offset + 2].copy_from_slice(&csum_lo.to_le_bytes());

            if self.sb.is_64bit && self.sb.desc_size >= 64 {
                let csum_hi_offset = if is_inode_bitmap { 42 } else { 44 };
                let csum_hi = ((bitmap_csum >> 16) & 0xFFFF) as u16;
                block_data[offset_in_block + csum_hi_offset..offset_in_block + csum_hi_offset + 2].copy_from_slice(&csum_hi.to_le_bytes());
            }
        }

        if self.sb.metadata_csum {
            let gd_end = offset_in_block + self.sb.desc_size as usize;
            let gd_raw = &block_data[offset_in_block..gd_end.min(block_data.len())];
            let mut gd_copy = gd_raw.to_vec();
            if gd_copy.len() > 32 { gd_copy[30..32].copy_from_slice(&[0, 0]); }
            let csum = checksum::group_desc_checksum(self.sb.csum_seed, group as u32, &gd_copy);
            block_data[offset_in_block + 30..offset_in_block + 32].copy_from_slice(&csum.to_le_bytes());
        }

        self.write_block(gd_block + gd_block_offset as u64, &block_data)?;
        self.write_superblock_free_counts()
    }

    fn write_superblock_free_counts(&mut self) -> Result<()> {
        let sb_sector = self.partition_start_lba as u32 + 2;
        let mut sb_data = self.io.read_sectors(sb_sector, 2)?;

        let fb_lo = (self.sb.free_blocks & 0xFFFFFFFF) as u32;
        sb_data[12..16].copy_from_slice(&fb_lo.to_le_bytes());
        sb_data[16..20].copy_from_slice(&self.sb.free_inodes.to_le_bytes());

        if self.sb.is_64bit && sb_data.len() >= 344 {
            let fb_hi = ((self.sb.free_blocks >> 32) & 0xFFFFFFFF) as u32;
            sb_data[340..344].copy_from_slice(&fb_hi.to_le_bytes());
        }

        if self.sb.metadata_csum {
            let computed = checksum::superblock_checksum(&sb_data[..1024]);
            sb_data[1020..1024].copy_from_slice(&computed.to_le_bytes());
        }

        self.io.write_sectors(sb_sector, &sb_data)
    }

    fn init_new_inode(&self, ino: u32, data_block: Option<u64>, data_size: usize) -> Vec<u8> {
        let inode_size = self.sb.inode_size as usize;
        let mut raw = vec![0u8; inode_size];

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as u32)
            .unwrap_or(0);

        let mode: u16 = 0o100644;
        raw[0..2].copy_from_slice(&mode.to_le_bytes());
        raw[4..8].copy_from_slice(&(data_size as u32).to_le_bytes());
        raw[8..12].copy_from_slice(&now.to_le_bytes());
        raw[12..16].copy_from_slice(&now.to_le_bytes());
        raw[16..20].copy_from_slice(&now.to_le_bytes());
        raw[26..28].copy_from_slice(&1u16.to_le_bytes());

        if data_block.is_some() {
            let blocks_512 = self.sb.block_size / 512;
            raw[28..32].copy_from_slice(&blocks_512.to_le_bytes());
        }

        let flags: u32 = if self.sb.has_extents { 0x00080000 } else { 0 };
        raw[32..36].copy_from_slice(&flags.to_le_bytes());
        raw[100..104].copy_from_slice(&ino.to_le_bytes());

        if self.sb.has_extents {
            raw[40..42].copy_from_slice(&0xF30Au16.to_le_bytes());
            let entries: u16 = if data_block.is_some() { 1 } else { 0 };
            raw[42..44].copy_from_slice(&entries.to_le_bytes());
            raw[44..46].copy_from_slice(&4u16.to_le_bytes());
            raw[46..48].copy_from_slice(&0u16.to_le_bytes());

            if let Some(block) = data_block {
                raw[52..56].copy_from_slice(&0u32.to_le_bytes());
                raw[56..58].copy_from_slice(&1u16.to_le_bytes());
                let hi = ((block >> 32) & 0xFFFF) as u16;
                raw[58..60].copy_from_slice(&hi.to_le_bytes());
                let lo = (block & 0xFFFFFFFF) as u32;
                raw[60..64].copy_from_slice(&lo.to_le_bytes());
            }
        } else if let Some(block) = data_block {
            raw[40..44].copy_from_slice(&(block as u32).to_le_bytes());
        }

        if inode_size > 128 && raw.len() > 130 {
            raw[128..130].copy_from_slice(&32u16.to_le_bytes());
        }

        raw
    }

    fn add_dir_entry(&mut self, parent_ino: u32, child_ino: u32, name: &str, file_type: u8) -> Result<()> {
        let parent_inode = self.read_inode(parent_ino)?;
        let extents = self.get_extents(&parent_inode)?;
        let name_bytes = name.as_bytes();
        let needed = align4(8 + name_bytes.len());
        let has_tail = self.sb.metadata_csum;
        let usable_size = self.sb.block_size as usize - if has_tail { 12 } else { 0 };
        let dir_data = self.read_file_data(&parent_inode)?;

        for ext in &extents {
            for bi in 0..ext.length as u64 {
                let block_start = (ext.logical_block as u64 + bi) as usize * self.sb.block_size as usize;
                let block_end = block_start + usable_size;
                if block_start >= dir_data.len() { break; }

                let mut pos = block_start;
                let mut last_entry_pos = None;

                while pos < block_end && pos < dir_data.len() {
                    if pos + 8 > dir_data.len() { break; }
                    let d_rec_len = u16::from_le_bytes([dir_data[pos + 4], dir_data[pos + 5]]) as usize;
                    if d_rec_len == 0 { break; }
                    last_entry_pos = Some(pos);
                    let next_pos = pos + d_rec_len;
                    if next_pos >= block_end { break; }
                    pos = next_pos;
                }

                let last_pos = match last_entry_pos {
                    Some(p) => p,
                    None => continue,
                };

                let last_inode = u32::from_le_bytes(dir_data[last_pos..last_pos + 4].try_into().unwrap());
                let last_rec_len = u16::from_le_bytes([dir_data[last_pos + 4], dir_data[last_pos + 5]]) as usize;
                let last_name_len = dir_data[last_pos + 6] as usize;
                let last_actual = if last_inode != 0 { align4(8 + last_name_len) } else { 0 };
                let free_space = last_rec_len - last_actual;
                if free_space < needed { continue; }

                let mut block = self.read_block(ext.physical_block + bi)?;
                let block_offset = last_pos - block_start;

                if last_inode != 0 {
                    block[block_offset + 4..block_offset + 6].copy_from_slice(&(last_actual as u16).to_le_bytes());
                    let new_offset = block_offset + last_actual;
                    let new_rec_len = (last_rec_len - last_actual) as u16;
                    block[new_offset..new_offset + 4].copy_from_slice(&child_ino.to_le_bytes());
                    block[new_offset + 4..new_offset + 6].copy_from_slice(&new_rec_len.to_le_bytes());
                    block[new_offset + 6] = name_bytes.len() as u8;
                    block[new_offset + 7] = file_type;
                    block[new_offset + 8..new_offset + 8 + name_bytes.len()].copy_from_slice(name_bytes);
                } else {
                    block[block_offset..block_offset + 4].copy_from_slice(&child_ino.to_le_bytes());
                    block[block_offset + 6] = name_bytes.len() as u8;
                    block[block_offset + 7] = file_type;
                    block[block_offset + 8..block_offset + 8 + name_bytes.len()].copy_from_slice(name_bytes);
                }

                if has_tail {
                    let tail_offset = self.sb.block_size as usize - 12;
                    let csum = checksum::dir_block_checksum(self.sb.csum_seed, parent_ino, parent_inode.i_generation, &block, self.sb.block_size);
                    block[tail_offset..tail_offset + 4].copy_from_slice(&0u32.to_le_bytes());
                    block[tail_offset + 4..tail_offset + 6].copy_from_slice(&12u16.to_le_bytes());
                    block[tail_offset + 6] = 0;
                    block[tail_offset + 7] = 0xDE;
                    block[tail_offset + 8..tail_offset + 12].copy_from_slice(&csum.to_le_bytes());
                }

                self.write_block(ext.physical_block + bi, &block)?;

                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() as u32)
                    .unwrap_or(0);
                let mut parent_raw = parent_inode.raw.clone();
                parent_raw[12..16].copy_from_slice(&now.to_le_bytes());
                parent_raw[16..20].copy_from_slice(&now.to_le_bytes());
                self.write_inode_raw(parent_ino, parent_raw)?;

                return Ok(());
            }
        }

        bail!("No free space in directory")
    }

    pub fn create_file(&mut self, parent_path: &str, name: &str, data: &[u8]) -> Result<u32> {
        let parent_inode = self.lookup(parent_path)?;
        if parent_inode.file_type() != inode::FileType::Directory {
            bail!("Not a directory: {}", parent_path);
        }

        let entries = self.read_dir_entries(&parent_inode)?;
        if entries.iter().any(|e| e.name == name) {
            bail!("File already exists: {}", name);
        }

        let parent_group = (parent_inode.ino - 1) / self.sb.inodes_per_group;
        let new_ino = self.alloc_inode(parent_group)?;

        let data_block = if !data.is_empty() {
            if data.len() > self.sb.block_size as usize {
                bail!("File data ({} bytes) exceeds single block ({} bytes)", data.len(), self.sb.block_size);
            }
            Some(self.alloc_block(parent_group)?)
        } else {
            None
        };

        let inode_raw = self.init_new_inode(new_ino, data_block, data.len());
        self.write_inode_raw(new_ino, inode_raw)?;

        if let Some(block) = data_block {
            let mut block_data = vec![0u8; self.sb.block_size as usize];
            block_data[..data.len()].copy_from_slice(data);
            self.write_block(block, &block_data)?;
        }

        self.add_dir_entry(parent_inode.ino, new_ino, name, 1)?;
        Ok(new_ino)
    }
}

fn align4(n: usize) -> usize {
    (n + 3) & !3
}
