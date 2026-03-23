# Testbench Scenarios

16 тестбенчей (98 тестовых сценариев): `tb_crc8`, `tb_crc7`, `tb_crc16`, `tb_uart_tx`, `tb_uart_rx`, `tb_uart_loopback`, `tb_sector_buf`, `tb_sector_buf_wr` (5 тестов), `tb_emmc_cmd`, `tb_emmc_cmd_crc_verify` (3 теста), `tb_uart_bridge` (24 теста), `tb_emmc_controller` (34 теста), `tb_emmc_dat` (9 тестов), `tb_emmc_init` (7 тестов), `tb_led_status` (5 тестов), `tb_top_integration` (3 теста).

`sim/pll_stub.v` — заглушка Gowin rPLL для iverilog.

## tb_emmc_controller (34 теста)

| # | Сценарий | Что проверяет |
|---|---|---|
| 1 | Init sequence | PRE_IDLE→CMD0→CMD1→CMD2→CMD3→CMD9→CMD7→CMD16, CID/CSD capture |
| 2 | Read single sector LBA=0 | CMD17, DAT0 data + CRC-16, sector buffer |
| 3 | Read single sector LBA=42 | Non-zero LBA передаётся корректно на CMD линию |
| 4 | Write single sector (CMD24) | Host→card DAT0 write, BRAM prefetch pipeline, CRC-16 генерация, CRC status (010) от card stub, busy wait |
| 5 | Multi-block read (CMD18, count=2) | 2 сектора подряд, ping-pong buffer flip, CMD12 STOP_TRANSMISSION |
| 6 | ExtCSD read (CMD8) | CMD8 → DAT0 512 байт ExtCSD, данные в sector buffer, buf_sel flip |
| 7 | Partition switch (CMD6) | CMD6 SWITCH → DAT0 busy wait → release, resp_valid + status OK |
| 8 | Write CRC error | Card отвечает CRC status 101 вместо 010, resp_status=0x03 |
| 9 | Read CRC mismatch | Card портит 1 бит данных (CRC верный для оригинала), resp_status=0x03 |
| 10 | Erase (CMD35→CMD36→CMD38) | LBA=100, count=10, CMD35/CMD36/CMD38 + DAT0 busy release |
| 11 | Write ExtCSD (CMD6 SWITCH) | cmd_id=0x09, index=33, value=1, CMD6 SWITCH + DAT0 busy |
| 12 | READ count=0 | cmd_count=0 → immediate ERR_CMD (0x02), no eMMC bus activity |
| 13 | ERASE count=0 | cmd_count=0 → immediate ERR_CMD (0x02) |
| 14 | WRITE count=0 | cmd_count=0 → immediate ERR_CMD (0x02), no UART hang |
| 15 | SEND_STATUS (CMD13) | cmd_id=0x0A → CMD13 с RCA, card_status capture, resp_valid + 32-bit status |
| 16 | RE-INIT (CMD0) | cmd_id=0x0B → MC_IDLE→MC_INIT→MC_READY, resp_valid, CID перечитан |
| 17 | Secure Erase (CMD38 arg) | cmd_id=0x0C, LBA=200, count=5, CMD38 arg=0x80000000 verified |
| 18 | Multi-block WRITE (CMD25) | count=2, два сектора с разными паттернами, CMD12 STOP, верификация данных |
| 19 | Multi-block READ CRC error + CMD12 | CMD18 count=2 + force_rd_crc_err, resp_status=0x03 + CMD12 sent |
| 20 | Multi-block WRITE CRC error + CMD12 | CMD25 count=2 + force_wr_crc_err, resp_status=0x03 + CMD12 sent |
| 21 | DAT0 busy timeout | CMD6 SWITCH + card не отпускает DAT0, switch_wait_cnt forced → ERR_EMMC |
| 22 | SET_CLK_DIV | Preset=3 (9 МГц) → STATUS_OK + verify fast_clk_div_reload; preset=7 (invalid) → ERR_CMD |
| 23 | SEND_RAW_CMD | 23a: CMD13 R1 short + card_status verify; 23b: CMD62 vendor arg; 23c: CMD0 no-resp; 23d: CMD9 R2 long 128-bit verify; 23e: CMD6 check_busy DAT0 wait |
| 24 | Multi-block WRITE count=16 | CMD25, 16 секторов, full 16-bank FIFO, per-sector data verify |
| 25 | WRITE count=17 rejected | count > 16 → ERR_CMD (16-bank FIFO limit) |
| 26 | CMD17 CRC error | force_cmd_crc_err → R1 CRC-7 mismatch, resp_status=0x03, MC_ERROR |
| 27 | CMD18 CRC error + CMD12 | force_cmd_crc_err → resp_status=0x03 + CMD12 STOP sent |
| 28 | CMD25 CRC error + CMD12 | force_cmd_crc_err → resp_status=0x03 + CMD12 STOP sent |
| 29 | Multi-block read with backpressure | CMD18 count=3, delayed acks (500/300 clk), clk_pause verification, data verify after ACK |
| 30 | CMD18 uart_rd_bank double-buffer | CMD18 count=3 LBA=30, ACK S0 → S1 ready → verify S0 data still accessible (uart_rd_bank not switched) → ACK S1 → verify S1 data |
| 31 | SET_CLK_DIV presets 0-6 | Все 7 пресетов: verify current_clk_preset + fast_clk_div_reload (div-1) |
| 32 | SET_CLK_DIV reject preset 7 | Invalid preset → STATUS_CMD_ERR (0x02) |
| 33 | Command at new CLK speed | SET_CLK_DIV preset=3 (10 MHz) → SEND_STATUS → verify STATUS_OK |
| 34 | RPMB FIFO wait timeout | SET_RPMB_MODE(1) → WRITE_SECTOR без данных → MC_RPMB_CMD23 → MC_RPMB_FIFO_WAIT → watchdog overflow → STATUS_EMMC_ERR (0x03) |

