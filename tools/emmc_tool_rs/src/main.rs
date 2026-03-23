mod cli;
mod commands;
mod emmc;
mod error;
mod ext4;
mod partition;
mod protocol;
mod rpmb;
mod transport;

use std::time::Duration;

use anyhow::Result;
use clap::Parser;

use cli::{Cli, Commands};
use transport::EmmcTool;

fn main() -> Result<()> {
    let cli = Cli::parse();

    // umount doesn't need FPGA connection
    if let Commands::Umount { ref mountpoint } = cli.command {
        return commands::partition_cmds::cmd_umount(mountpoint);
    }

    let timeout = Duration::from_secs_f64(cli.timeout);
    let mut tool = EmmcTool::new(&cli.port, cli.baud, timeout)?;

    // Apply global flags
    tool.max_retries = cli.retry;
    tool.ignore_crc = cli.ignore_crc;

    // --fast: set baud 12M + eMMC clock 10MHz
    if cli.fast {
        eprintln!("Fast mode: setting baud 12M + eMMC clock 10MHz...");
        tool.set_baud(3)?; // 12M
        tool.set_clk_speed(3)?; // 10MHz
    }

    let result = run_command(&cli, &mut tool);

    // --fast: restore defaults after command
    if cli.fast {
        eprintln!("Restoring defaults: baud 3M + eMMC clock 2MHz...");
        let _ = tool.set_clk_speed(0);
        let _ = tool.set_baud(0);
    }

    result
}

fn run_command(cli: &Cli, tool: &mut EmmcTool) -> Result<()> {
    match &cli.command {
        Commands::Ping => commands::core::cmd_ping(tool),
        Commands::Info => commands::core::cmd_info(tool),
        Commands::Read { lba, count, outfile } => {
            commands::core::cmd_read(tool, lba, count, outfile)
        }
        Commands::Write { lba, infile } => {
            commands::core::cmd_write(tool, lba, infile)
        }
        Commands::Dump { outfile } => {
            commands::core::cmd_dump(tool, outfile)
        }
        Commands::Hexdump { lba, count } => {
            commands::core::cmd_hexdump(tool, lba, count)
        }
        Commands::Verify { lba, infile } => {
            commands::core::cmd_verify(tool, lba, infile)
        }
        Commands::Status => commands::core::cmd_status(tool),
        Commands::Extcsd { raw } => commands::core::cmd_extcsd(tool, *raw),
        Commands::Setpart { partition } => {
            commands::core::cmd_set_partition(tool, partition)
        }
        Commands::Partitions => commands::partition_cmds::cmd_partitions(tool),
        Commands::Mount { partition, mountpoint } => {
            commands::partition_cmds::cmd_mount(tool, *partition, mountpoint)
        }
        Commands::Umount { .. } => unreachable!(),
        // Phase 2: Simple FPGA commands
        Commands::Erase { lba, count, confirm } => {
            commands::core::cmd_erase(tool, lba, count, *confirm)
        }
        Commands::SecureErase { lba, count, confirm } => {
            commands::core::cmd_secure_erase(tool, lba, count, *confirm)
        }
        Commands::WriteExtcsd { index, value, confirm } => {
            commands::core::cmd_write_extcsd(tool, index, value, *confirm)
        }
        Commands::CardStatus => commands::core::cmd_card_status(tool),
        Commands::Reinit => commands::core::cmd_reinit(tool),
        Commands::SetClock { speed } => commands::core::cmd_set_clock(tool, speed),
        Commands::SetBaud { preset } => commands::core::cmd_set_baud(tool, preset),
        Commands::BusWidth { width } => commands::core::cmd_bus_width(tool, width),
        Commands::RawCmd { index, arg, flags } => {
            commands::core::cmd_raw_cmd(tool, index, arg, flags)
        }
        Commands::CacheFlush => commands::core::cmd_cache_flush(tool),
        Commands::BootConfig { partition, ack } => {
            commands::core::cmd_boot_config(tool, partition, *ack)
        }

        // Phase 3: restore + recover
        Commands::Restore { infile, verify } => {
            commands::core::cmd_restore(tool, infile, *verify)
        }
        Commands::Recover => commands::core::cmd_recover(tool),

        // Phase 4: ext4 commands
        Commands::Ext4Info { partition } => {
            commands::ext4_cmds::cmd_ext4_info(tool, partition.as_deref())
        }
        Commands::Ext4Ls { path, partition } => {
            commands::ext4_cmds::cmd_ext4_ls(tool, path, partition.as_deref())
        }
        Commands::Ext4Cat { path, output, partition } => {
            commands::ext4_cmds::cmd_ext4_cat(tool, path, output.as_deref(), partition.as_deref())
        }
        Commands::Ext4Write { path, data_hex, infile, confirm, partition } => {
            commands::ext4_cmds::cmd_ext4_write(tool, path, data_hex.as_deref(), infile.as_deref(), *confirm, partition.as_deref())
        }
        Commands::Ext4Create { parent, name, data_hex, confirm, partition } => {
            commands::ext4_cmds::cmd_ext4_create(tool, parent, name, data_hex.as_deref(), *confirm, partition.as_deref())
        }

        // Phase 6: RPMB commands
        Commands::RpmbCounter => commands::rpmb_cmds::cmd_rpmb_counter(tool),
        Commands::RpmbRead { address, hex } => {
            commands::rpmb_cmds::cmd_rpmb_read(tool, address, *hex)
        }
        Commands::RpmbDump { outfile } => {
            commands::rpmb_cmds::cmd_rpmb_dump(tool, outfile)
        }
    }
}
