# Data Integrity Verification Mechanisms

Full map of all data integrity checks from eMMC chip to user application.

```
eMMC chip <--CRC7(CMD) + CRC16(DAT)--> FPGA <--CRC8(UART)--> PC (Python/Rust)
                                                                 |
                                                       verify / compare / RPMB MAC
```

---

## Level 1: Verilog RTL (FPGA)

### 1.1 CRC-7 on CMD line

- **Polynomial:** x^7 + x^3 + 1 (0x09), serial 1-bit/cycle
- **Files:** `src/emmc_crc7.v:24-30`, `src/emmc_cmd.v`
- **TX:** Generated for bits[47:8] of 48-bit CMD frame (`emmc_cmd.v:146-147`)
- **RX:** `crc_out != rx_shift[7:1]` -> `cmd_crc_err` (`emmc_cmd.v:237-238`)
- **R2 exception:** CRC-en not asserted during S_RECV when `resp_long==1` (`emmc_cmd.v:220`)
- **R3/CMD1 exception:** CRC check executes but `cmd_crc_err` is **ignored** during SI_CMD1_WAIT state (`emmc_init.v:288`)

### 1.2 CRC-16 on DAT line

- **Polynomial:** x^16 + x^12 + x^5 + 1 (0x1021 CCITT), serial 1-bit/cycle
- **Files:** `src/emmc_crc16.v:28,35`, `src/emmc_dat.v`
- **2 instances:** `u_crc16` (read, `emmc_dat.v:81`) and `u_wr_crc16` (write, `emmc_dat.v:96`)
- **READ:** `crc_recv != crc_out` -> `rd_crc_err` (`emmc_dat.v:230-231`, state S_RD_END)
- **WRITE:** CRC status token `3'b010` = OK (`emmc_dat.v:337`, state S_WR_CRC_STAT); else `wr_crc_err`

### 1.3 CRC-8 on UART

- **Polynomial:** x^8 + x^2 + x + 1 (0x07), parallel 8-bit/cycle
- **Files:** `src/crc8.v:22-29`, `src/uart_bridge.v`
- **RX coverage:** CMD_ID (`:469`) + LEN_H (`:477`) + LEN_L (`:485`) + PAYLOAD (`:499`). Header `0xAA` excluded (sync marker, triggers `crc_clear` at `:460`)
- **TX coverage:** CMD_ID (`:861-862`) + STATUS (`:871-872`) + LEN_H (`:881-882`) + LEN_L (`:891-892`) + PAYLOAD (`:909-923`). Header `0x55` excluded
- **RX check:** `rx_crc_match <= (rx_data == rx_crc_out)` (`uart_bridge.v:578`, state RX_CRC)
- **Enforcement:** `if (rx_crc_match)` at `uart_bridge.v:586` (state RX_EXEC1); on mismatch -> `tx_status <= STATUS_ERR_CRC` (`:602`), command **NOT** executed

### 1.4 Error counters and timeouts

**4 saturating 8-bit counters** (`emmc_controller.v:437-440`):

| Counter | Declaration | Increment |
|---------|------------|-----------|
| `err_cmd_timeout_cnt` | `:437` | `:460` |
| `err_cmd_crc_cnt` | `:438` | `:461` |
| `err_dat_rd_cnt` | `:439` | `:466` |
| `err_dat_wr_cnt` | `:440` | `:467` |

All reset to 0 on REINIT (`emmc_controller.v:453-458`).

**CMD timeout:** `timeout_cnt == 16'd1023` -> `cmd_timeout_flag` (`emmc_cmd.v:196-197`) = **1024 cycles**

**DAT timeout:** `timeout_cnt == 16'hFFFE` -> `timeout_flag` (`emmc_dat.v:183-184`) = **65534 cycles**. Same for write busy (`emmc_dat.v:355-356`).

**Init retry:** `MAX_CMD1_RETRIES = 16'd1400` (`emmc_init.v:56`). Auto-reinit: `boot_retry_cnt < 2'd3` (`emmc_controller.v:718-720`) = **3 full retries**.

### 1.5 MC_ERROR state

**NOT fatal** (corrected from plan). MC_ERROR is **transient**:
- Multi-block: sends CMD12 STOP -> MC_ERROR_STOP -> `cmd_ready` -> **MC_READY** (`emmc_controller.v:1254-1276`)
- Single-block: immediately `resp_valid`, `cmd_ready` -> **MC_READY** (`emmc_controller.v:1262-1264`)

