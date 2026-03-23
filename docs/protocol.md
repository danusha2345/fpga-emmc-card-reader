# UART Protocol Details

## Формат кадра

**PC → FPGA:** `[0xAA] [CMD] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]`
**FPGA → PC:** `[0x55] [CMD] [STATUS] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]`

CRC-8 покрывает всё кроме заголовка (0xAA/0x55) и самого CRC байта.

## SEND_RAW_CMD (0x0E) payload

**PC→FPGA (6 байт):**

| Байт | Содержимое |
|---|---|
| 0 | CMD_INDEX[5:0] — eMMC command index (0-63) |
| 1-4 | ARG[31:0] — 32-bit argument (big-endian) |
| 5 | FLAGS: [0]=resp_expected, [1]=resp_long (R2), [2]=check_busy |

**FPGA→PC:**
- resp_expected=0: 0 байт payload
- resp_long=0: 4 байта (R1 card status, big-endian)
- resp_long=1: 16 байт (R2 128-bit response)

## Пресеты UART baud (CMD 0x0F SET_BAUD)

| Preset | CPB (clks/bit) | Baud rate | Примечание |
|--------|---------------|-----------|------------|
| 0 | 20 | 3 Mbaud | default |
| 1 | 10 | 6 Mbaud | |
| 2 | 8 | 7.5 Mbaud | **отклоняется FPGA** (ERR_CMD) — FTDI divisor дробный |
| 3 | 5 | 12 Mbaud | требует FT2232HL (CJMCU-2232HL проверено OK) |

CPB (clocks per bit) = 60 МГц / baud. Response на SET_BAUD отправляется на **старом** baud rate.
FPGA применяет новый baud только после полной передачи CRC байта response.

### Handshake-протокол SET_BAUD

1. PC → FPGA: SET_BAUD(preset) на текущем baud
2. FPGA → PC: STATUS_OK на **старом** baud
3. FPGA: переключает baud после TX complete
4. PC: sleep(20ms), reopen port на новом baud
5. PC: PING → PONG подтверждает успех

## Status-коды ответа

| Код | Значение |
|---|---|
| 0x00 | OK |
| 0x01 | CRC Error |
| 0x02 | Unknown Command |
| 0x03 | eMMC Error |
| 0x04 | Busy (reserved, not currently sent by FPGA) |

## Multi-packet ответы

Некоторые команды генерируют **несколько UART-пакетов** на один запрос. Клиент
должен вычитать все пакеты, иначе остаточные данные десинхронизируют протокол.

### READ_SECTOR (0x03) — single-block (count=1)

| Пакет | CMD | Payload | Описание |
|-------|-----|---------|----------|
| 1 | 0x03 | 512 байт | Данные сектора |
| 2 | 0x03 | 0 байт | Completion |

### READ_SECTOR (0x03) — multi-block (count>1)

| Пакет | CMD | Payload | Описание |
|-------|-----|---------|----------|
| 1..N | 0x03 | 512 байт | Данные секторов (N пакетов) |
| N+1 | 0x03 | 0 байт | Completion |

### GET_EXT_CSD (0x07)

FPGA обрабатывает ExtCSD через sector buffer (как чтение 1 сектора):

| Пакет | CMD | Payload | Описание |
|-------|-----|---------|----------|
| 1 | 0x03 | 512 байт | ExtCSD данные (через sector buffer, cmd=READ_SECTOR!) |
| 2 | 0x07 | 0 байт | Completion |

**Внимание:** первый пакет приходит с `cmd=0x03` (READ_SECTOR), а не `0x07`, потому что
FPGA отправляет sector data с фиксированным `tx_cmd_id=CMD_READ_SECTOR` (uart_bridge.v:786).

## GET_STATUS debug payload (12 байт)

Байты 0-3 обратно совместимы с предыдущим 4-байтным форматом.

