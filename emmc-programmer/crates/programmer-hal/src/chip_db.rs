use serde::Deserialize;
use std::collections::HashMap;

#[derive(Debug, Deserialize)]
struct ManufacturerEntry {
    id: u8,
    name: String,
    country: String,
}

#[derive(Debug, Clone, Deserialize)]
struct ProductEntry {
    mid: u8,
    name: String,
    series: String,
    nand: String,
    emmc_ver: String,
    notes: String,
}

#[derive(Debug, Deserialize)]
struct ChipDbFile {
    manufacturers: Vec<ManufacturerEntry>,
    products: Vec<ProductEntry>,
}

#[derive(Debug, Clone)]
pub struct ManufacturerInfo {
    pub name: String,
    pub country: String,
}

#[derive(Debug, Clone)]
pub struct ProductInfo {
    pub series: String,
    pub nand: String,
    pub emmc_ver: String,
    pub notes: String,
}

pub struct ChipDatabase {
    manufacturers: HashMap<u8, ManufacturerInfo>,
    products: Vec<ProductEntry>,
}

impl ChipDatabase {
    pub fn builtin() -> Self {
        let json = include_str!("chip_db.json");
        let db: ChipDbFile =
            serde_json::from_str(json).expect("built-in chip_db.json parse error");

        let mut manufacturers = HashMap::new();
        for entry in db.manufacturers {
            manufacturers.insert(
                entry.id,
                ManufacturerInfo {
                    name: entry.name,
                    country: entry.country,
                },
            );
        }

        Self {
            manufacturers,
            products: db.products,
        }
    }

    pub fn manufacturer_name(&self, mid: u8) -> Option<&str> {
        self.manufacturers.get(&mid).map(|m| m.name.as_str())
    }

    pub fn manufacturer_info(&self, mid: u8) -> Option<&ManufacturerInfo> {
        self.manufacturers.get(&mid)
    }

    pub fn lookup_product(&self, mid: u8, product_name: &str) -> Option<ProductInfo> {
        // Try exact match first
        if let Some(p) = self
            .products
            .iter()
            .find(|p| p.mid == mid && p.name == product_name)
        {
            return Some(ProductInfo {
                series: p.series.clone(),
                nand: p.nand.clone(),
                emmc_ver: p.emmc_ver.clone(),
                notes: p.notes.clone(),
            });
        }
        // Try prefix match (product names in CID can be truncated/padded)
        self.products
            .iter()
            .find(|p| p.mid == mid && product_name.starts_with(&p.name))
            .map(|p| ProductInfo {
                series: p.series.clone(),
                nand: p.nand.clone(),
                emmc_ver: p.emmc_ver.clone(),
                notes: p.notes.clone(),
            })
    }

    pub fn all_manufacturers(&self) -> Vec<(u8, &str)> {
        let mut list: Vec<_> = self
            .manufacturers
            .iter()
            .map(|(&id, info)| (id, info.name.as_str()))
            .collect();
        list.sort_by_key(|(id, _)| *id);
        list
    }
}

impl Default for ChipDatabase {
    fn default() -> Self {
        Self::builtin()
    }
}
