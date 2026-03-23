use std::fmt;

/// Parsed CID register
#[derive(Debug, Clone)]
pub struct CidInfo {
    pub manufacturer_id: u8,
    pub device_type: u16,
    pub product_name: String,
    pub product_rev: String,
    pub serial_number: u32,
    pub mfg_date: String,
    pub raw: Vec<u8>,
}

impl CidInfo {
    pub fn parse(data: &[u8]) -> Self {
        assert!(data.len() >= 16);
        Self {
            manufacturer_id: data[0],
            device_type: ((data[1] as u16) << 8) | data[2] as u16,
            product_name: String::from_utf8_lossy(&data[3..9]).trim().to_string(),
            product_rev: format!("{}.{}", data[9] >> 4, data[9] & 0x0F),
            serial_number: u32::from_be_bytes([data[10], data[11], data[12], data[13]]),
            mfg_date: format!("{}-{:02}", 2013 + (data[14] >> 4) as u16, data[14] & 0x0F),
            raw: data[..16].to_vec(),
        }
    }

    pub fn manufacturer_name(&self) -> &str {
        match self.manufacturer_id {
            0x11 => "Toshiba",
            0x13 => "Micron",
            0x15 => "Samsung",
            0x45 => "SanDisk",
            0x90 => "SK Hynix",
            0xFE => "Micron",
            _ => "Unknown",
        }
    }
}

impl fmt::Display for CidInfo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} {} (MID=0x{:02X}, SN={}, Rev={}, Date={})",
            self.manufacturer_name(),
            self.product_name,
            self.manufacturer_id,
            self.serial_number,
            self.product_rev,
            self.mfg_date
        )
    }
}

/// Parsed CSD register
#[derive(Debug, Clone)]
pub struct CsdInfo {
    pub structure: u8,
    pub spec_vers: u8,
    pub read_bl_len: u8,
    pub capacity_bytes: Option<u64>,
    pub capacity_note: Option<String>,
    pub raw: Vec<u8>,
}

impl CsdInfo {
    pub fn parse(data: &[u8]) -> Self {
        assert!(data.len() >= 16);
        let structure = (data[0] >> 6) & 0x03;
        let spec_vers = (data[0] >> 2) & 0x0F;
        let read_bl_len = data[5] & 0x0F;
        let c_size =
            (((data[6] & 0x03) as u32) << 10) | ((data[7] as u32) << 2) | ((data[8] as u32) >> 6);
        let c_size_mult = (((data[9] & 0x03) as u32) << 1) | ((data[10] as u32) >> 7);

        let (capacity_bytes, capacity_note) = if c_size == 0xFFF {
            (
                None,
                Some(">= 2 GB (need EXT_CSD for exact size)".to_string()),
            )
        } else {
            let blocks = (c_size + 1) * (1 << (c_size_mult + 2));
            (Some(blocks as u64 * (1u64 << read_bl_len)), None)
        };

        Self {
            structure,
            spec_vers,
            read_bl_len,
            capacity_bytes,
            capacity_note,
            raw: data[..16].to_vec(),
        }
    }
}

/// Parsed Extended CSD (512 bytes)
#[derive(Debug, Clone)]
pub struct ExtCsdInfo {
    pub sec_count: u32,
    pub capacity_bytes: u64,
    pub boot_partition_size: u64,
    pub rpmb_size: u64,
    pub boot_ack: bool,
    pub boot_partition: u8,
    pub partition_access: u8,
    pub hs_support: bool,
    pub hs52_support: bool,
    pub ddr_support: bool,
    pub life_time_est_a: u8,
    pub life_time_est_b: u8,
    pub pre_eol_info: u8,
    pub fw_version: String,
    pub raw: Vec<u8>,
}

impl ExtCsdInfo {
    pub fn parse(data: &[u8]) -> Self {
        assert!(data.len() >= 512);

        let sec_count = u32::from_le_bytes([data[212], data[213], data[214], data[215]]);
        let boot_size_multi = data[226] as u64;
        let rpmb_size_mult = data[168] as u64;
        let part_config = data[179];
        let device_type = data[196];

        Self {
            sec_count,
            capacity_bytes: sec_count as u64 * 512,
            boot_partition_size: boot_size_multi * 128 * 1024,
            rpmb_size: rpmb_size_mult * 128 * 1024,
            boot_ack: (part_config >> 6) & 0x01 != 0,
            boot_partition: (part_config >> 3) & 0x07,
            partition_access: part_config & 0x07,
            hs_support: device_type & 0x01 != 0,
            hs52_support: device_type & 0x02 != 0,
            ddr_support: device_type & 0x04 != 0,
            life_time_est_a: data[267],
            life_time_est_b: data[268],
            pre_eol_info: data[269],
            fw_version: hex::encode(&data[254..262]),
            raw: data[..512].to_vec(),
        }
    }

    pub fn capacity_human(&self) -> String {
        format_size(self.capacity_bytes)
    }

    pub fn boot_size_human(&self) -> String {
        format_size(self.boot_partition_size)
    }

    pub fn rpmb_size_human(&self) -> String {
        format_size(self.rpmb_size)
    }

    pub fn life_time_str(val: u8) -> &'static str {
        match val {
            0 => "Not defined",
            1 => "0-10% used",
            2 => "10-20% used",
            3 => "20-30% used",
            4 => "30-40% used",
            5 => "40-50% used",
            6 => "50-60% used",
            7 => "60-70% used",
            8 => "70-80% used",
            9 => "80-90% used",
            10 => "90-100% used",
            11 => "Exceeded",
            _ => "Reserved",
        }
    }

    pub fn pre_eol_str(val: u8) -> &'static str {
        match val {
            0 => "Not defined",
            1 => "Normal",
            2 => "Warning",
            3 => "Urgent",
            _ => "Reserved",
        }
    }
}

pub fn format_size(bytes: u64) -> String {
    if bytes >= 1024 * 1024 * 1024 {
        format!("{:.1} GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    } else if bytes >= 1024 * 1024 {
        format!("{:.0} MB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.0} KB", bytes as f64 / 1024.0)
    } else {
        format!("{} B", bytes)
    }
}

/// Simple hex encode (avoid extra dependency)
mod hex {
    pub fn encode(data: &[u8]) -> String {
        data.iter().map(|b| format!("{:02x}", b)).collect()
    }
}
