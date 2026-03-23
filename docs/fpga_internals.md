# FPGA Internals — Protection & Timing Optimizations

## Тайминг (SDC)

Файл: `src/tangnano9k.sdc`
- sys_clk: 60 МГц (period 16.667 нс)
- Все eMMC I/O — `set_false_path` (логика на clk_en стробах, не отдельный домен)
- UART I/O — `set_false_path` (async)
- Кнопки/LED — `set_false_path`

## Защитные механизмы

- **UART RX timeout** (`uart_bridge.v`): 23-бит счётчик (~140 мс при 60 МГц). Сбрасывается при каждом `rx_valid`. При переполнении — возврат RX FSM в `RX_IDLE`. Защищает от зависания при неполном пакете от PC.
- **Baud watchdog** (`uart_bridge.v`): 30-бит счётчик (~18 с при 60 МГц). Активен только когда `uart_clks_per_bit != 0` (не дефолтный baud). Сбрасывается при каждом успешном приёме пакета (RX_EXEC1 + CRC match). При переполнении — автовозврат на дефолтный baud (`uart_clks_per_bit <= 0`). GUI keepalive thread шлёт PING каждые ~5с для предотвращения timeout.
- **DAT0 busy wait** (`emmc_controller.v`, `MC_SWITCH_WAIT` / `MC_STOP_WAIT`): После CMD6 SWITCH и CMD12 STOP (R1b) — polling DAT0 до выхода из busy (DAT0 == 1) с 20-бит timeout (~13 мс). Соответствует требованиям JEDEC.
- **CMD13 SWITCH verify** (`emmc_controller.v`, `MC_SWITCH_STATUS`): После CMD6 SWITCH busy release — отправляет CMD13 SEND_STATUS и проверяет bit 7 (SWITCH_ERROR). Если SWITCH_ERROR=1 — возвращает STATUS_EMMC_ERR вместо ложного OK. Предотвращает ситуацию когда host думает что bus width сменился, а карта осталась на старом. Соответствует JESD84-B51 §6.6.1.
- **Device Status error bits** (`emmc_controller.v`): R1 response проверяется на 7 error bits (ADDRESS_OUT_OF_RANGE, COM_CRC_ERROR, ILLEGAL_COMMAND, DEVICE_ECC_FAILED, CC_ERROR, ERROR, SWITCH_ERROR) в MC_READ_CMD, MC_WRITE_CMD, MC_EXT_CSD_CMD, MC_ERASE_*. Маска: `0x80F80080`. Device-side ошибки репортятся как STATUS_EMMC_ERR.
- **CMD7 post-busy delay** (`emmc_init.v`, `SI_CMD7_WAIT`): 1 мс задержка после CMD7 SELECT_CARD (R1b) перед CMD16. Компенсирует отсутствие DAT0 polling в init FSM.
- **CMD done guard** (`emmc_cmd.v`): `if (cmd_start && !cmd_done)` в S_IDLE предотвращает захват команды с устаревшими NBA-аргументами в том же такте, что и cmd_done. Без этого многокомандные последовательности (erase CMD35→36→38) получали дубликаты.
- **CMD start guard** (`emmc_controller.v`): `mc_cmd_start <= 1'b1` только в `else` ветке `if (cmd_done)` во всех 10 CMD-sending states. Без этого NBA-семантика оставляла mc_cmd_start=1 на 1 такт после cmd_done, вызывая spurious CMD restart.
- **CMD CRC error propagation** (`emmc_controller.v`): Все 10 CMD-sending states проверяют `if (cmd_timeout || cmd_crc_err)`. При CRC-7 mismatch в R1 response — переход в MC_ERROR (resp_status=0x03). При multi-block (CMD18/CMD25) — MC_ERROR → MC_ERROR_STOP (CMD12).
- **Auto-reinit** (`emmc_controller.v`): При ошибке init на первом boot — автоматический retry до 3 раз (`boot_retry_cnt`).
- **Post-reset delay** (`emmc_init.v`): 50 мс задержка после RST_n high (вместо 10 мс).
- **Sector-mode CMD16 skip** (`emmc_init.v`): OCR[30]=1 (sector addressing) → пропуск CMD16 SET_BLOCKLEN.
- **Ping-pong buffer read** (`emmc_controller.v`): Double-buffered `uart_rd_bank` / `uart_rd_bank_next`. `uart_rd_bank_next` защёлкивается в MC_READ_DAT/MC_EXT_CSD_DAT (pre-increment `emmc_bank`). `uart_rd_bank` (drives `buf_sel_b`) обновляется ТОЛЬКО по `rd_sector_ack` — когда UART bridge начинает читать сектор. Это гарантирует стабильность bank select пока UART передаёт данные. **Ранее** (v1) `uart_rd_bank` был комбинационным wire (`emmc_bank - 1`), мгновенно переключался mid-transfer. (v2) был reg, защёлкнутый в MC_READ_DAT — но при медленном UART (3M) и быстром eMMC (10 MHz) следующий сектор завершался быстрее, чем UART дочитывал текущий, переключая банк mid-transfer (~48% коррупции).
- **Multi-block reads** (CMD18): Sticky `rd_sector_ready` + `rd_sector_ack` handshake и sticky `resp_valid_r` для надёжной передачи между eMMC controller и UART bridge.
- **Multi-block writes** (CMD25): `wr_sectors_ready` 5-bit counter (0-16) → `emmc_wr_sector_valid` promotion → `wr_sector_ack` handshake. Max payload = 65535 байт (127 секторов).
- **wr_done_watchdog**: 24-bit counter (~280 мс) в MC_WRITE_DONE и MC_RPMB_FIFO_WAIT. Предотвращает deadlock при обрыве UART mid-transfer. В RPMB mode: если CMD23 отправлен, но UART не предоставляет write data — watchdog abort без CMD12 (CMD25 не начат, карта ждёт команду).
- **Write busy guard** (`emmc_dat.v`, `S_WR_BUSY`): Переиспользует `crc_status_cnt` (==4 при входе) → считает до 7, пропуская 3 `clk_en` перед проверкой `dat_in`. Защищает от Nwr gap (JESD84-B51 §6.14.3): карта может держать DAT0=1 на 1-2 CLK между CRC status end bit и busy start. Без guard — false completion → bus contention → partial write при CMD25. **ВАЖНО**: Выделенный `busy_guard_cnt` (2-bit) вызывал Gowin PnR regression — routing congestion ломала CRC-7 на CMD path. Решение: reuse existing `crc_status_cnt`, 0 новых FF.
- **CRC status timeout** (`emmc_dat.v`, `S_WR_CRC_STAT`): 16-bit `timeout_cnt` при ожидании CRC status start bit (dat_in=0, crc_status_cnt=0). Timeout ~65K clk_en предотвращает FSM hang если карта не отвечает (bus noise, breadboard контакт). При timeout — `wr_crc_err + wr_done`.
- **RPMB warning** (Python + Rust GUI): RPMB через CMD17/CMD24 — undefined behavior по JEDEC.

