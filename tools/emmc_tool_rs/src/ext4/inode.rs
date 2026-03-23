use anyhow::{bail, Result};

const EXT4_EXTENT_MAGIC: u16 = 0xF30A;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FileType {
    Unknown,
    RegularFile,
    Directory,
    CharDevice,
    BlockDevice,
    Fifo,
    Socket,
    Symlink,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct Inode {
    pub ino: u32,
    pub i_mode: u16,
    pub i_size: u64,
    pub i_blocks: u64,
    pub i_flags: u32,
    pub i_generation: u32,
    pub i_block: [u8; 60],
    pub raw: Vec<u8>,
}

impl Inode {
    pub fn file_type(&self) -> FileType {
        match (self.i_mode >> 12) & 0xF {
            0x1 => FileType::Fifo,
            0x2 => FileType::CharDevice,
            0x4 => FileType::Directory,
            0x6 => FileType::BlockDevice,
            0x8 => FileType::RegularFile,
            0xA => FileType::Symlink,
            0xC => FileType::Socket,
            _ => FileType::Unknown,
        }
    }

    pub fn mode_string(&self) -> String {
        let ft = match self.file_type() {
            FileType::Directory => 'd',
            FileType::Symlink => 'l',
            FileType::CharDevice => 'c',
            FileType::BlockDevice => 'b',
            FileType::Fifo => 'p',
            FileType::Socket => 's',
            _ => '-',
        };
        let m = self.i_mode;
        format!(
            "{}{}{}{}{}{}{}{}{}{}",
            ft,
            if m & 0o400 != 0 { 'r' } else { '-' },
            if m & 0o200 != 0 { 'w' } else { '-' },
            if m & 0o100 != 0 { 'x' } else { '-' },
            if m & 0o040 != 0 { 'r' } else { '-' },
            if m & 0o020 != 0 { 'w' } else { '-' },
            if m & 0o010 != 0 { 'x' } else { '-' },
            if m & 0o004 != 0 { 'r' } else { '-' },
            if m & 0o002 != 0 { 'w' } else { '-' },
            if m & 0o001 != 0 { 'x' } else { '-' },
        )
    }

    pub fn has_extents(&self) -> bool {
        self.i_flags & 0x00080000 != 0
    }
}

pub fn parse_inode(data: &[u8], ino: u32, inode_size: u16) -> Result<Inode> {
    let sz = inode_size as usize;
    if data.len() < sz.min(128) {
        bail!("Inode data too short: {} bytes", data.len());
    }

    let i_mode = u16::from_le_bytes([data[0], data[1]]);
    let i_size_lo = u32::from_le_bytes(data[4..8].try_into().unwrap());
    let i_blocks_lo = u32::from_le_bytes(data[28..32].try_into().unwrap());
    let i_flags = u32::from_le_bytes(data[32..36].try_into().unwrap());

    let mut i_block = [0u8; 60];
    i_block.copy_from_slice(&data[40..100]);

    let i_generation = u32::from_le_bytes(data[100..104].try_into().unwrap());

    let i_size = if (i_mode >> 12) & 0xF == 0x8 {
        let size_hi = u32::from_le_bytes(data[108..112].try_into().unwrap());
        i_size_lo as u64 | ((size_hi as u64) << 32)
    } else {
        i_size_lo as u64
    };

    let i_blocks = i_blocks_lo as u64;

    Ok(Inode {
        ino, i_mode, i_size, i_blocks, i_flags, i_generation, i_block,
        raw: data[..sz.min(data.len())].to_vec(),
    })
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct Extent {
    pub logical_block: u32,
    pub length: u16,
    pub physical_block: u64,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct ExtentIdx {
    pub logical_block: u32,
    pub child_block: u64,
}

#[derive(Debug)]
pub enum ExtentNodeContents {
    Leaves(Vec<Extent>),
    Indices(Vec<ExtentIdx>),
    Empty,
}

pub fn parse_extent_node(data: &[u8]) -> Result<ExtentNodeContents> {
    parse_extent_node_inner(data, false)
}

pub fn parse_extent_node_force(data: &[u8]) -> Result<ExtentNodeContents> {
    parse_extent_node_inner(data, true)
}

fn parse_extent_node_inner(data: &[u8], force: bool) -> Result<ExtentNodeContents> {
    if data.len() < 12 {
        bail!("Extent header too short");
    }

    let magic = u16::from_le_bytes([data[0], data[1]]);
    if magic != EXT4_EXTENT_MAGIC {
        if force {
            eprintln!("Warning: extent magic 0x{:04X} != 0xF30A, force-parsing", magic);
        } else {
            return Ok(ExtentNodeContents::Empty);
        }
    }

    let entries = u16::from_le_bytes([data[2], data[3]]);
    let depth = u16::from_le_bytes([data[6], data[7]]);

    if depth == 0 {
        let mut result = Vec::new();
        for i in 0..entries as usize {
            let offset = 12 + i * 12;
            if offset + 12 > data.len() { break; }
            let logical_block = u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap());
            let length = u16::from_le_bytes([data[offset + 4], data[offset + 5]]);
            let phys_hi = u16::from_le_bytes([data[offset + 6], data[offset + 7]]);
            let phys_lo = u32::from_le_bytes(data[offset + 8..offset + 12].try_into().unwrap());
            let physical_block = phys_lo as u64 | ((phys_hi as u64) << 32);
            result.push(Extent { logical_block, length, physical_block });
        }
        Ok(ExtentNodeContents::Leaves(result))
    } else {
        let mut indices = Vec::new();
        for i in 0..entries as usize {
            let offset = 12 + i * 12;
            if offset + 12 > data.len() { break; }
            let logical_block = u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap());
            let child_lo = u32::from_le_bytes(data[offset + 4..offset + 8].try_into().unwrap());
            let child_hi = u16::from_le_bytes([data[offset + 8], data[offset + 9]]);
            let child_block = child_lo as u64 | ((child_hi as u64) << 32);
            indices.push(ExtentIdx { logical_block, child_block });
        }
        Ok(ExtentNodeContents::Indices(indices))
    }
}
