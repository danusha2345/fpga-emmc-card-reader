pub mod checksum;
pub mod directory;
pub mod file_ops;
pub mod inode;
pub mod superblock;

use crate::protocol::EmmcConnection;
use anyhow::{bail, Result};

/// ext4 filesystem accessor over eMMC sectors
pub struct Ext4Fs<'a> {
    conn: &'a mut EmmcConnection,
    pub partition_start_lba: u64,
    pub sb: superblock::Superblock,
    pub group_descs: Vec<superblock::GroupDesc>,
}

impl<'a> Ext4Fs<'a> {
    /// Open ext4 filesystem at given partition start LBA
    pub fn open(conn: &'a mut EmmcConnection, partition_start_lba: u64) -> Result<Self> {
        // Superblock is at byte offset 1024 within the partition = sector 2 relative
        let sb_sector = partition_start_lba as u32 + 2; // byte 1024 = sector 2
        let sb_data = conn.read_sectors(sb_sector, 2)?; // read 1024 bytes
        let sb = superblock::Superblock::parse(&sb_data)?;

        // Read group descriptors
        let gd_block = if sb.block_size == 1024 { 2 } else { 1 };
        let gd_sector = partition_start_lba as u32 + (gd_block * sb.block_size / 512) as u32;
        let gd_sectors = ((sb.num_groups as u64 * sb.desc_size as u64) + 511) / 512;
        let gd_data = conn.read_sectors(gd_sector, gd_sectors as u16)?;

        let mut group_descs = Vec::with_capacity(sb.num_groups as usize);
        for i in 0..sb.num_groups as usize {
            let offset = i * sb.desc_size as usize;
            if offset + sb.desc_size as usize > gd_data.len() {
                break;
            }
            let gd_raw = &gd_data[offset..offset + sb.desc_size as usize];

            if sb.metadata_csum && gd_raw.len() >= 32 {
                let stored = u16::from_le_bytes([gd_raw[30], gd_raw[31]]);
                let mut gd_copy = gd_raw.to_vec();
                gd_copy[30..32].copy_from_slice(&[0, 0]);
                let computed = checksum::group_desc_checksum(sb.csum_seed, i as u32, &gd_copy);
                if stored != computed {
                    tracing::warn!(
                        "Group descriptor {} checksum mismatch: stored=0x{:04x}, computed=0x{:04x}",
                        i,
                        stored,
                        computed
                    );
                }
            }

            group_descs.push(superblock::GroupDesc::parse(gd_raw, sb.is_64bit));
        }

        Ok(Self {
            conn,
            partition_start_lba,
            sb,
            group_descs,
        })
    }

    /// Read a block by block number (relative to partition start)
    pub fn read_block(&mut self, block_num: u64) -> Result<Vec<u8>> {
        let sector =
            self.partition_start_lba as u32 + (block_num * self.sb.block_size as u64 / 512) as u32;
        let sectors_per_block = (self.sb.block_size / 512) as u16;
        self.conn.read_sectors(sector, sectors_per_block)
    }

    /// Write a block
    pub fn write_block(&mut self, block_num: u64, data: &[u8]) -> Result<()> {
        let sector =
            self.partition_start_lba as u32 + (block_num * self.sb.block_size as u64 / 512) as u32;
        self.conn.write_sectors(sector, data)
    }

    /// Get filesystem info
    pub fn info(&self) -> Ext4Info {
        Ext4Info {
            volume_name: self.sb.volume_name.clone(),
            uuid: self.sb.uuid_str.clone(),
            block_size: self.sb.block_size,
            block_count: self.sb.block_count,
            free_blocks: self.sb.free_blocks,
            inode_count: self.sb.inode_count,
            free_inodes: self.sb.free_inodes,
            inode_size: self.sb.inode_size,
            num_groups: self.sb.num_groups,
            desc_size: self.sb.desc_size,
            is_64bit: self.sb.is_64bit,
            has_extents: self.sb.has_extents,
            has_journal: self.sb.has_journal,
            metadata_csum: self.sb.metadata_csum,
        }
    }

    /// Check if a path exists
    pub fn exists(&mut self, path: &str) -> Result<bool> {
        match self.lookup(path) {
            Ok(_) => Ok(true),
            Err(_) => Ok(false),
        }
    }

    /// Lookup inode by path
    pub fn lookup(&mut self, path: &str) -> Result<inode::Inode> {
        let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();

        // Start from root inode (2)
        let mut current_ino = 2u32;
        let mut current_inode = self.read_inode(current_ino)?;

        for part in &parts {
            let entries = self.read_dir_entries(&current_inode)?;
            let found = entries.iter().find(|e| e.name == *part);
            match found {
                Some(entry) => {
                    current_ino = entry.inode;
                    current_inode = self.read_inode(current_ino)?;
                }
                None => {
                    bail!("Not found: {}", part);
                }
            }
        }

        Ok(current_inode)
    }

    /// List directory contents
    pub fn ls(&mut self, path: &str) -> Result<Vec<Ext4DirEntry>> {
        let inode = self.lookup(path)?;
        if inode.file_type() != inode::FileType::Directory {
            bail!("Not a directory: {}", path);
        }
        self.read_dir_entries(&inode)
    }

    /// Read file content
    pub fn cat(&mut self, path: &str) -> Result<Vec<u8>> {
        let inode = self.lookup(path)?;
        if inode.file_type() != inode::FileType::RegularFile {
            bail!("Not a regular file: {}", path);
        }
        self.read_file_data(&inode)
    }
}

#[derive(Debug, Clone)]
pub struct Ext4Info {
    pub volume_name: String,
    pub uuid: String,
    pub block_size: u32,
    pub block_count: u64,
    pub free_blocks: u64,
    pub inode_count: u32,
    pub free_inodes: u32,
    pub inode_size: u16,
    pub num_groups: u32,
    pub desc_size: u16,
    pub is_64bit: bool,
    pub has_extents: bool,
    pub has_journal: bool,
    pub metadata_csum: bool,
}

#[derive(Debug, Clone)]
pub struct Ext4DirEntry {
    pub inode: u32,
    pub name: String,
    pub file_type: u8,
    pub rec_len: u16,
}

impl Ext4DirEntry {
    pub fn file_type_name(&self) -> &str {
        match self.file_type {
            1 => "f",
            2 => "d",
            7 => "l",
            _ => "?",
        }
    }
}
