# eMMC Card Reader - Tang Nano 9K

FPGA-проект для чтения/записи eMMC через USB-UART на плате Sipeed Tang Nano 9K (Gowin GW1NR-9C).

## Железо

- **Плата:** Sipeed Tang Nano 9K (GW1NR-LV9QN88PC6/I5)
- **eMMC:** подключена к BANK3 (1.8V), поддержка 1-bit и 4-bit режимов
- **Связь с ПК:** USB-UART через FT2232HL (внешний) или BL702 (на плате), 3-12 Мбод
- **Тактирование:** 27 МГц кварц -> PLL -> 60 МГц системная частота

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
PC (emmc_tool.py / Rust GUI) <--UART 3-12 Mbaud--> FPGA (Tang Nano 9K) <--eMMC bus--> eMMC chip
```

### Модули (SpinalHDL)

```
top.v                  — Top-level: PLL, reset sync, tristate
├── pll.v              — rPLL: 27 MHz -> 60 MHz
├── emmc_controller    — eMMC хост: CMD/DAT FSM, init, clock gen, sector buffer
│   ├── EmmcInit       — Инициализация (CMD0->CMD1->CMD2->CMD3->CMD9->CMD7->CMD16)
│   ├── EmmcCmd        — CMD-линия: отправка команд, приём R1/R2/R3, CRC7
│   ├── EmmcDat        — DAT: чтение/запись 1-bit и 4-bit, CRC16 (8 инстансов)
│   ├── SectorBuf      — Read BRAM 1024 байт, ping-pong 2x512
│   └── SectorBufWr    — Write FIFO 8192 байт, 16x512 банков
├── uart_bridge        — UART-протокол: разбор команд, формирование ответов
│   ├── UartRx/UartTx  — UART приёмник/передатчик
│   └── Crc8           — CRC-8
└── led_status         — LED-индикация (6 LED, active-low)
```

RTL написан на SpinalHDL (Scala), генерирует Verilog в `generated/`.

## UART-протокол

**PC -> FPGA:** `[0xAA] [CMD_ID] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]`

**FPGA -> PC:** `[0x55] [CMD_ID] [STATUS] [LEN_H] [LEN_L] [PAYLOAD...] [CRC8]`

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

## Режим работы eMMC

- **1-bit SDR** (DAT0) — по умолчанию после инициализации
- **4-bit SDR** (DAT0-DAT3) — переключается runtime через CMD 0x11
- Инициализация на 400 кГц, рабочая частота 2-30 МГц (preset 0-6)
- Multi-block операции (CMD18/CMD25) + CMD12 STOP
- Ping-pong буфер: UART читает из одного буфера, eMMC пишет в другой
- Write FIFO: 16x512 байт, поточная загрузка через UART
- RPMB: CMD23 + CMD25/CMD18, authenticated frame protocol

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
```

Порт: `/dev/ttyUSB1` (FT2232HL) или `/dev/ttyACM0` (BL702). Baud: 3M default.

Полный CLI reference: **[docs/cli_reference.md](docs/cli_reference.md)**

## Сборка и прошивка

### SpinalHDL -> Verilog

```bash
sbt test                                        # 96 тестов (Verilator)
sbt "runMain emmcreader.EmmcCardReaderVerilog"   # генерация Verilog
```

### Синтез FPGA

```bash
gw_sh build.tcl                                  # Gowin synthesis + PnR
```

Bitstream: `impl/pnr/card_reader.fs`

### Прошивка

```bash
# SRAM (временная):
sudo rmmod ftdi_sio 2>/dev/null
openFPGALoader -m impl/pnr/card_reader.fs
sudo modprobe ftdi_sio

# Flash (постоянная):
openFPGALoader -f --detect impl/pnr/card_reader.fs
```

## Симуляция

96 тестов на SpinalSim (Verilator backend) покрывают все RTL-модули:

```bash
sbt test        # запустить все 96 тестов
```

16 дополнительных тестбенчей на Icarus Verilog:

```bash
cd sim && make  # запустить все 16 тестов
```

## Ресурсы FPGA

| Ресурс    | Использовано | Доступно | % |
|-----------|-------------|----------|---|
| LUT       | 3310        | 8640     | 38% |
| BSRAM     | 5           | 26       | 20% |
| Fmax      | 60.3 МГц   | -        | -   |

## Лицензия

MIT
