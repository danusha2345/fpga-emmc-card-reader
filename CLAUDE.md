# eMMC Card Reader — Tang Nano 9K

## Сборка

**GUI:** Gowin IDE → Open Project → `card_reader.gprj` → Run All (Synthesize + PnR)

**CLI (headless):**
```bash
gw_sh build.tcl        # UART variant
gw_sh build_fifo.tcl   # FT245 FIFO variant
```
`build.tcl` включает оптимизации: `place_option 2`, `route_option 2`, timing-driven, retiming, replicate_resources.

## Python-утилита (основные команды)

```bash
python3 tools/emmc_tool.py ping                           # проверка связи
python3 tools/emmc_tool.py info                            # CID/CSD
python3 tools/emmc_tool.py read <lba> <count> <outfile>    # чтение секторов
python3 tools/emmc_tool.py read --fast 0 5873664 out.img   # чтение с авто 12M+10MHz
python3 tools/emmc_tool.py --fast dump output.img          # полный дамп (12M + 10 MHz)
python3 tools/emmc_tool.py --fast dump --verify output.img # дамп + readback verify
python3 tools/emmc_tool.py --fast restore input.img        # восстановление
python3 tools/emmc_tool.py --fast restore --verify input.img # restore + readback verify
python3 tools/emmc_tool.py write --fast --verify 0 data.bin # запись + verify
python3 tools/emmc_tool.py verify --fast 0 dump.img        # верификация
python3 tools/emmc_tool.py partitions                      # таблица разделов
python3 tools/emmc_tool.py bus-width 4                      # переключение на 4-bit DAT bus
python3 tools/emmc_tool.py bus-width 1                      # обратно на 1-bit DAT bus
python3 tools/emmc_tool.py rpmb-counter                    # RPMB write counter + MAC verify
python3 tools/emmc_tool.py rpmb-read 0 --hex               # RPMB authenticated read addr 0
python3 tools/emmc_tool.py rpmb-dump rpmb.bin              # полный RPMB дамп
python3 tools/repair_dump.py dump.img --port /dev/ttyUSB1   # перечитка нулевых чанков
```

Порт: `/dev/ttyUSB1` (FT2232HL) или `/dev/ttyACM0` (BL702). Baud: 3M default.
FIFO transport: `--fifo` (FT232H, 245 FIFO mode, `pip install pyftdi`).
Полный CLI reference: **[docs/cli_reference.md](docs/cli_reference.md)**

## Прошивка FPGA

**SRAM (временная):**
```bash
sudo rmmod ftdi_sio 2>/dev/null
programmer_cli --device GW1NR-9C --operation_index 2 \
  --fsFile impl/pnr/card_reader.fs --cable-index 1
sudo modprobe ftdi_sio
```

**Flash (постоянная):** `--operation_index 5` (не 6 — verify зависает на FT2232C-клоне).
`programmer_cli` → `~/gowin/Programmer/bin/programmer_cli`.

## Rust GUI

### Programmer GUI (новый, универсальный)

```bash
cd emmc-programmer && cargo run --release -p programmer-gui
```

Workspace: **programmer-hal** (traits) → **programmer-fpga** (FPGA UART/FIFO adapter) → **programmer-engine** (state, commands, operations) → **programmer-gui** (egui UI).
Transport: UART или FT245 FIFO (feature `fifo`, default). FIFO даёт 3x ускорение чтения (1840 vs 636 KB/s).
6 вкладок: ChipInfo, Operations, Partitions, HexEditor, Filesystem, ImageManager.
Hotkeys: Ctrl+1..6 табы, Ctrl+L лог, Escape отмена.
ChipInfo: полный ExtCSD viewer (Device Info, Speed Modes, Boot Config, Health с прогресс-барами). Chip DB: 30 производителей + 40+ продуктов (серия, NAND тип, eMMC версия).
Operations: Read/Write/Erase/SecureErase, Verify/BlankCheck, DumpFull/RestoreFull, Card Status (CMD13), Raw CMD, ExtCSD Write.
Partitions: GPT/MBR parsing, кнопка "ext4" → переход в Filesystem tab.

### Legacy GUI (emmc-gui)

```bash
cd emmc-gui && cargo run --release
```

Workspace: **emmc-core** (протокол, Transport trait UART/FIFO, ext4, RPMB) → **emmc-app** (state, worker) → **emmc-gui** (egui UI, theme, hotkeys).
Transport: `Transport` trait абстрагирует UART (`SerialTransport`) и FIFO (`FifoTransport`, feature `fifo` — default, `rusb`).
Подробнее: **[docs/gui.md](docs/gui.md)**

## Архитектура

```
PC (emmc_tool.py / emmc-gui) ←UART 3Mbaud / FT245 FIFO→ FPGA (Tang Nano 9K) ←eMMC bus→ eMMC chip
```

### Иерархия модулей (UART variant)
```
top.v                  — Top-level: PLL, reset sync, связи модулей
├── pll.v              — rPLL: 27 MHz → 60 MHz (GW1NR-9C)
├── emmc_controller.v  — eMMC хост: CMD/DAT FSM, init, clock gen, sector buffer
│   ├── emmc_init.v    — Инициализация (CMD0→CMD1→CMD2→CMD3→CMD9→CMD7→CMD16)
│   ├── emmc_cmd.v     — CMD-линия: отправка команд, приём R1/R2/R3, CRC7
│   ├── emmc_dat.v     — DAT0-3: чтение/запись данных, CRC16 (1/4-bit)
│   ├── emmc_crc7.v    — CRC-7
│   ├── emmc_crc16.v   — CRC-16
│   ├── sector_buf.v   — Read BRAM 1024 байт, ping-pong 2×512
│   └── sector_buf_wr.v — Write FIFO 8192 байт, 16×512 банков
├── uart_bridge.v      — UART-протокол: разбор команд, формирование ответов
│   ├── uart_rx.v      — UART приёмник
│   ├── uart_tx.v      — UART передатчик
│   └── crc8.v         — CRC-8
└── led_status.v       — LED-индикация (6 LED, active-low)
```

