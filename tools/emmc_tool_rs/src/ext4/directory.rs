use super::Ext4DirEntry;

pub fn parse_dir_entries(data: &[u8], block_size: u32) -> Vec<Ext4DirEntry> {
    let mut entries = Vec::new();
    let mut offset = 0usize;
    let limit = block_size as usize;

    while offset + 8 <= data.len() && offset < limit {
        let inode = u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap());
        let rec_len = u16::from_le_bytes([data[offset + 4], data[offset + 5]]) as usize;
        let name_len = data[offset + 6] as usize;
        let file_type = data[offset + 7];

        if rec_len == 0 { break; }

        let min_rec_len = align4(8 + name_len);
        let effective_rec_len = if inode != 0 && name_len > 0 && rec_len < min_rec_len {
            min_rec_len
        } else {
            rec_len
        };

        if offset + effective_rec_len > limit { break; }

        if inode != 0 && name_len > 0 && offset + 8 + name_len <= data.len() {
            let name = String::from_utf8_lossy(&data[offset + 8..offset + 8 + name_len]).to_string();
            if file_type != 0xDE {
                entries.push(Ext4DirEntry {
                    inode, name, file_type, rec_len: effective_rec_len as u16,
                });
            }
        }

        offset += effective_rec_len;
    }

    entries
}

fn align4(n: usize) -> usize {
    (n + 3) & !3
}
