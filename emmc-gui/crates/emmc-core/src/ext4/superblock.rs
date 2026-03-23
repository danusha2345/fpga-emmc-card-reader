use super::checksum;
use anyhow::{bail, Result};

const EXT4_MAGIC: u16 = 0xEF53;

// Feature flags
const INCOMPAT_EXTENTS: u32 = 0x0040;
const INCOMPAT_64BIT: u32 = 0x0080;
const INCOMPAT_CSUM_SEED: u32 = 0x2000;
const RO_COMPAT_METADATA_CSUM: u32 = 0x0400;
const COMPAT_HAS_JOURNAL: u32 = 0x0004;

#[derive(Debug, Clone)]
pub struct Superblock {
    pub inode_count: u32,
    pub block_count: u64,
    pub free_blocks: u64,
    pub free_inodes: u32,
    pub block_size: u32,
    pub blocks_per_group: u32,
    pub inodes_per_group: u32,
    pub inode_size: u16,
    pub desc_size: u16,
    pub num_groups: u32,
    pub uuid: [u8; 16],
    pub uuid_str: String,
    pub volume_name: String,
    pub is_64bit: bool,
    pub has_extents: bool,
    pub has_journal: bool,
    pub metadata_csum: bool,
    pub csum_seed: u32,
}

impl Superblock {
    /// Parse superblock from raw data (starting at byte offset 0 of the sector that
    /// contains the superblock — the superblock itself starts at offset 0 of this data,
    /// which is byte 1024 of the partition).
    pub fn parse(data: &[u8]) -> Result<Self> {
        if data.len() < 1024 {
            bail!("Superblock data too short: {} bytes", data.len());
        }

        // The caller reads from LBA+2 (byte 1024), so superblock starts at offset 0
        let s = data;
        let magic = u16::from_le_bytes([s[56], s[57]]);
        if magic != EXT4_MAGIC {
            bail!("Invalid ext4 magic: 0x{:04X} (expected 0xEF53)", magic);
        }

        let inode_count = u32::from_le_bytes(s[0..4].try_into().unwrap());
        let block_count_lo = u32::from_le_bytes(s[4..8].try_into().unwrap());
        let free_blocks_lo = u32::from_le_bytes(s[12..16].try_into().unwrap());
        let free_inodes = u32::from_le_bytes(s[16..20].try_into().unwrap());
        let log_block_size = u32::from_le_bytes(s[24..28].try_into().unwrap());
        let blocks_per_group = u32::from_le_bytes(s[32..36].try_into().unwrap());
        let inodes_per_group = u32::from_le_bytes(s[40..44].try_into().unwrap());
        let inode_size = u16::from_le_bytes([s[88], s[89]]);

        let feature_compat = u32::from_le_bytes(s[92..96].try_into().unwrap());
        let feature_incompat = u32::from_le_bytes(s[96..100].try_into().unwrap());
        let feature_ro_compat = u32::from_le_bytes(s[100..104].try_into().unwrap());

        let uuid: [u8; 16] = s[104..120].try_into().unwrap();
        let uuid_str = format!(
            "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
            u32::from_le_bytes(uuid[0..4].try_into().unwrap()),
            u16::from_le_bytes(uuid[4..6].try_into().unwrap()),
            u16::from_le_bytes(uuid[6..8].try_into().unwrap()),
            u16::from_be_bytes(uuid[8..10].try_into().unwrap()),
            {
                let mut v = 0u64;
                for &b in &uuid[10..16] {
                    v = (v << 8) | b as u64;
                }
                v
            }
        );

        let volume_name = String::from_utf8_lossy(&s[120..136])
            .trim_end_matches('\0')
            .to_string();

        let is_64bit = feature_incompat & INCOMPAT_64BIT != 0;
        let has_extents = feature_incompat & INCOMPAT_EXTENTS != 0;
        let has_journal = feature_compat & COMPAT_HAS_JOURNAL != 0;
        let metadata_csum = feature_ro_compat & RO_COMPAT_METADATA_CSUM != 0;

        let block_size = 1024u32 << log_block_size;

        // 64-bit block count
        let block_count = if is_64bit && s.len() >= 340 {
            let hi = u32::from_le_bytes(s[336..340].try_into().unwrap());
            block_count_lo as u64 | ((hi as u64) << 32)
        } else {
            block_count_lo as u64
        };

        let free_blocks = if is_64bit && s.len() >= 344 {
            let hi = u32::from_le_bytes(s[340..344].try_into().unwrap());
            free_blocks_lo as u64 | ((hi as u64) << 32)
        } else {
            free_blocks_lo as u64
        };

        let desc_size = if is_64bit && s.len() >= 256 {
            let ds = u16::from_le_bytes([s[254], s[255]]);
            if ds > 0 {
                ds
            } else {
                32
            }
        } else {
            32
        };

        let num_groups =
            ((block_count + blocks_per_group as u64 - 1) / blocks_per_group as u64) as u32;

        // Checksum seed
        let csum_seed = if metadata_csum {
            if feature_incompat & INCOMPAT_CSUM_SEED != 0 && s.len() >= 272 {
                u32::from_le_bytes(s[268..272].try_into().unwrap())
            } else {
                checksum::ext4_csum_seed(&uuid)
            }
        } else {
            0
        };

        // Verify superblock checksum (only if metadata_csum feature is enabled)
        if metadata_csum && data.len() >= 1024 {
            let stored = u32::from_le_bytes(s[1020..1024].try_into().unwrap());
            let computed = checksum::superblock_checksum(s);
            if stored != computed {
                bail!(
                    "Superblock checksum mismatch: stored=0x{:08x}, computed=0x{:08x}",
                    stored,
                    computed
                );
            }
        }

        Ok(Self {
            inode_count,
            block_count,
            free_blocks,
            free_inodes,
            block_size,
            blocks_per_group,
            inodes_per_group,
            inode_size,
            desc_size,
            num_groups,
            uuid,
            uuid_str,
            volume_name,
            is_64bit,
            has_extents,
            has_journal,
            metadata_csum,
            csum_seed,
        })
    }
}

