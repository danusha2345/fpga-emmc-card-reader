# Python CLI Reference (emmc_tool.py)

Полный справочник команд `tools/emmc_tool.py`.

Порт по умолчанию: `/dev/ttyACM0` (встроенный BL702) или `/dev/ttyUSB1` (внешний JTAG-адаптер).
Скорость: 3 Мбод. **Важно:** при использовании FactoryAIOT Pro (FT2232C-клон) указывать `--baud 2000000` —
клон не поддерживает FTDI divisor 0 (3 Мбод), но при divisor 1 (запрос 2 Мбод) реально генерирует 3 Мбод.

**FT2232C warm-up:** `emmc_tool.py` автоматически делает open/close на 3M baud перед подключением
для `ttyUSB*` портов. Без этого Channel B FT2232C-клона не активируется после загрузки драйвера.

```bash
# Проверка связи
python3 tools/emmc_tool.py ping

# Информация о карте (CID/CSD)
python3 tools/emmc_tool.py info

# Чтение секторов в файл
python3 tools/emmc_tool.py read <lba> <count> <outfile>
python3 tools/emmc_tool.py read --fast <lba> <count> <outfile>  # авто 12M+10MHz, error recovery

# Полный дамп eMMC
python3 tools/emmc_tool.py dump <outfile>
python3 tools/emmc_tool.py --fast dump --verify <outfile>    # дамп + readback verify

# Восстановление eMMC из файла
python3 tools/emmc_tool.py restore <infile>
python3 tools/emmc_tool.py restore <infile> --lba 1024       # продолжить с LBA 1024
python3 tools/emmc_tool.py restore <infile> --count 4636672  # записать до LBA 4636671
python3 tools/emmc_tool.py restore <infile> --lba 7440 --count 4636672  # resume: LBA 7440..4636671
python3 tools/emmc_tool.py restore <infile> --fast           # 12M baud (требует FT2232HL)
python3 tools/emmc_tool.py restore <infile> --fast --verify  # restore + readback verify

# Таблица разделов (MBR/GPT auto-detect)
python3 tools/emmc_tool.py partitions

# ext4 файловая система (чтение/запись /data)
python3 tools/emmc_tool.py ext4-info              # информация о FS
python3 tools/emmc_tool.py ext4-ls /              # листинг директории
python3 tools/emmc_tool.py ext4-cat /file         # чтение файла
python3 tools/emmc_tool.py ext4-write /file --data-hex AABB --confirm  # перезапись
python3 tools/emmc_tool.py ext4-create / newfile --confirm             # создание

# Erase sectors
python3 tools/emmc_tool.py erase <lba> <count>

# Secure erase (physical overwrite, CMD38 arg=0x80000000)
python3 tools/emmc_tool.py secure-erase <lba> <count>

# Write ExtCSD byte (generic CMD6 SWITCH)
python3 tools/emmc_tool.py write-extcsd <index> <value>

# Enable cache & flush to flash
python3 tools/emmc_tool.py cache-flush

# Configure boot partition
python3 tools/emmc_tool.py boot-config <partition>    # none/boot0/boot1/user

# Card Status Register (CMD13 SEND_STATUS)
python3 tools/emmc_tool.py card-status

# Re-initialize eMMC card (error recovery)
python3 tools/emmc_tool.py reinit

# Set eMMC clock speed (runtime, no re-synthesis)
python3 tools/emmc_tool.py set-clock 4     # 4 MHz
python3 tools/emmc_tool.py set-clock 9     # 9 MHz
python3 tools/emmc_tool.py set-clock 2     # back to 2 MHz (default)

# Set UART baud rate (runtime, no re-synthesis)
python3 tools/emmc_tool.py set-baud 1     # 6 Mbaud
python3 tools/emmc_tool.py set-baud 3     # 12 Mbaud (requires FT2232HL)
python3 tools/emmc_tool.py set-baud 0     # back to 3 Mbaud (default)

# RPMB (Replay Protected Memory Block)
python3 tools/emmc_tool.py rpmb-counter                    # Read RPMB write counter + MAC verify
python3 tools/emmc_tool.py rpmb-read 0                     # Authenticated read at address 0
python3 tools/emmc_tool.py rpmb-read 0 --hex               # hex dump
python3 tools/emmc_tool.py rpmb-dump rpmb.bin              # Dump entire RPMB to file
# RPMB requires HMAC-SHA256 key.
# FPGA handles CMD23 SET_BLOCK_COUNT internally (back-to-back with CMD25/CMD18).

# Multi-sector reads (CMD18, faster for bulk)
python3 tools/emmc_tool.py --multi read 0 64 sectors.bin
# read --fast auto-enables CMD18 + switches to 12M UART / 10 MHz eMMC, restores on exit
# On read errors: writes zeros for failed chunks and continues (error recovery)
python3 tools/emmc_tool.py --multi --retry 3 read --fast 0 5873664 dump.img

# Fast dump (auto-switches to 12M UART + 10 MHz eMMC, dumps, switches back)
# dump/verify/restore auto-enable CMD18/CMD25 (multi-sector) for speed; --multi not required
# Capacity auto-detected from ExtCSD SEC_COUNT if CSD is unreliable (breadboard noise)
python3 tools/emmc_tool.py --fast dump output.img
python3 tools/emmc_tool.py --fast dump --verify output.img   # dump + readback verify

# Write sectors from file (with optional --fast and --verify)
python3 tools/emmc_tool.py write <lba> <infile>
python3 tools/emmc_tool.py write --fast --verify <lba> <infile>  # 12M+10MHz + readback verify

# Verify eMMC содержимого vs файл
python3 tools/emmc_tool.py verify 0 dump.img                # полная верификация
python3 tools/emmc_tool.py verify 0 dump.img --count 4636672  # верификация до LBA 4636671
python3 tools/emmc_tool.py verify --fast 0 dump.img           # быстрая верификация (12M + 10 MHz)

# Readback verify (--verify flag)
# Доступен для write, dump, restore. Выполняет полный readback и побайтовое сравнение.
# Retry 3 раза на каждый chunk — отличает UART noise от flash mismatch.

# Raw eMMC command (arbitrary CMD index + argument)
python3 tools/emmc_tool.py raw-cmd 13 0x00010000                # CMD13 SEND_STATUS
python3 tools/emmc_tool.py raw-cmd 62 0x96C9D71C                # CMD62 vendor debug
python3 tools/emmc_tool.py raw-cmd 0 0xF0F0F0F0 --no-resp       # CMD0 PRE_IDLE
python3 tools/emmc_tool.py raw-cmd 5 0x00010001 --busy           # CMD5 SLEEP_AWAKE
python3 tools/emmc_tool.py raw-cmd 9 0x00000000 --long           # CMD9 R2 (CSD)

# Automated eMMC recovery (try CMD5/CMD62/CMD0 sequences)
python3 tools/emmc_tool.py recover --target-mid 0x9B

# Retry on errors (for read/write/erase)
python3 tools/emmc_tool.py --retry 3 read <lba> <count> <outfile>
```