| Байт | Биты | Содержимое |
|---|---|---|
| 0 | [7:0] | resp_status (последний eMMC статус) |
| 1 | [7:4] | init_state (FSM init: 0=IDLE, 3=CMD0, 4=CMD1, 13=ERROR, 14=WAIT_CMD) |
| 1 | [2:0] | mc_state[4:2] |
| 2 | [7:6] | mc_state[1:0] (полный mc_state: 0=IDLE, 1=INIT, 2=READY, 10=ERROR, 19=STATUS_CMD) |
| 2 | [5] | info_valid (CID/CSD захвачены) |
| 2 | [4] | cmd_ready (контроллер принимает команды) |
| 3 | [7] | CMD pin raw state (1=HIGH) |
| 3 | [6] | DAT0 pin raw state (1=HIGH) |
| 4 | [7:5] | cmd_fsm (CMD line FSM: 0=IDLE, 1=SEND, 2=WAIT, 3=RECV, 4=DONE) |
| 4 | [4:1] | dat_fsm (DAT0 FSM: 0=IDLE, 1=RD_WAIT, 2=RD_DATA, ..., 13=WR_PRE2) |
| 4 | [0] | use_fast_clk (0=400kHz init, 1=fast transfer) |
| 5 | [7:6] | partition (0=user, 1=boot0, 2=boot1, 3=RPMB) |
| 5 | [5] | reinit_pending |
| 6 | [7:0] | cmd_timeout_cnt (saturating at 255) |
| 7 | [7:0] | cmd_crc_err_cnt (saturating at 255) |
| 8 | [7:0] | dat_rd_err_cnt (saturating at 255, CRC + timeout) |
| 9 | [7:0] | dat_wr_err_cnt (saturating at 255, CRC + busy timeout) |
| 10 | [7:0] | init_retry_cnt (CMD1 retries from last init, saturates at 255) |
| 11 | [4:3] | baud_preset (0-3, текущий пресет UART baud) |
| 11 | [2:0] | clk_preset (0-6, текущий пресет eMMC CLK) |

Счётчики ошибок сбрасываются по REINIT (cmd 0x0B) и глобальному reset.

## SET_BUS_WIDTH (0x11) — Switch eMMC bus width

**PC→FPGA (1 байт):**

| Байт | Содержимое |
|---|---|
| 0 | 1=1-bit (DAT0 only), 4=4-bit (DAT0-DAT3) |

**FPGA→PC:** STATUS_OK, 0 байт payload.

FPGA отправляет CMD6 SWITCH для записи ExtCSD[183] (BUS_WIDTH):
- width=1 → value=0x00 (1-bit mode)
- width=4 → value=0x01 (4-bit mode)

В 4-bit режиме данные передаются по DAT[3:0] ниблами (2 такта на байт, 1024 тактов на сектор вместо 4096). Каждая DAT линия имеет независимый CRC-16. CRC status token и busy всегда на DAT0.

Инициализация всегда в 1-bit. REINIT (0x0B) сбрасывает bus width в 1-bit.

**Требования к оборудованию:** физическое подключение DAT1-DAT3 к FPGA. На Tang Nano 9K QN88P нет свободных 1.8V пинов — RTL готов, но требуется проводное подключение.

## SET_RPMB_MODE (0x10) — Force CMD25/CMD18 for count=1

**PC→FPGA (1 байт):**

| Байт | Содержимое |
|---|---|
| 0 | 0=normal, 1=RPMB mode |

**FPGA→PC:** STATUS_OK, 0 байт payload.

В RPMB mode FPGA:
- Использует CMD25 (multi-block write) вместо CMD24 и CMD18 (multi-block read) вместо CMD17 даже при count=1
- **Автоматически отправляет CMD23 SET_BLOCK_COUNT** перед CMD25/CMD18 (FSM state MC_RPMB_CMD23)
  - Для write: CMD23 arg=0x80000001 (reliable write, 1 block)
  - Для read: CMD23 arg=0x00000001 (1 block)
- **Пропускает CMD12 STOP** после завершения — CMD23 устанавливает auto-terminate

