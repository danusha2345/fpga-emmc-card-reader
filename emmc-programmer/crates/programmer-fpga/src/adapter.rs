use emmc_core::card_info::{CidInfo, CsdInfo};
use emmc_core::protocol::{EmmcConnection, SECTOR_SIZE};
use programmer_hal::chip_db::ChipDatabase;
use programmer_hal::error::{ProgrammerError, Result};
use programmer_hal::traits::*;

pub struct FpgaUartProgrammer {
    conn: EmmcConnection,
    port_name: String,
    baud: u32,
}

impl FpgaUartProgrammer {
    pub fn connect(port: &str, baud: u32) -> Result<Self> {
        let conn = EmmcConnection::connect(port, baud)
            .map_err(|e| ProgrammerError::Connection(e.to_string()))?;
        Ok(Self {
            conn,
            port_name: port.to_string(),
            baud,
        })
    }

    pub fn port_name(&self) -> &str {
        &self.port_name
    }

    pub fn baud(&self) -> u32 {
        self.baud
    }

    pub fn connection(&mut self) -> &mut EmmcConnection {
        &mut self.conn
    }
}

impl Programmer for FpgaUartProgrammer {
    fn backend_name(&self) -> &str {
        "FPGA UART"
    }

    fn supported_chip_types(&self) -> &[ChipType] {
        &[ChipType::Emmc]
    }

    fn identify(&mut self) -> Result<Option<ChipInfo>> {
        self.conn
            .ping()
            .map_err(|e| ProgrammerError::Communication(e.to_string()))?;

        let (cid_raw, csd_raw) = self
            .conn
            .get_info()
            .map_err(|e| ProgrammerError::Communication(e.to_string()))?;

        let cid = CidInfo::parse(&cid_raw);
        let csd = CsdInfo::parse(&csd_raw);

        let capacity = match self.conn.get_ext_csd() {
            Ok(ext) => {
                let sec_count =
                    u32::from_le_bytes([ext[212], ext[213], ext[214], ext[215]]);
                sec_count as u64 * 512
            }
            Err(_) => 0,
        };

        // Look up manufacturer and product in chip database
        let db = ChipDatabase::builtin();
        let mfr_info = db.manufacturer_info(cid.manufacturer_id);
        let product_info = db.lookup_product(cid.manufacturer_id, &cid.product_name);

        let manufacturer = mfr_info
            .map(|m| m.name.clone())
            .unwrap_or_else(|| cid.manufacturer_name().to_string());
        let manufacturer_country = mfr_info.map(|m| m.country.clone());

        Ok(Some(ChipInfo {
            chip_type: ChipType::Emmc,
            manufacturer,
            manufacturer_id: cid.manufacturer_id,
            manufacturer_country,
            product_name: cid.product_name.clone(),
            product_series: product_info.as_ref().map(|p| p.series.clone()),
            nand_type: product_info.as_ref().map(|p| p.nand.clone()),
            emmc_version: product_info.as_ref().map(|p| p.emmc_ver.clone()),
            product_notes: product_info.map(|p| p.notes),
            capacity_bytes: capacity,
            serial_number: Some(cid.serial_number.to_string()),
            revision: Some(cid.product_rev.clone()),
            date: Some(cid.mfg_date.clone()),
            raw_id: cid.raw.clone(),
            csd_raw: Some(csd.raw.clone()),
            csd_structure: Some(csd.structure),
            csd_spec_vers: Some(csd.spec_vers),
        }))
    }

    fn read(
        &mut self,
        addr: u64,
        len: u64,
        progress: &dyn ProgressReporter,
    ) -> Result<Vec<u8>> {
        let start_lba = (addr / SECTOR_SIZE as u64) as u32;
        let total_sectors =
            len.div_ceil(SECTOR_SIZE as u64) as u32;
        let chunk_size: u16 = 64;

        let mut data = Vec::with_capacity(len as usize);
        let mut sectors_read = 0u32;

        while sectors_read < total_sectors {
            if progress.is_cancelled() {
                return Err(ProgrammerError::Cancelled);
            }

            let remaining = total_sectors - sectors_read;
            let n = remaining.min(chunk_size as u32) as u16;
            let lba = start_lba + sectors_read;

            let chunk = self
                .conn
                .read_sectors(lba, n)
                .map_err(|e| ProgrammerError::Communication(e.to_string()))?;

            data.extend_from_slice(&chunk);
            sectors_read += n as u32;

            progress.report(
                sectors_read as u64,
                total_sectors as u64,
                "Reading...",
            );
        }

        data.truncate(len as usize);
        Ok(data)
    }

