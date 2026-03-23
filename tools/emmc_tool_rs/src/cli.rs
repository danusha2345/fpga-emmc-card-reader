use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "emmc_tool", about = "eMMC Card Reader Tool for Tang Nano 9K")]
pub struct Cli {
    /// Serial port
    #[arg(short = 'p', long, default_value = "/dev/ttyACM0")]
    pub port: String,

    /// Timeout in seconds
    #[arg(short = 't', long, default_value_t = 5.0)]
    pub timeout: f64,

    /// Baud rate (default 3000000, try 2000000 if unstable)
    #[arg(short = 'b', long, default_value_t = 3_000_000)]
    pub baud: u32,

    /// Fast mode: set baud 12M + eMMC clock 10MHz automatically
    #[arg(long)]
    pub fast: bool,

    /// Number of retries on error (exponential backoff)
    #[arg(long, default_value_t = 0)]
    pub retry: u32,

    /// Ignore CRC mismatches (warn instead of error)
    #[arg(long)]
    pub ignore_crc: bool,

    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Test connection
    Ping,

    /// Read eMMC CID/CSD
    Info,

    /// Read sectors to file
    Read {
        /// Start LBA (decimal or 0x hex)
        lba: String,
        /// Number of sectors
        count: String,
        /// Output file
        outfile: String,
    },

    /// Write file to sectors
    Write {
        /// Start LBA (decimal or 0x hex)
        lba: String,
        /// Input file
        infile: String,
    },

    /// Full eMMC dump
    Dump {
        /// Output file
        outfile: String,
    },

    /// Hex dump sectors
    Hexdump {
        /// Start LBA (decimal or 0x hex)
        lba: String,
        /// Number of sectors (default: 1)
        #[arg(default_value = "1")]
        count: String,
    },

    /// Verify eMMC data against file
    Verify {
        /// Start LBA (decimal or 0x hex)
        lba: String,
        /// File to compare against
        infile: String,
    },

    /// Controller status
    Status,

    /// Show partition table
    Partitions,

    /// Read Extended CSD (512-byte info)
    Extcsd {
        /// Show raw bytes
        #[arg(long)]
        raw: bool,
    },

    /// Switch partition (user/boot0/boot1/rpmb)
    Setpart {
        /// Partition: user, boot0, boot1, rpmb, or 0-3
        partition: String,
    },

    /// Dump partition & loop-mount
    Mount {
        /// Partition number
        partition: i32,
        /// Mount point directory
        mountpoint: String,
    },

    /// Unmount & cleanup
    Umount {
        /// Mount point to unmount
        mountpoint: String,
    },

    // === Phase 2: Simple FPGA commands ===

    /// Erase sectors
    Erase {
        /// Start LBA (decimal or 0x hex)
        lba: String,
        /// Number of sectors
        count: String,
        /// Actually erase
        #[arg(long)]
        confirm: bool,
    },

    /// Secure erase sectors (trim)
    SecureErase {
        /// Start LBA (decimal or 0x hex)
        lba: String,
        /// Number of sectors
        count: String,
        /// Actually erase
        #[arg(long)]
        confirm: bool,
    },

    /// Write ExtCSD register
    WriteExtcsd {
        /// ExtCSD index (0-511)
        index: String,
        /// Value (0-255)
        value: String,
        /// Actually write
        #[arg(long)]
        confirm: bool,
    },

    /// Read eMMC card status register (CMD13)
    CardStatus,

    /// Reinitialize eMMC card
    Reinit,

    /// Set eMMC clock speed
    SetClock {
        /// Speed in MHz or preset number (0-6)
        speed: String,
    },

    /// Set UART baud rate
    SetBaud {
        /// Preset: 0=3M, 1=6M, 2=9M, 3=12M
        preset: String,
    },

    /// Set eMMC bus width
    BusWidth {
        /// 1 or 4
        width: String,
    },

    /// Send raw eMMC command
    RawCmd {
        /// CMD index (0-63)
        index: String,
        /// Argument (32-bit, decimal or 0x hex)
        arg: String,
        /// Flags: bit0=expect_data, bit1=write, bit2=long_response
        #[arg(default_value = "0")]
        flags: String,
    },

    /// Flush eMMC cache
    CacheFlush,

    /// Configure boot partition
    BootConfig {
        /// Boot partition: none, boot0, boot1
        partition: String,
        /// Enable boot ACK
        #[arg(long)]
        ack: bool,
    },

    // === Phase 3: restore + recover ===

    /// Restore full eMMC from image file
    Restore {
        /// Input image file
        infile: String,
        /// Verify after write
        #[arg(long)]
        verify: bool,
    },

    /// Attempt to recover unresponsive eMMC card
    Recover,

    // === Phase 4: ext4 commands ===

    /// Show ext4 filesystem info
    Ext4Info {
        /// Partition number or name
        #[arg(short = 'P', long)]
        partition: Option<String>,
    },

    /// List directory on ext4 partition
    Ext4Ls {
        /// Path to list (default: /)
        #[arg(default_value = "/")]
        path: String,
        /// Partition number or name
        #[arg(short = 'P', long)]
        partition: Option<String>,
    },

    /// Read file from ext4 partition
    Ext4Cat {
        /// File path
        path: String,
        /// Output file (default: stdout hex)
        #[arg(short = 'o', long)]
        output: Option<String>,
        /// Partition number or name
        #[arg(short = 'P', long)]
        partition: Option<String>,
    },

    /// Write data to existing file on ext4 partition
    Ext4Write {
        /// File path on ext4
        path: String,
        /// Hex data string (e.g. "48656c6c6f")
        #[arg(long)]
        data_hex: Option<String>,
        /// Input file
        #[arg(long)]
        infile: Option<String>,
        /// Actually write
        #[arg(long)]
        confirm: bool,
        /// Partition number or name
        #[arg(short = 'P', long)]
        partition: Option<String>,
    },

    /// Create new file on ext4 partition
    Ext4Create {
        /// Parent directory path
        parent: String,
        /// New file name
        name: String,
        /// Hex data for new file
        #[arg(long)]
        data_hex: Option<String>,
        /// Actually create
        #[arg(long)]
        confirm: bool,
        /// Partition number or name
        #[arg(short = 'P', long)]
        partition: Option<String>,
    },

    // === Phase 6: RPMB commands ===

    /// Read RPMB write counter
    RpmbCounter,

    /// Authenticated RPMB read
    RpmbRead {
        /// RPMB half-sector address
        address: String,
        /// Show hex dump
        #[arg(long)]
        hex: bool,
    },

    /// Dump all RPMB data
    RpmbDump {
        /// Output file
        outfile: String,
    },
}