Returns to MC_READY without reinit. Status reported as `STATUS_EMMC_ERR` (0x03) (`emmc_controller.v:388`).

### 1.6 Metastability protection

2-stage FF synchronizers for CMD and DAT inputs (`emmc_controller.v:157-177`):
```
cmd_in_raw -> cmd_in_meta -> cmd_in_sync  (lines 169-170)
dat_in_raw -> dat_in_meta -> dat_in_sync  (lines 171-172)
```

---

## Level 2: Python CLI (emmc_tool.py)

### 2.1 CRC-8 UART packets

- **Function:** `crc8()` (`emmc_tool.py:207-217`) — polynomial 0x07, init 0x00
- **TX coverage:** CMD + LEN_H + LEN_L + PAYLOAD (`emmc_tool.py:285-286`)
- **RX coverage:** CMD + STATUS + LEN_H + LEN_L + PAYLOAD (`emmc_tool.py:329-330`)
- **Enforcement:** `RuntimeError` on mismatch; `--ignore-crc` flag downgrades to WARNING (`emmc_tool.py:331-336`)
- **Header scanning:** `_recv_response()` scans for `0x55` sync byte in a loop (`emmc_tool.py:299-305`), not exact 5-byte read

### 2.2 Retry with exponential backoff

- **Function:** `_with_retry()` (`emmc_tool.py:262-275`)
- **Delay:** `0.1 * (2 ** attempt)` seconds (`emmc_tool.py:271`)
- **Activation:** `--retry N` (default 0 = disabled) (`emmc_tool.py:234`)
- **On retry:** `reset_input_buffer()` to clear garbage (`emmc_tool.py:274`)

### 2.3 Status codes

5 codes (`emmc_tool.py:116-128`):

| Code | Name | Value |
|------|------|-------|
| STATUS_OK | OK | 0x00 |
| STATUS_ERR_CRC | CRC Error | 0x01 |
| STATUS_ERR_CMD | Unknown CMD | 0x02 |
| STATUS_ERR_EMMC | eMMC Error | 0x03 |
| STATUS_BUSY | Busy | 0x04 |

Every response checks status; non-OK raises `RuntimeError`.

### 2.4 `verify` command

- **Location:** `emmc_tool.py:1059-1135`
- **Chunk size:** 64 sectors (`_safe_read_chunk()`, `:245`)
- **Comparison:** per-sector 512-byte slice comparison (not byte-by-byte)
- **`--fast`:** auto 10MHz + 12Mbaud (`:1063-1068`)
- **On mismatch:** prints LBA, `sys.exit(1)` (`:1124,1128`)

### 2.5 `dump` error recovery

- **`cmd_read`:** writes zeros on error, continues (`emmc_tool.py:1212-1220`)
- **`cmd_dump`:** identical pattern (`emmc_tool.py:1348-1355`)
- Enables post-hoc repair via `repair_dump.py`

### 2.6 repair_dump.py

- **Location:** `tools/repair_dump.py:17-31`
- **Scan:** finds 64-sector (32KB) zero chunks (`find_zero_chunks()`)
- **Repair:** re-reads each zero chunk at user-specified speed (default `--clock 0` = 2 MHz for maximum stability), patches in-place (`:107-109`)

### 2.7 compare_emmc.py — structural comparison

| Component | Parse | Compare |
|-----------|-------|---------|
| GPT | `:44-84` | `:399-441` |
| UNR0 | `:109-186` | `:444-529` |
| IM\*H | `:196-260` | `:532-566` |
| ext4 superblock | `:282-325` | `:569-596` |
| SQFS | `:332-358` | `:599-626` |
| `--deep` mount+diff | — | `:732-841` |

Deep mode: `sudo mount -o loop,ro,noload,offset=...`, file tree diff, MD5 comparison, JSON config diff.

### 2.8 RPMB MAC

- **Function:** `rpmb_calc_mac()` (`emmc_tool.py:190-198`) — `hmac.new(key, frame[228:512], sha256)`
- **Verify:** `rpmb_verify_mac()` (`:201-204`) — compares `frame[196:228]` with computed MAC

---

## Level 3: Rust GUI (emmc-gui)

### 3.1 CRC-8 UART

