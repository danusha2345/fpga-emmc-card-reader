use crate::error::Result;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChipType {
    Emmc,
    Nand,
    Spi,
}

impl fmt::Display for ChipType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChipType::Emmc => write!(f, "eMMC"),
            ChipType::Nand => write!(f, "NAND"),
            ChipType::Spi => write!(f, "SPI"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ChipInfo {
    pub chip_type: ChipType,
    pub manufacturer: String,
    pub manufacturer_id: u8,
    pub manufacturer_country: Option<String>,
    pub product_name: String,
    pub product_series: Option<String>,
    pub nand_type: Option<String>,
    pub emmc_version: Option<String>,
    pub product_notes: Option<String>,
    pub capacity_bytes: u64,
    pub serial_number: Option<String>,
    pub revision: Option<String>,
    pub date: Option<String>,
    pub raw_id: Vec<u8>,
    // CSD register
    pub csd_raw: Option<Vec<u8>>,
    pub csd_structure: Option<u8>,
    pub csd_spec_vers: Option<u8>,
}

impl fmt::Display for ChipInfo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} {} (MID=0x{:02X})",
            self.manufacturer, self.product_name, self.manufacturer_id
        )?;
        if self.capacity_bytes > 0 {
            let gb = self.capacity_bytes as f64 / (1024.0 * 1024.0 * 1024.0);
            if gb >= 1.0 {
                write!(f, " {:.1} GB", gb)?;
            } else {
                let mb = self.capacity_bytes as f64 / (1024.0 * 1024.0);
                write!(f, " {:.0} MB", mb)?;
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct VerifyResult {
    pub total_bytes: u64,
    pub mismatches: Vec<VerifyMismatch>,
}

#[derive(Debug, Clone)]
pub struct VerifyMismatch {
    pub offset: u64,
    pub expected: u8,
    pub actual: u8,
}

impl VerifyResult {
    pub fn is_ok(&self) -> bool {
        self.mismatches.is_empty()
    }
}

#[derive(Debug, Clone)]
pub struct BlankCheckResult {
    pub total_bytes: u64,
    pub is_blank: bool,
    pub first_non_blank: Option<u64>,
}

pub trait ProgressReporter: Send + Sync {
    fn report(&self, current: u64, total: u64, description: &str);
    fn is_cancelled(&self) -> bool;
}

pub trait Programmer: Send {
    fn backend_name(&self) -> &str;
    fn supported_chip_types(&self) -> &[ChipType];
    fn identify(&mut self) -> Result<Option<ChipInfo>>;
    fn read(
        &mut self,
        addr: u64,
        len: u64,
        progress: &dyn ProgressReporter,
    ) -> Result<Vec<u8>>;
    fn write(
        &mut self,
        addr: u64,
        data: &[u8],
        progress: &dyn ProgressReporter,
    ) -> Result<()>;
    fn erase(
        &mut self,
        addr: u64,
        len: u64,
        progress: &dyn ProgressReporter,
    ) -> Result<()>;
    fn verify(
        &mut self,
        addr: u64,
        expected: &[u8],
        progress: &dyn ProgressReporter,
    ) -> Result<VerifyResult>;
    fn blank_check(
        &mut self,
        addr: u64,
        len: u64,
        progress: &dyn ProgressReporter,
    ) -> Result<BlankCheckResult>;
    fn extensions(&mut self) -> Option<&mut dyn ProgrammerExt> {
        None
    }
}

pub trait ProgrammerExt: Send {
    fn set_partition(&mut self, id: u8) -> Result<()>;
    fn read_ext_csd(&mut self) -> Result<Vec<u8>>;
    fn send_raw_command(&mut self, cmd: u8, arg: u32, flags: u8) -> Result<Vec<u8>>;
    fn set_speed(&mut self, preset: u8) -> Result<()>;
    fn set_baud(&mut self, preset: u8) -> Result<()>;
    fn set_bus_width(&mut self, width: u8) -> Result<()>;
    fn reinit(&mut self) -> Result<()>;
}