## Утилиты сравнения и ремонта дампов

```bash
# Сравнение двух eMMC дампов (GPT, UNR0, IM*H, ext4, SQFS, boot partitions)
python3 tools/compare_emmc.py <dump_a> <dump_b> [опции]
python3 tools/compare_emmc.py dump_a.img dump_b.img \
  --boot0-a dumps/boot0_a.bin --boot0-b dumps/boot0_b.bin \
  --boot1-b dumps/boot1_b.bin --skip-ext4

# Глубокое сравнение с файловым diff (монтирует ext4 через loop, требует sudo)
python3 tools/compare_emmc.py --deep dump_a.img dump_b.img

# Глубокий анализ одного дампа (GPT, форматы, ext4 mount, ELF inventory, извлечение конфигов)
python3 tools/analyze_dump.py <dump> [--boot0 FILE] [--boot1 FILE] [--extract-dir DIR] [-o FILE]
python3 tools/analyze_dump.py dump.img \
  --boot0 dumps/boot0.bin \
  --boot1 dumps/boot1.bin \
  --extract-dir extracted/ -o docs/analysis.md
python3 tools/analyze_dump.py dump.img --no-mount -o report.md    # без sudo, только superblock

# Ремонт дампа: перечитка нулевых чанков (32 KB) на пониженной скорости
python3 tools/repair_dump.py <dump> --port /dev/ttyUSB1 [опции]
python3 tools/repair_dump.py dump.img --port /dev/ttyUSB1 --clock 2          # 6 MHz eMMC (default)
python3 tools/repair_dump.py dump.img --port /dev/ttyUSB1 --clock 0          # 2 MHz (самый надёжный)
python3 tools/repair_dump.py dump.img --port /dev/ttyUSB1 --dry-run          # только показать статистику
```

| Опция compare_emmc | Описание |
|---|---|
| `--deep` | Глубокое сравнение: mount ext4, файловый diff, JSON key-by-key diff |
| `--skip-ext4` | Пропустить сравнение ext4 superblock |
| `--skip-firmware` | Пропустить сравнение IM\*H firmware |
| `--boot0-a/b` | Boot0 файлы для каждого дампа |
| `--boot1-a/b` | Boot1 файлы |
| `--extcsd-a/b` | ExtCSD бинарные файлы (512 байт) |

| Опция analyze_dump | Описание |
|---|---|
| `--boot0 FILE` | Boot0 partition файл |
| `--boot1 FILE` | Boot1 partition файл |
| `--extract-dir DIR` | Каталог для извлечения конфигов, скриптов, TEE apps |
| `-o FILE` | Выходной markdown отчёт |
| `--no-mount` | Только superblock анализ (не требует sudo) |

| Опция repair_dump | Описание |
|---|---|
| `--clock N` | eMMC clock preset (0=2MHz, 1=3.75, 2=6MHz default, 3=10) |
| `--baud N` | UART baud preset (0=3M default, 1=6M, 3=12M) |
| `--base-lba N` | Если дамп начинается не с LBA 0 |
| `--dry-run` | Только подсчёт нулевых чанков, без чтения |
