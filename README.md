# eMMC Card Reader - Tang Nano 9K

FPGA-проект для чтения/записи eMMC через USB на плате Sipeed Tang Nano 9K (Gowin GW1NR-9C).

## Железо

- **Плата:** Sipeed Tang Nano 9K (GW1NR-LV9QN88PC6/I5)
- **eMMC:** подключена к BANK3 (1.8V), поддержка 1-bit и 4-bit режимов
- **Связь с ПК:** UART (FT232H / BL702, 3-12 Мбод) или FT245 FIFO (~7.5 MB/s)
- **Тактирование:** 27 МГц кварц → PLL → 60 МГц системная частота

### Распиновка eMMC

| Сигнал    | Пин FPGA | Банк | Описание         |
|-----------|----------|------|------------------|
| emmc_clk  | 82       | 3    | Тактовая (2-30 МГц) |
| emmc_rstn | 81       | 3    | Reset (active low)  |
| emmc_cmd  | 79       | 3    | CMD-линия (bidir)   |
| emmc_dat0 | 80       | 3    | DAT0 (bidir)        |
| emmc_dat1 | 83       | 3    | DAT1 (4-bit mode)   |
| emmc_dat2 | 84       | 3    | DAT2 (4-bit mode)   |
| emmc_dat3 | 85       | 3    | DAT3 (4-bit mode)   |

## Архитектура

```
                    UART 3-12 Mbaud
PC (tools / GUI) <──────────────────> FPGA (Tang Nano 9K) <──eMMC bus──> eMMC chip
                    FT245 FIFO ~7.5 MB/s
```

Два варианта transport:
- **UART** (`build.tcl`) — через FT232H или BL702, 3/6/12 Мбод
- **FT245 FIFO** (`build_fifo.tcl`) — через FT232H в режиме 245 FIFO, 8-bit параллельный, ~3x быстрее UART

### Модули (SpinalHDL)

```
top.v                  — Top-level: PLL, reset sync, tristate
├── pll.v              — rPLL: 27 MHz → 60 MHz
├── emmc_controller    — eMMC хост: CMD/DAT FSM, init, clock gen, sector buffer
│   ├── EmmcInit       — Инициализация (CMD0→CMD1→CMD2→CMD3→CMD9→CMD7→CMD16)
│   ├── EmmcCmd        — CMD-линия: отправка команд, приём R1/R2/R3, CRC7
│   ├── EmmcDat        — DAT: чтение/запись 1-bit и 4-bit, CRC16 (8 инстансов)
│   ├── SectorBuf      — Read BRAM 1024 байт, ping-pong 2×512
│   └── SectorBufWr    — Write FIFO 8192 байт, 16×512 банков
├── uart_bridge        — UART-протокол (или fifo_bridge для FT245)
│   ├── UartRx/UartTx  — UART приёмник/передатчик
│   ├── Ft245Fifo      — FT245 async FIFO PHY (только FIFO вариант)
│   └── Crc8           — CRC-8
└── led_status         — LED-индикация (6 LED, active-low)
```

RTL написан на SpinalHDL (Scala), генерирует Verilog в `generated/`.

## Протокол

**PC → FPGA:** `[0xAA] [CMD_ID] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]`

**FPGA → PC:** `[0x55] [CMD_ID] [STATUS] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]`

### Команды