### Иерархия модулей (FIFO variant)
```
top_fifo.v             — Top-level: PLL, reset sync, FIFO tristate
├── pll.v
├── emmc_controller.v  — (идентичен UART variant)
├── fifo_bridge.v      — FT245 FIFO протокол (UartBridge с useFifo=true)
│   ├── ft245_fifo.v   — FT245 async FIFO PHY (8-bit parallel, RD#/WR#)
│   └── crc8.v         — CRC-8
└── led_status.v
```

## Ключевые параметры

| Параметр | Значение |
|---|---|
| FPGA | GW1NR-9C QN88P (Gowin LittleBee) |
| System CLK | 60 МГц (PLL: 27 × 20 / 9) |
| Transport | UART 3M default (CMD 0x0F) / FT245 FIFO (~7.5 MB/s) |
| eMMC bus | 1-bit default, 4-bit runtime (CMD 0x11) |
| eMMC CLK | 2 МГц default (runtime CMD 0x0D, presets 0-6) |
| Buffers | Read: 2×512 ping-pong, Write: 16×512 FIFO, BSRAM 5/26 |
| Best speed | FIFO + 4-bit 6MHz: read 1840, write 805 KB/s |

### Пресеты eMMC CLK (CMD 0x0D)

| Preset | Делитель | Частота |
|--------|----------|---------|
| 0 | 15 | 2 МГц (default) |
| 1 | 8 | 3.75 МГц |
| 2 | 5 | 6 МГц |
| 3 | 3 | 10 МГц |
| 4 | 2 | 15 МГц |
| 6 | 1 | 30 МГц (только PCB) |

## UART-протокол

**PC → FPGA:** `[0xAA] [CMD] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]`
**FPGA → PC:** `[0x55] [CMD] [STATUS] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]`

| ID | Команда | Payload (TX) | Описание |
|---|---|---|---|
| 0x01 | PING | — | Проверка связи |
| 0x02 | GET_INFO | — | CID + CSD (32 байта) |
| 0x03 | READ_SECTOR | LBA(4) + COUNT(2) | Чтение секторов |
| 0x04 | WRITE_SECTOR | LBA(4) + COUNT(2) + DATA(N×512) | Запись секторов |
| 0x05 | ERASE | LBA(4) + COUNT(2) | Стирание |
| 0x06 | GET_STATUS | — | Debug status (12 байт) |
| 0x07 | GET_EXT_CSD | — | Extended CSD (512 байт) |
| 0x08 | SET_PARTITION | PART_ID(1) | 0=user, 1=boot0, 2=boot1 |
| 0x09 | WRITE_EXT_CSD | INDEX(1) + VALUE(1) | CMD6 SWITCH |
| 0x0A | GET_CARD_STATUS | — | CMD13 (4 байта) |
| 0x0B | REINIT | — | Полная переинициализация |
| 0x0C | SECURE_ERASE | LBA(4) + COUNT(2) | CMD38 arg=0x80000000 |
| 0x0D | SET_CLK_DIV | PRESET(1) | eMMC CLK (preset 0-6) |
| 0x0E | SEND_RAW_CMD | INDEX(1)+ARG(4)+FLAGS(1) | Произвольная eMMC CMD |
| 0x0F | SET_BAUD | PRESET(1) | UART baud (0=3M, 1=6M, 3=12M) |
| 0x10 | SET_RPMB_MODE | MODE(1) | 0=normal, 1=force CMD25/CMD18 for count=1 |
| 0x11 | SET_BUS_WIDTH | WIDTH(1) | 0=1-bit, 1=4-bit (CMD6 ExtCSD[183]) |

Status: 0x00=OK, 0x01=CRC Error, 0x02=Unknown CMD, 0x03=eMMC Error, 0x04=Busy.
Подробнее (RAW_CMD, baud handshake, GET_STATUS bitfield, RPMB): **[docs/protocol.md](docs/protocol.md)**

## Симуляция (Icarus Verilog)

```bash
cd sim && make          # запустить все 16 тестов
cd sim && make test_crc8  # один конкретный тест
```

16 тестбенчей, 98 сценариев. Подробнее: **[docs/testbenches.md](docs/testbenches.md)**

## Документация (docs/)

| Файл | Содержимое |
|------|-----------|
| [docs/cli_reference.md](docs/cli_reference.md) | Полный Python CLI (все команды emmc_tool.py) |
| [docs/protocol.md](docs/protocol.md) | UART протокол: RAW_CMD, baud presets, GET_STATUS, RPMB |
| [docs/hardware.md](docs/hardware.md) | Распиновки (eMMC, UART, FT245 FIFO), CJMCU-2232HL, FT2232C quirks |
| [docs/testbenches.md](docs/testbenches.md) | Все 98 тестовых сценариев + card stub |
| [docs/speed.md](docs/speed.md) | Speed sweep v1-v9, UART vs FIFO, 1-bit vs 4-bit |
| [docs/fpga_internals.md](docs/fpga_internals.md) | Защитные механизмы, тайминг-оптимизации |
| [docs/gui.md](docs/gui.md) | Rust GUI архитектура, ext4, OTA builder |
