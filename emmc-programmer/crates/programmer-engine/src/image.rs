use std::path::Path;

pub struct ImageBuffer {
    pub data: Vec<u8>,
    pub path: Option<String>,
}

impl ImageBuffer {
    pub fn from_file(path: &Path) -> anyhow::Result<Self> {
        let data = std::fs::read(path)?;
        Ok(Self {
            data,
            path: Some(path.display().to_string()),
        })
    }

    pub fn save_to_file(&self, path: &Path) -> anyhow::Result<()> {
        std::fs::write(path, &self.data)?;
        Ok(())
    }

    pub fn sector_count(&self) -> usize {
        self.data.len().div_ceil(512)
    }

    pub fn diff(&self, other: &ImageBuffer) -> Vec<DiffEntry> {
        diff_slices(&self.data, &other.data)
    }
}

/// Sector-level diff of two byte slices (no cloning needed)
pub fn diff_slices(a: &[u8], b: &[u8]) -> Vec<DiffEntry> {
    let max_len = a.len().max(b.len());
    let sector_size = 512;
    let num_sectors = max_len.div_ceil(sector_size);
    let mut diffs = Vec::new();

    for sector in 0..num_sectors {
        let start = sector * sector_size;
        let end_a = (start + sector_size).min(a.len());
        let end_b = (start + sector_size).min(b.len());

        let slice_a = if start < a.len() { &a[start..end_a] } else { &[] };
        let slice_b = if start < b.len() { &b[start..end_b] } else { &[] };

        if slice_a != slice_b {
            diffs.push(DiffEntry {
                sector_lba: sector as u64,
                offset: start as u64,
            });
        }
    }
    diffs
}

#[derive(Debug, Clone)]
pub struct DiffEntry {
    pub sector_lba: u64,
    pub offset: u64,
}