## tb_uart_bridge (24 теста)

| # | Сценарий | Что проверяет |
|---|---|---|
| 1 | PING | Round-trip [AA,01,...] → [55,01,00,...], CRC-8 |
| 2 | GET_INFO | CID+CSD 32 байта через info_shift регистр |
| 3 | Unknown command | STATUS_ERR_CMD (0x02) |
| 4 | CRC error | STATUS_ERR_CRC (0x01) при bad CRC |
| 5 | READ_SECTOR | Полный round-trip 512 байт: UART cmd → mock eMMC → 512-byte UART response, проверка всех данных + CRC-8 |
| 6 | RX timeout | Неполный пакет → protocol_error → recovery → valid PING |
| 7 | WRITE_SECTOR | 518-byte payload (LBA+COUNT+512 data), mock eMMC write, response OK |
| 8 | ERASE | LBA=100, COUNT=10, проверка cmd_id/lba/count forwarding |
| 9 | GET_STATUS | Pre-set emmc_resp_status=0x42, 1-byte response payload |
| 10 | GET_EXT_CSD | Mock rd_sector_ready, 512-byte response с pattern-проверкой |
| 11 | SET_PARTITION | Payload=0x02 (boot1), проверка cmd_lba[7:0]=0x02 |
| 12 | WRITE_EXT_CSD | cmd=0x09, index=33, value=1, проверка lba encoding + response |
| 13 | READ_SECTOR count=0 | Полный round-trip: count=0 → STATUS_ERR_CMD (0x02), пустой response |
| 14 | GET_CARD_STATUS | cmd=0x0A, mock card_status=0xDEADBEEF, проверка 4-byte response |
| 15 | REINIT | cmd=0x0B, mock init completion, проверка 0-byte response |
| 16 | SECURE_ERASE | cmd=0x0C, LBA=200, count=5, round-trip проверка cmd_id forwarding |
| 17 | WRITE count=2 (multi-write) | 2 сектора в одном пакете (1030B payload), wr_sectors_ready counter + wr_sector_ack handshake, data verification обоих секторов |
| 18 | READ count=2 (multi-sector) | 2× rd_sector_ready, 2×512-byte пакета + финальный resp_valid |
| 19 | SET_BAUD preset=3 (12M) | Response OK на старом baud → CPB=6 → PING на новом baud |
| 20 | SET_BAUD invalid preset=7 | STATUS_ERR_CMD, CPB не изменился |
| 21 | SET_BAUD preset=0 (default) | Response на CPB=6 → CPB=24 → PING на CPB=24 |
| 22 | SET_BAUD preset=2 (rejected) | STATUS_ERR_CMD, CPB не изменился (9M broken with FT2232HL) |
| 23 | Baud watchdog auto-reset | Switch to preset 1 → force watchdog overflow → CPB=0 (default) → PING OK |
| 24 | WRITE count=10 (multi-write) | 10 секторов (5126B payload), 16-bank FIFO, per-sector ack handshake + data verify |

## tb_sector_buf_wr (5 тестов)

| # | Сценарий | Что проверяет |
|---|---|---|
| 1 | Write/read one sector (bank 0) | 512 байт через Port B → Port A, побайтная верификация |
| 2 | Fill all 16 banks | 16 банков с разными паттернами, spot-check 3 адреса на банк, независимость банков |
| 3 | Concurrent read/write | Запись в bank 5 + чтение bank 3 одновременно, оба корректны |
| 4 | Wrap-around (bank 15 → 0) | Запись bank 15 → bank 0, верификация обоих |
| 5 | Max address boundary | addr=511 во всех 16 банках, distinct values |

## tb_top_integration (3 теста)

| # | Сценарий | Что проверяет |
|---|---|---|
| 1 | UART PING end-to-end | UART TX bit-bang → uart_bridge → resp_valid → UART RX, полный round-trip |
| 2 | eMMC card stub | Card stub отвечает на CMD/DAT0, init последовательность через emmc_controller |
| 3 | Signal interconnect | Wiring uart_bridge ↔ emmc_controller: cmd_valid, cmd_id, tx_pin |

