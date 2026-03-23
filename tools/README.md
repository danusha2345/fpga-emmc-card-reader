# eMMC Tools

Утилиты для работы с eMMC через FPGA-ридер на Tang Nano 9K.

## Установка

```bash
pip install pyserial pyftdi
```

---

## emmc_tool.py — eMMC Card Reader

Работа с eMMC через FPGA-ридер на Tang Nano 9K (UART 3 Мбод / FT245 FIFO).

### Подключение

```bash
python tools/emmc_tool.py --port /dev/ttyUSB1 ping
```

### Команды

| Команда | Описание |
|---------|----------|
| `ping` | Проверка связи с FPGA |
| `info` | CID/CSD регистры (производитель, ёмкость) |
| `extcsd` | Extended CSD (512 байт, health, partitions) |
| `partitions` | Список разделов (MBR/GPT auto-detect) |
| `read LBA COUNT FILE` | Чтение секторов в файл |
| `write LBA FILE` | Запись секторов из файла |
| `dump FILE` | Дамп всей eMMC |
| `restore FILE` | Восстановление из файла |
| `verify LBA FILE` | Верификация (сравнение с файлом) |
| `erase LBA COUNT` | Стирание секторов |
| `secure-erase LBA COUNT` | Безопасное стирание |
| `set-clock PRESET` | Установить eMMC CLK (preset 0-6) |
| `set-baud PRESET` | Установить UART baud |
| `bus-width 1\|4` | Переключение 1-bit/4-bit DAT bus |
| `rpmb-counter` | RPMB write counter |
| `rpmb-read ADDR` | RPMB authenticated read |
| `rpmb-dump FILE` | Полный RPMB дамп |

### Примеры

```bash
# Информация об eMMC
python tools/emmc_tool.py info

# Полный дамп (12M baud + 10 MHz eMMC CLK)
python tools/emmc_tool.py --fast dump output.img

# Восстановление
python tools/emmc_tool.py --fast restore input.img

# 4-bit режим
python tools/emmc_tool.py bus-width 4

# Список разделов
python tools/emmc_tool.py partitions
```

### Опции

| Флаг | Описание | Default |
|------|----------|---------|
| `--port PORT` | Серийный порт | `/dev/ttyUSB1` |
| `--baud RATE` | Baud rate | `3000000` |
| `--fast` | Авто 12M baud + 10 MHz eMMC CLK | off |
| `--fifo` | FT245 FIFO transport | off |

---

## Дополнительные утилиты

| Скрипт | Описание |
|--------|----------|
| `repair_dump.py` | Перечитка нулевых чанков в дампе |
| `speed_test.py` | Тест скорости чтения/записи |
| `ext4_utils.py` | Утилиты для работы с ext4 |
| `fifo_transport.py` | FT245 FIFO transport (pyftdi) |