| CMD_ID | Имя              | Описание                               |
|--------|------------------|-----------------------------------------|
| 0x01   | PING             | Проверка связи                          |
| 0x02   | GET_INFO         | CID + CSD (32 байта)                   |
| 0x03   | READ_SECTOR      | Чтение секторов (multi-block CMD18)     |
| 0x04   | WRITE_SECTOR     | Запись секторов (multi-block CMD25)     |
| 0x05   | ERASE            | Стирание секторов                       |
| 0x06   | GET_STATUS       | Debug status (12 байт)                  |
| 0x07   | GET_EXT_CSD      | Extended CSD (512 байт)                 |
| 0x08   | SET_PARTITION     | 0=user, 1=boot0, 2=boot1, 3=RPMB       |
| 0x09   | WRITE_EXT_CSD    | CMD6 SWITCH (index + value)             |
| 0x0A   | GET_CARD_STATUS   | CMD13 (4 байта)                        |
| 0x0B   | REINIT           | Полная переинициализация                |
| 0x0C   | SECURE_ERASE     | CMD38 arg=0x80000000                    |
| 0x0D   | SET_CLK_DIV      | eMMC CLK preset (0-6, 2-30 МГц)        |
| 0x0E   | SEND_RAW_CMD     | Произвольная eMMC CMD                   |
| 0x0F   | SET_BAUD         | UART baud preset (3M/6M/12M)           |
| 0x10   | SET_RPMB_MODE    | Force CMD25/CMD18 + CMD23 для RPMB      |
| 0x11   | SET_BUS_WIDTH    | Переключение 1-bit/4-bit DAT bus        |

Status: 0x00=OK, 0x01=CRC Error, 0x02=Unknown CMD, 0x03=eMMC Error, 0x04=Busy.

## Скорость

| Transport | eMMC bus | eMMC CLK | Read KB/s | Write KB/s |
|-----------|----------|----------|-----------|------------|
| UART 12M  | 1-bit    | 10 МГц  | 636       | 481        |
| FT245 FIFO| 4-bit    | 6 МГц   | 1840      | 805        |

## GUI (Rust)

### Programmer GUI (универсальный)

```bash
cd emmc-programmer && cargo run --release -p programmer-gui
```

6 вкладок: ChipInfo, Operations, Partitions, HexEditor, Filesystem, ImageManager.

### Legacy GUI

```bash
cd emmc-gui && cargo run --release
```

5 вкладок: eMMC Info, Sectors, Partitions, ext4 Browser, Hex Editor.

## Python CLI

```bash
pip install pyserial

python3 tools/emmc_tool.py ping                           # проверка связи
python3 tools/emmc_tool.py info                            # CID/CSD
python3 tools/emmc_tool.py --fast dump output.img          # полный дамп (12M + 10 MHz)
python3 tools/emmc_tool.py --fast restore input.img        # восстановление
python3 tools/emmc_tool.py bus-width 4                     # переключение на 4-bit
python3 tools/emmc_tool.py bus-width 1                     # обратно на 1-bit
python3 tools/emmc_tool.py partitions                      # таблица разделов
python3 tools/emmc_tool.py --fifo --fast dump output.img   # дамп через FT245 FIFO
```

Порт: `/dev/ttyUSB1` (FT232H) или `/dev/ttyACM0` (BL702). Baud: 3M default.

Полный CLI reference: **[docs/cli_reference.md](docs/cli_reference.md)**

## Сборка и прошивка

### SpinalHDL → Verilog

```bash
sbt test                                        # 92 теста (Verilator)
sbt "runMain emmcreader.EmmcCardReaderVerilog"   # генерация Verilog
```

### Синтез FPGA

```bash
gw_sh build.tcl                                  # UART variant
gw_sh build_fifo.tcl                             # FT245 FIFO variant
```

Bitstream: `impl/pnr/card_reader.fs` (UART) / `impl/pnr/card_reader_fifo.fs` (FIFO)

### Прошивка

```bash
# SRAM (временная):
sudo openFPGALoader -b tangnano9k impl/pnr/card_reader.fs

# Flash (постоянная):
sudo openFPGALoader -f -b tangnano9k impl/pnr/card_reader.fs
```

## Симуляция

92 теста на SpinalSim (Verilator backend) покрывают все RTL-модули:

```bash
sbt test        # запустить все 92 теста
```

16 дополнительных тестбенчей на Icarus Verilog:

```bash
cd sim && make  # запустить все 16 тестов
```

## Ресурсы FPGA

| Ресурс    | Использовано | Доступно | % |
|-----------|-------------|----------|---|
| LUT       | ~3100       | 8640     | 36% |
| BSRAM     | 5           | 26       | 20% |
| Fmax      | 60 МГц     | -        | -   |

## Лицензия

MIT