## tb_emmc_dat (9 тестов)

| # | Сценарий | Что проверяет |
|---|---|---|
| 1 | Read CRC OK | Card → DAT0 start + 4096 бит + CRC-16 + end, 512 байт в BRAM |
| 2 | Read CRC mismatch | Инвертированный CRC → rd_crc_err=1 |
| 3 | Read timeout | DAT0 остаётся high → timeout через 65K clk_en |
| 4 | Write CRC OK | BRAM → DAT0 + CRC-16, card отвечает CRC status 010, busy release |
| 5 | Write CRC status error | Card отвечает 101 → wr_crc_err=1 |
| 6 | Write busy timeout | Card не отпускает DAT0 → wr_crc_err=1 |
| 7 | Back-to-back read+write | FSM корректно возвращается в S_IDLE между операциями |
| 8 | Nwr gap regression | Card вставляет 2 CLK gap (DAT0=1) между CRC status end bit и busy start. Без busy guard → false wr_done. С guard → корректное ожидание |
| 9 | CRC status timeout | Card не посылает CRC status (DAT0 high). Без timeout → FSM hang. С timeout → wr_crc_err + wr_done |

## tb_emmc_init (7 тестов)

| # | Сценарий | Что проверяет |
|---|---|---|
| 1 | Happy path | CMD0→CMD1→CMD2→CMD3→CMD9→CMD7→CMD16, CID/CSD capture, use_fast_clk |
| 2 | CMD1 polling (5 retries) | OCR[31]=0 на 5 попыток, затем ready |
| 3 | CMD1 extended polling (50) | 50 retries → init_done=1 |
| 4 | CMD timeout на CMD2 | cmd_timeout=1 → init_error=1 |
| 5 | CRC error на CMD3 | cmd_crc_err=1 → init_error=1 |
| 6 | CRC error на CMD1 (R3) | CRC ignored для R3 response, init продолжается |
| 7 | RST_n timing | emmc_rstn_out low→high последовательность |

## tb_led_status (5 тестов)

| # | Сценарий | Что проверяет |
|---|---|---|
| 1 | Reset state | Все led_n = 1 (off) |
| 2 | eMMC activity stretch | 1-cycle pulse → LED on, stretch counter, turn off |
| 3 | UART activity stretch | Pulse → on, re-trigger → counter reset |
| 4 | Direct LEDs | emmc_ready → led_n[2]=0, error → led_n[3]=0 |
| 5 | Heartbeat toggle | Force hb_cnt near overflow → led_n[5] toggles |

## tb_emmc_cmd_crc_verify (3 теста)

| # | Сценарий | Что проверяет |
|---|---|---|
| 1 | CMD0 (GO_IDLE) | CRC-7 = 0x4A для index=0, arg=0x00000000 |
| 2 | CMD1 (SEND_OP_COND) | CRC-7 = 0x05 для index=1, arg=0x40FF8000 |
| 3 | CMD3 (SET_RELATIVE_ADDR) | CRC-7 = 0x3F для index=3, arg=0x00010000 |

Захватывает 47 бит (без end bit) на CMD линии и сверяет CRC-7 с независимо вычисленным значением.

## Особенности card stub в tb_emmc_controller

- **DAT0 на negedge**: card stub шлёт данные на спаде eMMC CLK, чтобы данные были стабильны когда host читает на фронте (иначе CRC-16 module в `emmc_dat.v`, подключённый к `dat_in` напрямую, захватывает уже изменённый бит)
- **card_resp_triggered**: response generation срабатывает однократно на `card_rx_done` (иначе NBA race между CMD FSM и response gen создаёт spurious TX и bus contention)
- **DAT_WAIT=100**: card stub ждёт 100 eMMC тактов перед отправкой данных, давая host время обработать R1 ответ
- **Write reception**: card stub принимает данные от хоста на negedge (стабильны после posedge-драйва хоста), вычисляет CRC-16, отправляет CRC status (start + 010 + busy), `card_wr_mem[]` хранит принятые данные для верификации
- **Multi-block read**: card stub автоматически шлёт следующий сектор после DAT_END, останавливается по CMD12; `card_sector_lba` инкрементируется для разных data-паттернов
- **ExtCSD (CMD8)**: card stub отвечает на CMD8, DAT FSM шлёт 512 байт с pattern `(i + 0xEE) & 0xFF`
- **Partition switch (CMD6)**: card stub отвечает R1 + DAT0 busy на `switch_busy_limit` eMMC тактов
- **CRC error injection**: `force_wr_crc_err` → CRC status 101 вместо 010; `force_rd_crc_err` → портит 1 бит данных; `force_cmd_crc_err` → XOR CRC-7 в R1 response (CMD17/18/24/25)