- **Function:** `crc8()` (`protocol.rs:46-60`) — polynomial 0x07
- **TX coverage:** CMD + LEN_H + LEN_L + PAYLOAD (`protocol.rs:678-682`)
- **RX coverage:** CMD + STATUS + LEN_H + LEN_L + PAYLOAD (`protocol.rs:735-740`)
- **Enforcement:** `bail!` on CRC mismatch — returns Err, retried by `with_retry()` (`protocol.rs:741-747`)
- **CMD18 per-sector CRC:** each sector checked independently, `bail!` on mismatch (`protocol.rs:433-448`)

### 3.2 Retry

- **Function:** `with_retry()` (`protocol.rs:774-792`)
- **Delay:** 50ms **fixed** (not exponential) (`protocol.rs:785`)
- **dump:** 3 retries (`operations.rs:611`)
- **verify:** 3 retries (`operations.rs:1012`)
- **restore:** NO retry (by design — write already committed to eMMC)

### 3.3 ext4 CRC-32C (Castagnoli)

- **Polynomial:** 0x82F63B78 (reflected) (`checksum.rs:3,14`)
- **Seed:** CRC-32C of superblock UUID (`superblock.rs:121-126`, `checksum.rs:41-43`)
- **Verified checksums (read + write):**
  - Superblock checksum (`checksum.rs:122-125`) — CRC-32C of bytes 0..1020, verified in `Superblock::parse()` (`superblock.rs:131-140`), recomputed in `write_superblock_free_counts()` (`file_ops.rs`)
  - Inode checksum (`checksum.rs:46-81`) — verified on read (`file_ops.rs:read_inode()`, warn on mismatch), recomputed on write (`write_inode_raw()`, `update_inode_size()`)
  - Directory block checksum (`checksum.rs:84-100`) — verified on read if 0xDE tail present (`file_ops.rs:read_dir_entries()`, warn), recomputed on write (`add_dir_entry()`, `rename_entry()`)
  - Group descriptor checksum (`checksum.rs:103-115`) — verified on read (`mod.rs:open()`, warn), recomputed on write (`write_group_desc_with_bitmap_csum()`)
  - Bitmap checksum (`checksum.rs:118-120`) — computed and written in GD during alloc (`file_ops.rs`)

### 3.4 ext4 bitrot recovery

- **Extent magic (0xF30A):** `parse_extent_node_force()` (`inode.rs:161-183`) — force-parse with WARN on corrupted magic (`:174`)
- **Extent retry:** 3 attempts to re-read inode (`file_ops.rs:49-51`); after 3 failures -> force-parse (`:77`)
- **Directory rec_len:** auto-recovery to `min_rec_len = align4(8 + name_len)` (`directory.rs:22-37`)
- **Superblock magic:** 0xEF53 — `bail!` if mismatch (`superblock.rs:46-49`)

### 3.5 RPMB MAC + Result Code

- **Verify:** `verify_mac(frame, key) -> bool` (`rpmb.rs:105-108`) — compares `frame[196..228]` with computed MAC
- **MAC computation:** `calc_mac()` (`:97`) — `hmac_sha256(key, frame[228..512])`
- **Usage:** `read_counter()` returns `Result<(RpmbFrame, bool)>` where bool = `mac_valid` (`:115,130`)
- **Result code warn:** Both `read_counter()` and `read_data()` log `tracing::warn!` when `frame.result != 0` (e.g. YMTC always returns 0x0001 "General failure")

### 3.6 Write pipelining

- **Pattern:** send batch N+1 while eMMC programs batch N (`operations.rs:707-708`)
- **Flow:** recv(N) at `:732-734` -> send(N+1) at `:750-752`
- **Cache flush mandatory:** on cancel (`:720`), on write error (`:735,753,768`), on success (`:784`)

---

## Summary Table: All 20 Checks

