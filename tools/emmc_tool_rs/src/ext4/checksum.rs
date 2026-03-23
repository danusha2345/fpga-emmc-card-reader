/// CRC-32C (Castagnoli) — used for ext4 metadata checksums
///
/// Polynomial: 0x82F63B78 (reflected)

const CRC32C_TABLE: [u32; 256] = {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut crc = i as u32;
        let mut j = 0;
        while j < 8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0x82F63B78;
            } else {
                crc >>= 1;
            }
            j += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
};

pub fn crc32c_raw(data: &[u8], init: u32) -> u32 {
    let mut crc = init;
    for &byte in data {
        crc = (crc >> 8) ^ CRC32C_TABLE[((crc ^ byte as u32) & 0xFF) as usize];
    }
    crc
}

#[allow(dead_code)]
pub fn crc32c(data: &[u8]) -> u32 {
    crc32c_raw(data, 0xFFFFFFFF) ^ 0xFFFFFFFF
}

pub fn ext4_csum_seed(uuid: &[u8; 16]) -> u32 {
    crc32c_raw(uuid, 0xFFFFFFFF)
}

pub fn inode_checksum(
    seed: u32,
    inode_num: u32,
    generation: u32,
    inode_raw: &[u8],
    inode_size: u16,
) -> u32 {
    let ino_bytes = inode_num.to_le_bytes();
    let gen_bytes = generation.to_le_bytes();
    let crc = crc32c_raw(&ino_bytes, seed);
    let crc = crc32c_raw(&gen_bytes, crc);
    let crc = crc32c_raw(&inode_raw[..124], crc);
    let crc = crc32c_raw(&[0, 0], crc);
    let crc = crc32c_raw(&inode_raw[126..128.min(inode_raw.len())], crc);

    if inode_size > 128 && inode_raw.len() > 128 {
        let extra_start = 128usize;
        let extra_end = (inode_size as usize).min(inode_raw.len());
        if extra_end > extra_start + 4 {
            let crc = crc32c_raw(&inode_raw[extra_start..130], crc);
            let crc = crc32c_raw(&[0, 0], crc);
            if extra_end > 132 {
                return crc32c_raw(&inode_raw[132..extra_end], crc);
            }
            return crc;
        }
        return crc32c_raw(&inode_raw[extra_start..extra_end], crc);
    }

    crc
}

pub fn dir_block_checksum(
    seed: u32,
    inode_num: u32,
    generation: u32,
    block_data: &[u8],
    block_size: u32,
) -> u32 {
    let ino_bytes = inode_num.to_le_bytes();
    let gen_bytes = generation.to_le_bytes();
    let crc = crc32c_raw(&ino_bytes, seed);
    let crc = crc32c_raw(&gen_bytes, crc);
    let end = (block_size as usize)
        .saturating_sub(12)
        .min(block_data.len());
    crc32c_raw(&block_data[..end], crc)
}

pub fn group_desc_checksum(seed: u32, group_num: u32, gd_raw: &[u8]) -> u16 {
    let grp_bytes = group_num.to_le_bytes();
    let crc = crc32c_raw(&grp_bytes, seed);
    let crc = crc32c_raw(&gd_raw[..30.min(gd_raw.len())], crc);
    let crc = crc32c_raw(&[0, 0], crc);
    let crc = if gd_raw.len() > 32 {
        crc32c_raw(&gd_raw[32..], crc)
    } else {
        crc
    };
    crc as u16
}

pub fn bitmap_checksum(seed: u32, bitmap_data: &[u8]) -> u32 {
    crc32c_raw(bitmap_data, seed)
}

pub fn superblock_checksum(sb_raw: &[u8]) -> u32 {
    crc32c_raw(&sb_raw[..1020], 0xFFFFFFFF) ^ 0xFFFFFFFF
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_crc32c_known() {
        let result = crc32c(b"123456789");
        assert_eq!(result, 0xE3069283);
    }
}