## Оптимизации для тайминга (Gowin)

Критические пути оптимизированы в `uart_bridge.v` и `emmc_controller.v`:
- **info_shift** (256-бит сдвиговый регистр) — заменяет 32:1 MUX при отправке CID/CSD
- **emmc_rd_data_reg** — pipeline-регистр между BRAM read и tx_crc_data
- **tx_busy_r** — registered tx_busy для разрыва критического пути
- **RX_EXEC** разделён на 2 стадии (RX_EXEC1 + RX_EXEC2) для balance timing
- **tx_start_d** — 1-цикл задержка tx_start чтобы tx_cmd_id успел установиться
- Down-counter вместо up-counter для payload (сравнение с 0 дешевле)
- Saturating rx_byte_num (0→8) для индексации первых байт payload
- **erase_end_lba** — pipeline-регистр для CMD36 аргумента (убирает 32-bit adder с критического пути)
- **cmd_count_is_zero** — предвычисленный флаг count==0 (убирает 16-bit NOR из CE цепи)
- **cmd_is_*** — предекодированные флаги cmd_id (убирают 8-bit compare из dispatch)
- **card_status_pending** — предрегистрированный флаг в uart_bridge (убирает 8-bit compare emmc_cmd_id из TX_IDLE → info_shift critical path)
- **status_arg** — предвычисленный `{init_rca, 16'h0000}` в emmc_controller (убирает concat из MC_READY dispatch)
- **rd_sector_ready** — sticky level + `rd_sector_ack` handshake (заменяет одноцикловый пульс)
- **resp_valid_r** — sticky latch в uart_bridge для `emmc_resp_valid`
- **GET_STATUS direct read** — `info_shift[255:248]` читает `emmc_resp_status` напрямую
- **wr_sectors_ready** — 5-bit counter (0-16), pipelined producer-consumer
- **Adaptive read chunk** (`emmc_tool.py`): `_safe_read_chunk()` — безопасный CMD18 chunk size
- **Write cache** (`emmc_tool.py`): ExtCSD[33] (CACHE_CTRL=1)
- **dump ExtCSD fallback** — ёмкость из ExtCSD SEC_COUNT если CSD < 2 GB
- **dump/verify/restore auto-multi** — автоматически CMD18/CMD25 для bulk
- **Single-read completion** — FPGA шлёт N+1 пакетов (N секторов + 0-byte completion)
- **restore --lba seek** — `f.seek(N * 512)` при resume

**ОСТОРОЖНО с timing:** Добавление логики в enable-цепь `sectors_remaining_next` (underflow guard `!= 16'd0`) вызывает timing regression — 16-bit NOR удлиняет критический путь. Fmax=60.5 МГц при 60 МГц constraint (margin 0.8%).

**ОСТОРОЖНО с Gowin PnR:** Добавление даже 2 FF (`busy_guard_cnt`) может вызвать routing congestion, ломающую CRC-7 на CMD path (детерминированный pattern: even LBA fail, odd pass). Решение: reuse existing registers (см. Write busy guard выше). Fmax после reuse: 66.8 МГц (было 65.0).