#[derive(Debug, Clone)]
pub struct GroupDesc {
    pub block_bitmap: u64,
    pub inode_bitmap: u64,
    pub inode_table: u64,
    pub free_blocks_count: u32,
    pub free_inodes_count: u32,
}

impl GroupDesc {
    pub fn parse(data: &[u8], is_64bit: bool) -> Self {
        let block_bitmap_lo = u32::from_le_bytes(data[0..4].try_into().unwrap());
        let inode_bitmap_lo = u32::from_le_bytes(data[4..8].try_into().unwrap());
        let inode_table_lo = u32::from_le_bytes(data[8..12].try_into().unwrap());
        let free_blocks_lo = u16::from_le_bytes([data[12], data[13]]);
        let free_inodes_lo = u16::from_le_bytes([data[14], data[15]]);

        if is_64bit && data.len() >= 64 {
            let block_bitmap_hi = u32::from_le_bytes(data[32..36].try_into().unwrap());
            let inode_bitmap_hi = u32::from_le_bytes(data[36..40].try_into().unwrap());
            let inode_table_hi = u32::from_le_bytes(data[40..44].try_into().unwrap());
            let free_blocks_hi = u16::from_le_bytes([data[44], data[45]]);
            let free_inodes_hi = u16::from_le_bytes([data[46], data[47]]);

            Self {
                block_bitmap: block_bitmap_lo as u64 | ((block_bitmap_hi as u64) << 32),
                inode_bitmap: inode_bitmap_lo as u64 | ((inode_bitmap_hi as u64) << 32),
                inode_table: inode_table_lo as u64 | ((inode_table_hi as u64) << 32),
                free_blocks_count: free_blocks_lo as u32 | ((free_blocks_hi as u32) << 16),
                free_inodes_count: free_inodes_lo as u32 | ((free_inodes_hi as u32) << 16),
            }
        } else {
            Self {
                block_bitmap: block_bitmap_lo as u64,
                inode_bitmap: inode_bitmap_lo as u64,
                inode_table: inode_table_lo as u64,
                free_blocks_count: free_blocks_lo as u32,
                free_inodes_count: free_inodes_lo as u32,
            }
        }
    }
}