    fn write(
        &mut self,
        addr: u64,
        data: &[u8],
        progress: &dyn ProgressReporter,
    ) -> Result<()> {
        let start_lba = (addr / SECTOR_SIZE as u64) as u32;
        let total_sectors =
            data.len().div_ceil(SECTOR_SIZE) as u32;
        let chunk_size = 16usize; // FPGA FIFO limit

        let mut sectors_written = 0u32;
        let mut offset = 0usize;

        while sectors_written < total_sectors {
            if progress.is_cancelled() {
                return Err(ProgrammerError::Cancelled);
            }

            let remaining = (total_sectors - sectors_written) as usize;
            let n = remaining.min(chunk_size);
            let end = (offset + n * SECTOR_SIZE).min(data.len());
            let chunk = &data[offset..end];
            let lba = start_lba + sectors_written;

            self.conn
                .write_sectors(lba, chunk)
                .map_err(|e| ProgrammerError::Communication(e.to_string()))?;

            sectors_written += n as u32;
            offset += n * SECTOR_SIZE;

            progress.report(
                sectors_written as u64,
                total_sectors as u64,
                "Writing...",
            );
        }

        Ok(())
    }

    fn erase(
        &mut self,
        addr: u64,
        len: u64,
        progress: &dyn ProgressReporter,
    ) -> Result<()> {
        let start_lba = (addr / SECTOR_SIZE as u64) as u32;
        let total_sectors =
            len.div_ceil(SECTOR_SIZE as u64) as u32;
        let max_chunk = 0xFFFFu16;
        let mut sectors_erased = 0u32;

        while sectors_erased < total_sectors {
            if progress.is_cancelled() {
                return Err(ProgrammerError::Cancelled);
            }

            let remaining = total_sectors - sectors_erased;
            let n = remaining.min(max_chunk as u32) as u16;
            let lba = start_lba + sectors_erased;

            self.conn
                .erase(lba, n)
                .map_err(|e| ProgrammerError::Communication(e.to_string()))?;

            sectors_erased += n as u32;
            progress.report(
                sectors_erased as u64,
                total_sectors as u64,
                "Erasing...",
            );
        }

        Ok(())
    }

    fn verify(
        &mut self,
        addr: u64,
        expected: &[u8],
        progress: &dyn ProgressReporter,
    ) -> Result<VerifyResult> {
        let actual = self.read(addr, expected.len() as u64, progress)?;
        let mut mismatches = Vec::new();

        for (i, (&exp, &act)) in expected.iter().zip(actual.iter()).enumerate() {
            if exp != act {
                mismatches.push(VerifyMismatch {
                    offset: addr + i as u64,
                    expected: exp,
                    actual: act,
                });
            }
        }

        Ok(VerifyResult {
            total_bytes: expected.len() as u64,
            mismatches,
        })
    }

    fn blank_check(
        &mut self,
        addr: u64,
        len: u64,
        progress: &dyn ProgressReporter,
    ) -> Result<BlankCheckResult> {
        let data = self.read(addr, len, progress)?;
        let first_non_blank =
            data.iter().position(|&b| b != 0x00 && b != 0xFF);

        Ok(BlankCheckResult {
            total_bytes: len,
            is_blank: first_non_blank.is_none(),
            first_non_blank: first_non_blank.map(|p| addr + p as u64),
        })
    }

    fn extensions(&mut self) -> Option<&mut dyn ProgrammerExt> {
        Some(self)
    }
}

impl ProgrammerExt for FpgaUartProgrammer {
    fn set_partition(&mut self, id: u8) -> Result<()> {
        self.conn
            .set_partition(id)
            .map_err(|e| ProgrammerError::Communication(e.to_string()))
    }

    fn read_ext_csd(&mut self) -> Result<Vec<u8>> {
        self.conn
            .get_ext_csd()
            .map_err(|e| ProgrammerError::Communication(e.to_string()))
    }

    fn send_raw_command(
        &mut self,
        cmd: u8,
        arg: u32,
        flags: u8,
    ) -> Result<Vec<u8>> {
        let resp = flags & 1 != 0;
        let long = flags & 2 != 0;
        let busy = flags & 4 != 0;
        let (_status, data) = self
            .conn
            .send_raw_cmd(cmd, arg, resp, long, busy)
            .map_err(|e| ProgrammerError::Communication(e.to_string()))?;
        Ok(data)
    }

    fn set_speed(&mut self, preset: u8) -> Result<()> {
        self.conn
            .set_clk_speed(preset)
            .map_err(|e| ProgrammerError::Communication(e.to_string()))
    }

    fn set_baud(&mut self, preset: u8) -> Result<()> {
        self.conn
            .set_baud(preset)
            .map_err(|e| ProgrammerError::Communication(e.to_string()))
    }

    fn set_bus_width(&mut self, width: u8) -> Result<()> {
        self.conn
            .set_bus_width(width)
            .map_err(|e| ProgrammerError::Communication(e.to_string()))
    }

    fn reinit(&mut self) -> Result<()> {
        self.conn
            .reinit()
            .map_err(|e| ProgrammerError::Communication(e.to_string()))
    }
}