| # | Mechanism | Where | Algorithm | On Error |
|---|-----------|-------|-----------|----------|
| 1 | CRC-7 CMD TX/RX | FPGA | x^7+x^3+1 (0x09) | `cmd_crc_err` -> MC_ERROR (transient) |
| 2 | CRC-16 DAT read | FPGA | 0x1021 CCITT | `rd_crc_err` -> MC_ERROR (transient) |
| 3 | CRC-16 DAT write | FPGA | status token 010 | `wr_crc_err` -> MC_ERROR (transient) |
| 4 | CRC-8 UART RX | FPGA | 0x07 | STATUS_ERR_CRC, cmd rejected |
| 5 | CRC-8 UART RX | Python | 0x07 | RuntimeError (or WARN with --ignore-crc) |
| 6 | CRC-8 UART RX | Rust | 0x07 | bail! -> retry |
| 7 | CRC-8 CMD18 per-sector | Rust | 0x07 | bail! -> retry |
| 8 | Status code check | Python/Rust | 5 codes | raise / bail! |
| 9 | CMD timeout | FPGA | 1024 cycles | `cmd_timeout` -> MC_ERROR |
| 10 | DAT timeout | FPGA | 65534 cycles | `timeout_flag` -> MC_ERROR |
| 11 | Init retry | FPGA | CMD1: 1400, full: 3 | SI_ERROR -> MC_ERROR |
| 12 | Read retry | Python | exp backoff 0.1*2^n | --retry N (default 0) |
| 13 | Read retry | Rust | 3x, 50ms fixed | last error -> UI |
| 14 | ext4 CRC-32C read | Rust | 0x82F63B78 | inode/dir/gd warn on mismatch |
| 14b | ext4 CRC-32C write | Rust | 0x82F63B78 | inode/dir/gd/sb recomputed |
| 15 | ext4 extent magic | Rust | 0xF30A | force-parse + WARN |
| 16 | ext4 rec_len | Rust | alignment check | auto-recovery |
| 17 | ext4 superblock magic | Rust | 0xEF53 | bail! |
| 17b | ext4 superblock CRC | Rust | CRC-32C of [0..1020] | bail! |
| 17c | ext4 bitmap CRC in GD | Rust | CRC-32C (seed) | written on alloc |
| 18 | RPMB MAC | Python | HMAC-SHA256 | verify -> bool |
| 19 | RPMB MAC + result | Rust | HMAC-SHA256 | verify_mac -> bool, warn on result!=0 |
| 20 | Zero chunk scan | Python | == b'\x00' * N | repair_dump.py |

---

## Python vs Rust Differences

| Aspect | Python | Rust |
|--------|--------|------|
| CRC-8 RX mismatch | RuntimeError (fatal) | bail! (fatal, retried) |
| Retry delay | Exponential (0.1 * 2^n) | Fixed 50ms |
| Retry default | 0 (disabled) | 3 (always on for dump/verify) |
| Dump error recovery | Writes zeros, continues | Error -> stops (after 3 retry) |
| ext4 CRC-32C | None (no ext4 parsing) | Full verification |
| ext4 superblock CRC | N/A | Verified (bail! on mismatch) |
| Write retry | None | None |
| Header sync | Scans for 0x55 in loop | Scans for 0x55 in loop |

---

## Known Gaps

1. ~~**Rust CRC-8 is WARN-only**~~ — **FIXED**: CRC mismatch now returns `bail!`, retried by `with_retry()`.

2. ~~**ext4 superblock checksum**~~ — **FIXED**: `superblock_checksum()` added, verified in `Superblock::parse()` when `metadata_csum` is enabled.

3. ~~**ext4 bitmap block checksum**~~ — **FIXED**: `bitmap_checksum()` is now computed and written into group descriptor during alloc_inode/alloc_block, before GD checksum recompute.

4. ~~**repair_dump.py speed**~~ — **FIXED**: Default changed from `--clock 2` (6 MHz) to `--clock 0` (2 MHz) for maximum stability.

5. **MC_ERROR is transient** — the plan incorrectly stated it was fatal with "return only through reinit". In reality, MC_ERROR auto-recovers to MC_READY (with CMD12 for multi-block, immediately for single-block).

6. ~~**Superblock CRC in write path**~~ — **FIXED**: `write_superblock_free_counts()` now recomputes CRC-32C after modifying free counts.

7. ~~**Inode checksum on read**~~ — **FIXED**: `read_inode()` verifies inode checksum (warn, not bail — forensic tool).

8. ~~**Dir block checksum on read**~~ — **FIXED**: `read_dir_entries()` verifies 0xDE tail checksum when present (warn).

9. ~~**Group descriptor checksum on read**~~ — **FIXED**: `Ext4Fs::open()` verifies GD checksum during parse (warn).

10. ~~**RPMB result code**~~ — **FIXED**: `read_counter()`/`read_data()` log `warn!` on non-zero result codes.