Это необходимо по JEDEC eMMC 5.1 spec §6.6.22 — RPMB data frame **должен** передаваться через reliable write (CMD25), CMD24 не гарантирует атомарность.

## RPMB Protocol (JEDEC eMMC 5.1)

**RPMB (Replay Protected Memory Block) НЕ является блочным устройством!**
Нельзя читать/писать CMD17/CMD24. Требуется фреймовый протокол с HMAC-SHA256.

### Последовательность RPMB чтения через наш card reader:
1. `SET_RPMB_MODE(1)` — включить RPMB mode
2. `SET_PARTITION(3)` — переключиться на RPMB
3. `WRITE_SECTOR(LBA=0, count=1, data=request_frame)` — FPGA: CMD23(0x80000001) + CMD25 + 512B
4. `READ_SECTOR(LBA=0, count=1)` — FPGA: CMD23(0x00000001) + CMD18 + 512B response
5. `SET_PARTITION(0)` — вернуться на user
6. `SET_RPMB_MODE(0)` — вернуть нормальный режим

CMD23 отправляется FPGA автоматически (MC_RPMB_CMD23), back-to-back с CMD25/CMD18.

### RPMB Data Frame (512 байт):

| Offset | Размер | Содержимое |
|--------|--------|------------|
| 0-195 | 196 | Stuff bytes (зарезервировано) |
| 196-227 | 32 | MAC (HMAC-SHA256) |
| 228-483 | 256 | Data (application data) |
| 484-499 | 16 | Nonce (случайное число для read) |
| 500-503 | 4 | Write Counter (MSB first) |
| 504-505 | 2 | Address (half-sector units) |
| 506-507 | 2 | Block Count |
| 508-509 | 2 | Result (0=OK, 1=general fail, ...) |
| 510-511 | 2 | Req/Resp Type (1=auth key, 2=read counter, 3=auth write, 4=auth read, 5=read result) |

### HMAC-SHA256 ключ:
- 32-byte симметричный ключ, программируется в OTP (однократно)
- Нечитаемый после записи
- Уникален для каждого устройства (некоторые устройства используют hardcoded test key)

### RPMB в нашем card reader
**⚠ Важно:** CMD 0x08 (SET_PARTITION) с partition=3 **без** предварительного SET_RPMB_MODE(1) опасен — CMD17/CMD24 на RPMB является protocol violation. Инцидент: YMTC 64GB eMMC вошла в необратимый error state после CMD17 на RPMB.

Правильный путь: `SET_RPMB_MODE(1)` → `SET_PARTITION(3)` → RPMB операции → `SET_PARTITION(0)` → `SET_RPMB_MODE(0)`. Python-утилита (`rpmb-counter`, `rpmb-read`, `rpmb-dump`) делает это автоматически.

### Dead eMMC: MID=0x65 / "M MOR"

Когда NAND массив eMMC выходит из строя (коррозия/вода, ESD, износ), контроллер eMMC не может прочитать реальный CID из OTP/NAND и выдаёт **fallback CID**:

| Поле | Значение |
|------|----------|
| Manufacturer ID | `0x65` (Unknown) |
| Product Name | `M MOR` |
| CID hex | `65646F4D 204D4F52...` |

Характерные признаки:
- Capacity в ExtCSD сильно занижена (например 1.83 GB вместо 64 GB)
- Firmware version = all zeros, DDR = No, Health = Not defined
- Множество CRC ошибок при инициализации (`init_retries` >> 0)
- NAND массив частично нерабочий (eMMC Error при чтении дальних LBA)
- Секторы содержат заводской паттерн `ER17` + нули

Этот паттерн хорошо документирован на ремонтных форумах (UFI Box, Easy JTAG) для чипов SK Hynix, YMTC и др. Чип **невосстановим** — требуется замена.

Python-утилита и Rust GUI автоматически детектируют эту сигнатуру и выводят предупреждение.
