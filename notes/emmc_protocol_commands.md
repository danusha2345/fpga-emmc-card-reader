# eMMC Protocol — Полный справочник команд

> Источник: JEDEC JESD84-B51 (eMMC 5.1), даташиты производителей, Linux kernel mmc/mmc.h
> Контекст: Tang Nano 9K Card Reader — 1-bit DAT0 mode, 81 MHz sys_clk

---

## Оглавление

1. [Формат команды и ответа](#1-формат-команды-и-ответа)
2. [Типы ответов (Response)](#2-типы-ответов-response)
3. [Классы команд](#3-классы-команд)
4. [Полная таблица команд](#4-полная-таблица-команд)
5. [Детальное описание команд](#5-детальное-описание-команд)
6. [Состояния карты (Card States)](#6-состояния-карты-card-states)
7. [Протокол передачи данных (DAT)](#7-протокол-передачи-данных-dat)
8. [CRC алгоритмы](#8-crc-алгоритмы)
9. [Тайминги](#9-тайминги)
10. [Extended CSD — ключевые поля](#10-extended-csd--ключевые-поля)
11. [Реализация в проекте](#11-реализация-в-проекте)

---

## 1. Формат команды и ответа

### Формат команды (Host → Card, 48 бит)

```
[Start:0][Transmit:1][CMD_index:6][Argument:32][CRC7:7][End:1]
 bit 47     bit 46     bits 45-40    bits 39-8   bits 7-1  bit 0
```

- **Start bit** = 0 (всегда)
- **Transmit bit** = 1 (host → card)
- **CMD index** = 6 бит (0–63)
- **Argument** = 32 бита (зависит от команды)
- **CRC7** = 7 бит (poly = 0x09, init = 0x00, покрывает биты 47–8)
- **End bit** = 1 (всегда)

### Формат ответа (Card → Host)

Два формата: **48-бит** (R1/R1b/R3/R4/R5) и **136-бит** (R2).

---

## 2. Типы ответов (Response)

### R1 — Standard Response (48 бит)

```
[0][0][CMD_index:6][Card_Status:32][CRC7:7][1]
```

| Поле | Биты | Описание |
|------|------|----------|
| Start | 47 | 0 |
| Transmit | 46 | 0 (card → host) |
| CMD index | 45:40 | Эхо индекса команды |
| Card Status | 39:8 | 32-бит статус (см. ниже) |
| CRC7 | 7:1 | CRC-7 |
| End | 0 | 1 |

**Card Status (важные биты):**

| Бит | Название | Описание |
|-----|----------|----------|
| 31 | ADDRESS_OUT_OF_RANGE | Адрес вне диапазона |
| 29 | ERASE_SEQ_ERROR | Ошибка последовательности erase |
| 26 | DEVICE_IS_LOCKED | Карта залочена паролем |
| 25 | WP_VIOLATION | Запись в защищённую область |
| 22 | ILLEGAL_COMMAND | Недопустимая команда в текущем состоянии |
| 21 | DEVICE_ECC_FAILED | Внутренний ECC не исправил ошибку |
| 20 | CC_ERROR | Внутренняя ошибка контроллера |
| 19 | ERROR | Общая ошибка |
| 16 | CID_CSD_OVERWRITE | Попытка перезаписать read-only CID/CSD |
| 12:9 | CURRENT_STATE | Текущее состояние (0–15, см. §6) |
| 8 | READY_FOR_DATA | Буфер готов к следующей команде |
| 7 | SWITCH_ERROR | Ошибка CMD6 SWITCH |
| 5 | APP_CMD | Следующая команда — ACMD |

### R1b — R1 with Busy (48 бит + DAT0 busy)

Формат идентичен R1, но после ответа карта удерживает **DAT0 = 0** пока занята.
Host должен опрашивать DAT0 до появления `1`.

### R2 — CID/CSD Register (136 бит)

```
[0][0][111111][CID_or_CSD:128][CRC7_internal:7][1]
```

| Поле | Биты | Описание |
|------|------|----------|
| Start | 135 | 0 |
| Transmit | 134 | 0 |
| Reserved | 133:128 | 111111 (NOT echo CMD index) |
| Content | 127:0 | 128 бит CID или CSD |

**Примечание:** CRC7 в R2 вычислен картой для внутренних целей, host обычно его не проверяет.

### R3 — OCR Register (48 бит, **без CRC**)

```
[0][0][111111][OCR:32][1111111][1]
```

- CMD index = `0x3F` (reserved, not echoed)
- CRC7 = `0x7F` (all ones, **невалидный** — не проверять!)
- Используется только для CMD1 (SEND_OP_COND)

**OCR Register:**

| Бит | Описание |
|-----|----------|
| 31 | Card power up status (busy) — 0=busy, 1=ready |
| 30 | Access mode: 1=sector, 0=byte |
| 29:24 | Reserved |
| 23:8 | Voltage window (2.7–3.6V = 0xFF80) |
| 7 | 1.70–1.95V support |

### R4 — Fast I/O (48 бит)

Используется CMD39 (FAST_IO) — **не реализовано в проекте**.

### R5 — Interrupt Request (48 бит)

Используется CMD40 (GO_IRQ_STATE) — **не реализовано в проекте**.

---

## 3. Классы команд

| Класс | Название | Команды | Описание |
|-------|----------|---------|----------|
| 0 | Basic | CMD0,1,2,3,4,7,9,10,12,13,14,15,19 | Базовые: reset, init, select, status |
| 1 | Stream read | CMD11 | Потоковое чтение (deprecated в eMMC 5.1) |
| 2 | Block read | CMD16,17,18 | Блочное чтение |
| 3 | Stream write | CMD20 | Потоковая запись (deprecated) |
| 4 | Block write | CMD23,24,25,26,27 | Блочная запись, program CID/CSD |
| 5 | Erase | CMD35,36,38 | Стирание |
| 6 | Write protect | CMD28,29,30 | Защита от записи (опционально) |
| 7 | Lock card | CMD42 | Блокировка/разблокировка паролем |
| 8 | Application | CMD55,56 | App-specific команды |
| 9 | I/O mode | CMD39,40 | Fast I/O, IRQ (опционально) |
| 10 | Switch | CMD6,8 | Переключение режимов, ExtCSD |
| 11 | — | — | Зарезервирован |

---

## 4. Полная таблица команд

### Обозначения

| Символ | Значение |
|--------|----------|
| **bc** | broadcast, без ответа |
| **bcr** | broadcast с ответом |
| **ac** | addressed command (без данных) |
| **adtc** | addressed data transfer command |
| ✅ | Реализовано в проекте |
| ⬜ | Не реализовано |

### Класс 0 — Basic Commands

| CMD | Тип | Ответ | Название | Аргумент | Статус | Описание |
|-----|------|-------|----------|----------|--------|----------|
| 0 | bc | — | GO_IDLE_STATE | `0x00000000` | ✅ | Сброс всех карт в Idle state |
| 0 | bc | — | GO_PRE_IDLE | `0xF0F0F0F0` | ⬜ | Pre-idle state (eMMC 4.5+) |
| 0 | bc | — | BOOT_INITIATION | `0xFFFFFFFA` | ⬜ | Старт boot sequence |
| 1 | bcr | R3 | SEND_OP_COND | `0x40FF8080` | ✅ | Запрос OCR, проверка ready |
| 2 | bcr | R2 | ALL_SEND_CID | `0x00000000` | ✅ | Запрос CID (128 бит) |
| 3 | ac | R1 | SET_RELATIVE_ADDR | `{RCA[31:16], 0}` | ✅ | Назначить RCA (eMMC: host задаёт) |
| 4 | bc | — | SET_DSR | `{DSR[31:16], 0}` | ⬜ | Установить Driver Stage Register |
| 5 | ac | R1b | SLEEP_AWAKE | `{RCA, 0, Sleep:1, 0}` | ⬜ | Вход/выход из sleep mode |
| 6 | ac | R1b | SWITCH | `{0, Access:2, Index:8, Value:8, CmdSet:3}` | ✅ | Изменение ExtCSD регистра |
| 7 | ac | R1/R1b | SELECT_CARD | `{RCA[31:16], 0}` | ✅ | Выбор карты (Stby→Tran) |
| 8 | adtc | R1 | SEND_EXT_CSD | `0x00000000` | ✅ | Чтение ExtCSD (512 байт на DAT) |
| 9 | ac | R2 | SEND_CSD | `{RCA[31:16], 0}` | ✅ | Чтение CSD register (128 бит) |
| 10 | ac | R2 | SEND_CID | `{RCA[31:16], 0}` | ⬜ | Чтение CID в Transfer state |
| 12 | ac | R1/R1b | STOP_TRANSMISSION | `{0, HPI:1, 0}` | ✅ | Прервать multi-block чтение/запись |
| 13 | ac | R1 | SEND_STATUS | `{RCA[31:16], 0, SQS:1, 0}` | ⬜ | Запрос Card Status register |
| 14 | adtc | R1 | BUSTEST_R | `0x00000000` | ⬜ | Чтение bus test pattern (для bus width) |
| 15 | ac | — | GO_INACTIVE_STATE | `{RCA[31:16], 0}` | ⬜ | Перевод карты в Inactive |
| 19 | adtc | R1 | BUSTEST_W | `0x00000000` | ⬜ | Запись bus test pattern |
| 21 | adtc | R1 | SEND_TUNING_BLOCK | `0x00000000` | ⬜ | Tuning block для HS200/HS400 |

### Класс 2 — Block Read Commands

| CMD | Тип | Ответ | Название | Аргумент | Статус | Описание |
|-----|------|-------|----------|----------|--------|----------|
| 16 | ac | R1 | SET_BLOCKLEN | `Block_length[31:0]` | ✅ | Установить длину блока (512) |
| 17 | adtc | R1 | READ_SINGLE_BLOCK | `Data_address[31:0]` | ✅ | Чтение одного блока |
| 18 | adtc | R1 | READ_MULTIPLE_BLOCK | `Data_address[31:0]` | ✅ | Чтение нескольких блоков |

### Класс 4 — Block Write Commands

| CMD | Тип | Ответ | Название | Аргумент | Статус | Описание |
|-----|------|-------|----------|----------|--------|----------|
| 23 | ac | R1 | SET_BLOCK_COUNT | `{Reliable:1, 0, Count:16}` | ⬜ | Задать кол-во блоков (вместо CMD12) |
| 24 | adtc | R1 | WRITE_BLOCK | `Data_address[31:0]` | ✅ | Запись одного блока |
| 25 | adtc | R1 | WRITE_MULTIPLE_BLOCK | `Data_address[31:0]` | ✅ | Запись нескольких блоков |
| 26 | adtc | R1 | PROGRAM_CID | `0x00000000` | ⬜ | Программирование CID (однократно!) |
| 27 | adtc | R1 | PROGRAM_CSD | `0x00000000` | ⬜ | Программирование записываемых полей CSD |

### Класс 5 — Erase Commands

| CMD | Тип | Ответ | Название | Аргумент | Статус | Описание |
|-----|------|-------|----------|----------|--------|----------|
| 35 | ac | R1 | ERASE_GROUP_START | `Data_address[31:0]` | ✅ | Начало диапазона стирания |
| 36 | ac | R1 | ERASE_GROUP_END | `Data_address[31:0]` | ✅ | Конец диапазона стирания |
| 38 | ac | R1b | ERASE | `{Secure_req:1, 0, ...}` | ✅ | Выполнить стирание + busy |

**Примечание:** CMD38 arg `0x00000000` = обычный erase, `0x80000000` = secure erase (заполнение pattern'ом), `0x80008000` = secure trim. В проекте используется arg=0 (обычный erase).

### Класс 6 — Write Protection

| CMD | Тип | Ответ | Название | Аргумент | Статус | Описание |
|-----|------|-------|----------|----------|--------|----------|
| 28 | ac | R1b | SET_WRITE_PROT | `Data_address[31:0]` | ⬜ | Защитить группу от записи |
| 29 | ac | R1b | CLR_WRITE_PROT | `Data_address[31:0]` | ⬜ | Снять защиту от записи |
| 30 | adtc | R1 | SEND_WRITE_PROT | `Data_address[31:0]` | ⬜ | Статус WP (32 бита на DAT) |
| 31 | adtc | R1 | SEND_WRITE_PROT_TYPE | `Data_address[31:0]` | ⬜ | Тип WP (64 бита на DAT) |

### Класс 7 — Lock Card

| CMD | Тип | Ответ | Название | Аргумент | Статус | Описание |
|-----|------|-------|----------|----------|--------|----------|
| 42 | adtc | R1 | LOCK_UNLOCK | `0x00000000` | ⬜ | Lock/Unlock/SetPwd/ClrPwd/Erase |

### Класс 8 — Application Specific

| CMD | Тип | Ответ | Название | Аргумент | Статус | Описание |
|-----|------|-------|----------|----------|--------|----------|
| 55 | ac | R1 | APP_CMD | `{RCA[31:16], 0}` | ⬜ | Префикс для ACMD |
| 56 | adtc | R1 | GEN_CMD | `{0, RD/WR:1}` | ⬜ | General purpose I/O |

### Класс 9 — I/O Mode

| CMD | Тип | Ответ | Название | Аргумент | Статус | Описание |
|-----|------|-------|----------|----------|--------|----------|
| 39 | ac | R4 | FAST_IO | `{RCA, Reg_addr:8, 0, Data:8}` | ⬜ | Быстрый R/W регистра |
| 40 | bcr | R5 | GO_IRQ_STATE | `0x00000000` | ⬜ | Вход в IRQ mode |

### Специальные команды (eMMC 5.0+)

| CMD | Тип | Ответ | Название | Аргумент | Статус | Описание |
|-----|------|-------|----------|----------|--------|----------|
| 49 | adtc | R1 | SET_TIME | `0x00000000` | ⬜ | Установка RTC (eMMC 5.0+) |

---

## 5. Детальное описание команд

### CMD0 — GO_IDLE_STATE

```
Index: 0   Arg: 0x00000000   Response: None   Class: 0
```

Сброс карты в Idle state. Первая команда после hardware reset (RST_n).
Варианты аргумента:
- `0x00000000` — обычный сброс
- `0xF0F0F0F0` — pre-idle (eMMC 4.5+, для boot mode)
- `0xFFFFFFFA` — boot initiation (карта шлёт boot data на DAT)

**В проекте (emmc_init.v:143):** `arg = 0x00000000`, без ожидания ответа.

### CMD1 — SEND_OP_COND

```
Index: 1   Arg: 0x40FF8080   Response: R3   Class: 0
```

Операция polling: host отправляет свои capabilities, карта отвечает своим OCR.
- Бит 30 (HCS) = 1 → host поддерживает sector addressing
- Биты 23:8 = voltage window
- Бит 7 = 1.7-1.95V support
- **Ответ R3:** бит 31 = 1 означает карта инициализирована (ready)

**В проекте (emmc_init.v:155):** `arg = 0x40FF8000`, polling до 200 попыток с проверкой resp[31].

### CMD2 — ALL_SEND_CID

```
Index: 2   Arg: 0x00000000   Response: R2 (136-bit)   Class: 0
```

Карта отправляет 128-бит CID (Card IDentification):
- Manufacturer ID (MID) — 8 бит
- Device/BGA (CBX) — 2 бита
- OEM ID (OID) — 8 бит
- Product Name (PNM) — 48 бит (6 ASCII символов)
- Product Revision (PRV) — 8 бит
- Serial Number (PSN) — 32 бит
- Manufacturing Date (MDT) — 8 бит

**В проекте (emmc_init.v:186):** CID сохраняется в `cid_reg[127:0]`.

### CMD3 — SET_RELATIVE_ADDR

```
Index: 3   Arg: {RCA, 16'h0000}   Response: R1   Class: 0
```

Host назначает Relative Card Address. В eMMC (в отличие от SD) RCA задаёт host.
Типичное значение RCA = `0x0001`. После CMD3 карта переходит в Stand-by state.

**В проекте (emmc_init.v:197):** `rca_reg = 16'h0001`.

### CMD6 — SWITCH

```
Index: 6   Arg: {2'b00, Access:2, Index:8, Value:8, CmdSet:3}   Response: R1b   Class: 10
```

Универсальная команда для записи **одного байта** в ExtCSD.

**Access mode (bits 25:24):**

| Access | Описание |
|--------|----------|
| 00 | Command Set — изменить активный набор команд |
| 01 | Set Bits — установить биты (OR) |
| 10 | Clear Bits — сбросить биты (AND NOT) |
| 11 | Write Byte — записать байт |

**Примеры аргументов:**

| Цель | Index | Value | Полный аргумент |
|------|-------|-------|----------------|
| Partition → boot0 | 179 | 0x01 | `0x03B30100` |
| Partition → boot1 | 179 | 0x02 | `0x03B30200` |
| Partition → user | 179 | 0x00 | `0x03B30000` |
| Bus width 4-bit | 183 | 0x01 | `0x03B70100` |
| Bus width 8-bit | 183 | 0x02 | `0x03B70200` |
| HS timing enable | 185 | 0x01 | `0x03B90100` |
| HS200 timing | 185 | 0x02 | `0x03B90200` |
| Cache enable | 33 | 0x01 | `0x03210100` |
| Cache disable | 33 | 0x00 | `0x03210000` |

**В проекте (emmc_controller.v:344):** `switch_arg = {6'b0, 2'b11, index, value, 8'b0}`
Используется для partition switch (ExtCSD[179]) и generic write-extcsd.

### CMD7 — SELECT/DESELECT_CARD

```
Index: 7   Arg: {RCA, 16'h0000}   Response: R1b   Class: 0
```

Выбирает карту (Stand-by → Transfer state). Только выбранная карта реагирует
на data-команды (CMD17/18/24/25/etc).

**В проекте (emmc_init.v:223):** после CMD9, переводит карту в Transfer state.

### CMD8 — SEND_EXT_CSD

```
Index: 8   Arg: 0x00000000   Response: R1 + 512B data   Class: 10
```

Карта отправляет 512 байт Extended CSD register на линии DAT.
Содержит конфигурацию карты: partition info, HS mode, cache, boot, RPMB и т.д.

**В проекте (emmc_controller.v:452):** данные сохраняются в sector buffer.

### CMD9 — SEND_CSD

```
Index: 9   Arg: {RCA, 16'h0000}   Response: R2 (136-bit)   Class: 0
```

128-бит CSD register содержит:
- CSD_STRUCTURE, SPEC_VERS — версия спецификации
- TAAC, NSAC — тайминг доступа
- TRAN_SPEED — максимальная скорость шины
- READ_BL_LEN, WRITE_BL_LEN — размер блока
- C_SIZE — ёмкость карты

**В проекте (emmc_init.v:212):** CSD сохраняется в `csd_reg[127:0]`.

### CMD12 — STOP_TRANSMISSION

```
Index: 12   Arg: 0x00000000   Response: R1/R1b   Class: 0
```

Прерывает multi-block операцию (CMD18/CMD25). В R1b варианте карта
может удерживать DAT0 busy пока не завершит текущую операцию.

Бит 0 аргумента = HPI (High Priority Interrupt) — прерывание текущей операции
с приоритетом. В проекте не используется (arg=0).

**В проекте (emmc_controller.v:531,587):** отправляется после CMD18 и CMD25.

### CMD13 — SEND_STATUS

```
Index: 13   Arg: {RCA, 16'h0000}   Response: R1   Class: 0
```

Запрашивает 32-бит Card Status. Полезно для:
- Проверки текущего состояния (биты 12:9)
- Проверки ошибок после операций
- Polling готовности (READY_FOR_DATA, бит 8)

Бит 15 аргумента = SQS (Status Query on Sequential) — для Sequential/Queued commands.

**В проекте:** не реализовано. Ошибки определяются по CRC и timeout.

### CMD16 — SET_BLOCKLEN

```
Index: 16   Arg: Block_length[31:0]   Response: R1   Class: 2
```

Устанавливает размер блока для последующих операций чтения/записи.
Для eMMC с sector addressing (>2GB) блок всегда 512 байт.

**В проекте (emmc_init.v:237):** `arg = 32'd512`, последняя команда init.

### CMD17 — READ_SINGLE_BLOCK

```
Index: 17   Arg: Data_address[31:0]   Response: R1 + 512B data   Class: 2
```

Чтение одного блока (512 байт). Для карт с sector addressing аргумент = LBA
(а не byte address). Данные передаются на DAT0 с CRC-16.

**В проекте (emmc_controller.v:431):** если `cmd_count <= 1`.

### CMD18 — READ_MULTIPLE_BLOCK

```
Index: 18   Arg: Data_address[31:0]   Response: R1 + N×512B data   Class: 2
```

Чтение нескольких блоков подряд. Карта шлёт блоки непрерывно пока не получит CMD12.
Альтернатива: предварительный CMD23 задаёт число блоков (без CMD12).

**В проекте (emmc_controller.v:431):** если `cmd_count > 1`. Терминируется CMD12.

### CMD23 — SET_BLOCK_COUNT

```
Index: 23   Arg: {Reliable_Write:1, 0[14:0], Block_count:16}   Response: R1   Class: 4
```

Задаёт число блоков для CMD18/CMD25. Если задан — CMD12 не нужен.
Бит 31 = Reliable Write (данные гарантированно на flash при power loss).

**В проекте:** не реализовано. Используется CMD12 для терминации.

### CMD24 — WRITE_BLOCK

```
Index: 24   Arg: Data_address[31:0]   Response: R1, затем host шлёт 512B   Class: 4
```

Запись одного блока. После R1 host передаёт данные на DAT0 с CRC-16.
Карта отвечает 3-бит CRC status и удерживает DAT0 busy до завершения записи.

**В проекте (emmc_controller.v:446):** если `cmd_count <= 1`.

### CMD25 — WRITE_MULTIPLE_BLOCK

```
Index: 25   Arg: Data_address[31:0]   Response: R1, затем host шлёт N×512B   Class: 4
```

Запись нескольких блоков подряд. Терминируется CMD12 или предварительным CMD23.

**В проекте (emmc_controller.v:446):** если `cmd_count > 1`. Терминируется CMD12.

### CMD35 — ERASE_GROUP_START

```
Index: 35   Arg: Data_address[31:0]   Response: R1   Class: 5
```

Устанавливает начальный адрес диапазона стирания. Для sector-addressed карт = LBA.

**В проекте (emmc_controller.v:469):** `arg = cmd_lba`.

### CMD36 — ERASE_GROUP_END

```
Index: 36   Arg: Data_address[31:0]   Response: R1   Class: 5
```

Устанавливает конечный адрес диапазона стирания.

**В проекте (emmc_controller.v:720):** `arg = erase_end_lba = cmd_lba + cmd_count - 1`.
Значение `erase_end_lba` предвычислено pipeline-регистром для оптимизации тайминга.

### CMD38 — ERASE

```
Index: 38   Arg: 0x00000000   Response: R1b (+ DAT0 busy)   Class: 5
```

Выполняет стирание ранее заданного диапазона (CMD35→CMD36→CMD38).

| Аргумент | Операция |
|----------|----------|
| `0x00000000` | Normal Erase (карта может не обнулять, а пометить) |
| `0x00000001` | Trim (гарантированно недоступны, но не обнулены) |
| `0x80000000` | Secure Erase (перезапись паттерном) |
| `0x80000001` | Secure Trim Step 1 |
| `0x80008000` | Secure Trim Step 2 |

**В проекте (emmc_controller.v:736):** `arg = 0`, обычный erase. Busy wait в MC_SWITCH_WAIT.

### CMD5 — SLEEP_AWAKE

```
Index: 5   Arg: {RCA, 0[14:0], Sleep:1}   Response: R1b   Class: 0
```

Переводит карту в sleep mode (ultra low power) или выводит из него.
- Sleep=1 → вход в sleep (сначала нужен CMD7 deselect)
- Sleep=0 → выход из sleep (затем CMD7 select)

**В проекте:** не реализовано.

### CMD42 — LOCK_UNLOCK

```
Index: 42   Arg: 0x00000000   Response: R1 + data block   Class: 7
```

Управление паролем карты. Данные (на DAT) содержат:
- Set Password / Clear Password / Lock / Unlock / Force Erase
- Password длиной до 16 байт (определяется PWD_LEN)

**В проекте:** не реализовано.

---

## 6. Состояния карты (Card States)

```
  ┌─────────┐
  │  Idle   │◄──── CMD0 (Reset)
  │ (idle)  │
  └────┬────┘
       │ CMD1 (ready)
  ┌────▼────┐
  │  Ready  │
  │ (ready) │
  └────┬────┘
       │ CMD2
  ┌────▼────┐
  │  Ident  │
  │ (ident) │
  └────┬────┘
       │ CMD3
  ┌────▼────┐
  │ Stand-by│◄──── CMD7 (deselect) ◄──┐
  │  (stby) │                          │
  └────┬────┘                          │
       │ CMD7 (select)                 │
  ┌────▼────┐                          │
  │Transfer │──────────────────────────┘
  │  (tran) │
  └──┬───┬──┘
     │   │
     │   │ CMD17/18 (read)     CMD24/25 (write)
     │   │                      │
  ┌──▼───┐                 ┌────▼───┐
  │ Data │                 │Receive │
  │(data)│                 │ (rcv)  │
  └──┬───┘                 └────┬───┘
     │ CMD12/done               │ CMD12/done
     │                          │
     │   ┌──────────┐          │
     └──►│Programming│◄────────┘
         │  (prg)    │
         └─────┬─────┘
               │ done
               ▼
           Transfer (tran)
```

**CURRENT_STATE в Card Status (биты 12:9):**

| Код | Состояние | Описание |
|-----|-----------|----------|
| 0 | idle | После CMD0, до CMD1 |
| 1 | ready | CMD1 accepted, OCR ready |
| 2 | ident | CMD2 accepted, CID sent |
| 3 | stby | CMD3 accepted, RCA assigned |
| 4 | tran | CMD7 accepted, готов к data transfer |
| 5 | data | Передача данных (read) |
| 6 | rcv | Приём данных (write) |
| 7 | prg | Программирование flash |
| 8 | dis | Disconnect (CMD7 deselect во время data) |
| 9 | btst | Bus test mode |
| 10 | slp | Sleep mode (CMD5) |
| 11-15 | — | Reserved |

---

## 7. Протокол передачи данных (DAT)

### Чтение (Card → Host)

```
Card sends on DAT0:
┌───┬──────────────────────────┬──────────┬───┐
│ 0 │    4096 бит (512 байт)   │ CRC-16   │ 1 │
│   │    MSB first per byte    │ (16 бит) │   │
└───┴──────────────────────────┴──────────┴───┘
 Start       Data payload          CRC      End
  bit                                        bit
```

- Start bit = 0, End bit = 1
- Данные: MSB first в каждом байте
- CRC-16: покрывает 4096 бит данных (poly = 0x1021)
- Host сэмплирует на rising edge eMMC CLK

### Запись (Host → Card)

```
Host sends on DAT0:
┌───┬──────────────────────────┬──────────┬───┐
│ 0 │    4096 бит (512 байт)   │ CRC-16   │ 1 │
│   │    MSB first per byte    │ (16 бит) │   │
└───┴──────────────────────────┴──────────┴───┘

Card responds (CRC Status Token):
┌───┬─────────┬───┬────────────────────┐
│ 0 │ Status  │ 1 │  Busy (DAT0 = 0)   │
│   │ (3 бит) │   │  до завершения     │
└───┴─────────┴───┴────────────────────┘
```

**CRC Status Token (3 бита):**

| Значение | Описание |
|----------|----------|
| 010 | CRC OK, данные приняты |
| 101 | CRC Error, данные отклонены |
| 111 | Write Error (не CRC) |

### Multi-block transfer

При чтении (CMD18) карта шлёт блоки непрерывно:

```
[Block 1: start + 512B + CRC + end] [Block 2: start + 512B + CRC + end] ... [CMD12 → stop]
```

При записи (CMD25) host шлёт блоки, каждый получает CRC status:

```
[Block 1 → CRC status → Busy] [Block 2 → CRC status → Busy] ... [CMD12 → stop]
```

---

## 8. CRC алгоритмы

### CRC-7 (командная линия)

| Параметр | Значение |
|----------|----------|
| Polynomial | x⁷ + x³ + 1 (0x09) |
| Init | 0x00 |
| Покрытие | Биты 47–8 команды (40 бит) |
| Модуль | `emmc_crc7.v` |

### CRC-16 (линия данных)

| Параметр | Значение |
|----------|----------|
| Polynomial | x¹⁶ + x¹² + x⁵ + 1 (0x1021, CCITT) |
| Init | 0x0000 |
| Покрытие | 4096 бит данных (512 байт) |
| Модуль | `emmc_crc16.v` |

---

## 9. Тайминги

### Ключевые задержки (JEDEC)

| Параметр | Мин | Макс | Описание |
|----------|-----|------|----------|
| NCR | 2 | 64 | Command → Response (eMMC CLK cycles) |
| NRC | 8 | — | Response → next Command |
| NCC | 8 | — | Command → Command (без data) |
| NWR | 2 | — | CRC status end → next data block start |
| NAC | — | 10×TAAC + NCR | Read data timeout |

### Тайминги в проекте

| Параметр | Значение | Файл |
|----------|----------|------|
| CMD response timeout | 1024 eMMC CLK | emmc_cmd.v |
| DAT read timeout | 65536 clk_en | emmc_dat.v |
| DAT busy timeout (write) | 65536 clk_en | emmc_dat.v |
| SWITCH busy timeout | 2²⁰ (~13 мс @ 81 МГц) | emmc_controller.v |
| Init CLK | ~300 кГц (div=270) | emmc_controller.v |
| Data CLK | ~10 МГц (div=4) | emmc_controller.v |
| CMD1 retries | 200 | emmc_init.v |

---

## 10. Extended CSD — ключевые поля

512-байт регистр, читается CMD8. Байты 0–191 = Properties (read-only), 192–511 = Modes (R/W через CMD6).

### Properties (Read-Only)

| Byte | Название | Описание |
|------|----------|----------|
| 192 | EXT_CSD_REV | Версия ExtCSD (7 = eMMC 5.0/5.1) |
| 196 | DEVICE_TYPE | Поддерживаемые speed modes |
| 212-215 | SEC_COUNT | Общая ёмкость в секторах |
| 226 | BOOT_SIZE_MULT | Размер boot partition (×128KB) |
| 224 | HC_ERASE_GRP_SIZE | Размер erase group (×512KB) |
| 221 | HC_WP_GRP_SIZE | Размер WP group |
| 168 | RPMB_SIZE_MULT | Размер RPMB partition (×128KB) |
| 231 | PARTITION_SETTING_COMPLETED | Partition config финализирован |
| 228 | GP_SIZE_MULT | Размеры GP партиций |

### Modes (Read/Write via CMD6)

| Byte | Название | Access | Описание |
|------|----------|--------|----------|
| 179 | PARTITION_ACCESS | Write | Выбор partition (0=user, 1=boot0, 2=boot1, 3=RPMB) |
| 177 | BOOT_CONFIG | Write | Boot partition config |
| 183 | BUS_WIDTH | Write | Ширина шины (0=1bit, 1=4bit, 2=8bit) |
| 185 | HS_TIMING | Write | Speed mode (0=legacy, 1=HS, 2=HS200, 3=HS400) |
| 33 | CACHE_CTRL | Write | 1=enable cache, 0=disable |
| 32 | FLUSH_CACHE | Write | 1=trigger cache flush |
| 162 | RST_n_FUNCTION | Write | 0=RST_n disabled, 1=enabled, 2=permanently enabled |
| 175 | ERASE_GROUP_DEF | Write | 0=old def, 1=HC erase group |

---

## 11. Реализация в проекте

### Команды, реализованные в RTL

| CMD | Модуль | Строки | Контекст |
|-----|--------|--------|----------|
| CMD0 | emmc_init.v | 143-152 | SI_CMD0, сброс карты |
| CMD1 | emmc_init.v | 155-176 | SI_CMD1, polling OCR ready |
| CMD2 | emmc_init.v | 186-195 | SI_CMD2, получение CID |
| CMD3 | emmc_init.v | 197-210 | SI_CMD3, назначение RCA=0x0001 |
| CMD9 | emmc_init.v | 212-221 | SI_CMD9, получение CSD |
| CMD7 | emmc_init.v | 223-235 | SI_CMD7, select card |
| CMD16 | emmc_init.v | 237-246 | SI_CMD16, block len = 512 |
| CMD6 | emmc_controller.v | 474-486 | Partition switch / ExtCSD write |
| CMD8 | emmc_controller.v | 452-457 | Read ExtCSD (512B) |
| CMD12 | emmc_controller.v | 531,587 | Stop multi-block CMD18/CMD25 |
| CMD17 | emmc_controller.v | 431 | Read single block |
| CMD18 | emmc_controller.v | 431 | Read multiple blocks |
| CMD24 | emmc_controller.v | 446 | Write single block |
| CMD25 | emmc_controller.v | 446 | Write multiple blocks |
| CMD35 | emmc_controller.v | 469 | Erase group start |
| CMD36 | emmc_controller.v | 720 | Erase group end |
| CMD38 | emmc_controller.v | 736 | Execute erase |
| CMD13 | emmc_controller.v | MC_STATUS_CMD | SEND_STATUS (Card Status Register, 32-bit) |
| CMD0 (reinit) | emmc_controller.v | MC_IDLE→MC_INIT | RE-INIT (full init via reinit_pending flag) |
| CMD38 (secure) | emmc_controller.v | MC_ERASE_CMD | Secure Erase (CMD38 arg=0x80000000, erase_secure reg) |

### Последовательность инициализации

```
Power On → RST_n pulse → 74+ clock cycles →
CMD0 (idle) → CMD1 (poll OCR×200) → CMD2 (get CID) →
CMD3 (set RCA=1) → CMD9 (get CSD) → CMD7 (select) →
CMD16 (blocklen=512) → switch to fast CLK → READY
```

### Команды, НЕ реализованные (потенциальные расширения)

| CMD | Назначение | Приоритет |
|-----|-----------|-----------|
| CMD5 | Sleep mode (power saving) | Low |
| CMD23 | Pre-defined block count (вместо CMD12) | Medium |
| CMD14/19 | Bus test (для 4/8-bit mode) | N/A (1-bit mode) |
| CMD21 | Tuning (для HS200/HS400) | N/A (10 MHz mode) |
| CMD42 | Lock/Unlock (security) | Low |

---

## Источники

- [JEDEC JESD84-B51 (eMMC 5.1)](https://www.jedec.org/standards-documents/technology-focus-areas/flash-memory-ssds-ufs-emmc/e-mmc) — официальная спецификация
- [eMMC Protocol — Prodigy Technovations](https://www.prodigytechno.com/emmc-protocol) — обзор протокола
- [How to Use MMC/SDC — elm-chan.org](https://elm-chan.org/docs/mmc/mmc_e.html) — практическое руководство
- [eMMC Commands — PushMindStack Wiki](https://wiki.pushmindstack.com/storage/emmc/command) — таблица команд
- [Linux kernel mmc/mmc.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/mmc/mmc.h) — определения команд в ядре Linux
- [Lauterbach eMMC FLASH Programming Guide (02.2025)](https://www2.lauterbach.com/pdf/emmcflash.pdf) — практическое программирование
- [JEDEC JESD84-A43 (MMC 4.3)](https://community.nxp.com/pwmxy87654/attachments/pwmxy87654/lpc/27039/1/JESD84-A43.pdf) — ранняя версия стандарта
