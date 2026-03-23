# Hardware — Pinout & Adapters

## Распиновка eMMC (Bank 3, 1.8V)

| Сигнал | FPGA Pin | IO Site | Направление | Примечание |
|---|---|---|---|---|
| emmc_cmd | 79 | IOT12[B] | bidir | Внутренний PULL_MODE=UP (~100K к 1.8V) |
| emmc_dat0 | 80 | IOT12[A] | bidir | Внутренний PULL_MODE=UP (~100K к 1.8V) |
| emmc_rstn | 81 | IOT11[B] | output | Active-low reset |
| emmc_clk | 82 | IOT11[A] | output | До 12 МГц |
| emmc_dat1 | 83 | IOT10[B] | bidir | 4-bit mode (PULL_MODE=UP) |
| emmc_dat2 | 84 | IOT10[A] | bidir | 4-bit mode (PULL_MODE=UP) |
| emmc_dat3 | 85 | IOT9[B] | bidir | 4-bit mode (PULL_MODE=UP) |

Все пины выведены на гребёнку платы (пины 79-85). Для подключения eMMC необходим
внешний источник питания 1.8V (VCC/VCCQ). На плате Tang Nano 9K нет доступного пина 1.8V.

**Не используются:** пины 87 (MODE1) и 88 (MODE0) — не выведены на гребёнку.

## Распиновка UART (Bank 0, 3.3V) — FT2232HL Channel B

| Сигнал | FPGA Pin | IO Site | Направление | FT2232HL Pin |
|---|---|---|---|---|
| uart_tx | 25 | IOB8A | output | BDBUS1 (RXD) |
| uart_rx | 26 | IOB8B | input | BDBUS0 (TXD) |

Bank 0 (3.3V) — совместим с FT2232HL (VCCIO=3.3V). BL702 UART (пины 17/18) hardwired через R45/R46 — не используется.

## CJMCU-2232HL (настоящий FT2232HL)

Подключение к Tang Nano 9K: Channel A → JTAG (прошивка), Channel B → UART (связь).

| CJMCU-2232HL | Сигнал | Tang Nano 9K |
|---|---|---|
| AD0 | TCK | FPGA pin 6 (через R36 на BL702 trace) |
| AD1 | TDI | FPGA pin 7 (через R38 на BL702 trace) |
| AD2 | TDO | FPGA pin 8 (через R37 на BL702 trace) |
| AD3 | TMS | FPGA pin 5 (через R39 на BL702 trace) |
| BD0 | TXD → RX | FPGA pin 26 (uart_rx) |
| BD1 | RXD ← TX | FPGA pin 25 (uart_tx) |
| GND | GND | GND |

Маркировка на плате: `AD`=Channel A Data, `BD`=Channel B Data, `AC`/`BC`=Control (не используются).

Проверенные UART baud rates через CJMCU-2232HL:
- **3 Mbaud** (preset 0): OK
- **6 Mbaud** (preset 1): OK
- **9 Mbaud** (preset 2): **не работает, отклоняется FPGA** (FTDI divisor дробный, ~11% ошибка)
- **12 Mbaud** (preset 3): OK

Настоящий FT2232HL поддерживает `--baud 3000000` напрямую (divisor 0 работает), в отличие от FT2232C-клона.

## FactoryAIOT Pro (FT2232C-клон)

Адаптер FactoryAIOT Pro (USB `0403:6010`, bcdDevice 5.00) — клон FT2232C.
Ядро Linux (`ftdi_sio`) вычисляет FTDI-делители через `ftdi_232bm_baud_base_to_divisor()`:

| Запрос baud | Делитель → чип | Реальный FT2232C | Клон FactoryAIOT |
|---|---|---|---|
| 3 000 000 | divisor = 0 | 3 Мбод | **не работает** |
| 2 000 000 | divisor = 1 | 2 Мбод (×1.5) | **3 Мбод** (3M/1) |

Клон не реализует спец-обработку divisor 0 и внутренний ×1.5 множитель для divisor 1.
Поэтому для связи с FPGA (UART 3 Мбод) нужно указывать `--baud 2000000`.

### Flash-прошивка через FT2232C-клон

`programmer_cli --operation_index 6` (embFlash) выдаёт **"Verify Failed at 0"** — это ложная
ошибка FT2232C-клона. Прошивка записывается корректно (проверено по LED-индикации и UART ping).

## FT245 Async FIFO (CJMCU-2232HL Channel B)

Альтернативный транспорт: параллельный 8-bit FIFO вместо UART. Требует отдельную прошивку
(`card_reader_fifo.fs`) и настройку EEPROM на CJMCU-2232HL (Channel B = "245 FIFO" через FT_PROG).

### Распиновка FT245 FIFO (12 пинов)

| Сигнал | FPGA Pin | Bank | CJMCU-2232HL | Направление |
|---|---|---|---|---|
| fifo_d0 | 26 | 2 (3.3V) | BD0 | bidir |
| fifo_d1 | 25 | 2 (3.3V) | BD1 | bidir |
| fifo_d2 | 27 | 2 (3.3V) | BD2 | bidir |
| fifo_d3 | 28 | 2 (3.3V) | BD3 | bidir |
| fifo_d4 | 29 | 2 (3.3V) | BD4 | bidir |
| fifo_d5 | 30 | 2 (3.3V) | BD5 | bidir |
| fifo_d6 | 33 | 2 (3.3V) | BD6 | bidir |
| fifo_d7 | 34 | 2 (3.3V) | BD7 | bidir |
| fifo_rxf_n | 35 | 1 (3.3V) | BRXF# | input |
| fifo_txe_n | 40 | 1 (3.3V) | BTXE# | input |
| fifo_rd_n | 41 | 1 (3.3V) | BRD# | output |
| fifo_wr_n | 42 | 1 (3.3V) | BWR# | output |

### EEPROM Setup (одноразово)

CJMCU-2232HL (SN=`FTBEXHE8`) содержит 93C46 EEPROM. Через FT_PROG (Windows):
1. Channel A: оставить "MPSSE" (JTAG)
2. Channel B: установить "245 FIFO"
3. Программировать EEPROM

### Использование

```bash
# Прошивка FIFO-варианта
sudo openFPGALoader -f -b tangnano9k impl/pnr/card_reader_fifo.fs

# Python: --fifo флаг переключает на FifoTransport (pyftdi)
sudo python3 tools/emmc_tool.py --fifo ping
sudo python3 tools/emmc_tool.py --fifo bus-width 4
sudo python3 tools/emmc_tool.py --fifo set-clock 2
sudo python3 tools/emmc_tool.py --fifo read 0 1000 /dev/null
sudo python3 tools/emmc_tool.py --fifo --multi write 0 data.bin
```

### Известные особенности

- **Два FT2232 на шине**: Sipeed (SN=`FactoryAIOT*`) + CJMCU. `fifo_transport.py` автоматически
  находит CJMCU по серийному номеру.
- **Warmup**: первый USB read после open() пустой — `FifoTransport.__init__()` отправляет
  warmup PING для инициализации USB pipeline.
- **Phantom read fix**: пакеты >512 байт разбиваются USB HS bulk на 2 трансфера.
  Между ними FIFO опустошается, RXF# уходит в high. Из-за 2-FF metastability sync
  FPGA видит stale "data available" → phantom read → CRC mismatch. Fix: 4 recovery clocks
  вместо 1 в read cycle (`Ft245Fifo.scala`).
