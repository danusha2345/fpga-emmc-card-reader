# Programmer GUI (emmc-programmer/)

Универсальный Flash Programmer GUI на Rust + egui с trait-based HAL.

```bash
cd emmc-programmer && cargo run --release -p programmer-gui
```

## Архитектура

Workspace из 4 крейтов:
- **programmer-hal** — трейты `Programmer`, `ProgrammerExt`, `ChipInfo`, `ProgressReporter`
- **programmer-fpga** — `FpgaUartProgrammer` — FPGA UART/FIFO backend (Tang Nano 9K)
- **programmer-engine** — `AppState`, `Command`, `WorkerMessage`, `OperationProgress`
- **programmer-gui** — egui UI, panels, theme, widgets

Транспорт: UART (serial port) или FT245 FIFO (USB, feature `fifo` — default). FIFO даёт 3x ускорение чтения. При старте сканирует USB на CJMCU-2232HL (SN=`FTBEXHE8`). Переключение UART/FIFO — radio button в Connection panel.

Worker pattern: `dispatch_command(Command)` → destructive commands показывают confirm dialog → `execute_command()` запускает `std::thread::spawn` с `Arc<Mutex<FpgaUartProgrammer>>` → результат через `crossbeam_channel` → `process_messages()` обновляет state.

## Вкладки

| # | Вкладка | Hotkey | Функции |
|---|---------|--------|---------|
| 1 | ChipInfo | Ctrl+1 | Identify (CID + chip DB: серия, NAND, eMMC ver), Read ExtCSD (Device Info, Speed Modes, Boot Config, Health), Reinit |
| 2 | Operations | Ctrl+2 | Read/Write секторов, Erase/Secure Erase, Verify/Blank Check, Full Dump/Restore, Partition switch, Speed Control, Bus Width (1-bit/4-bit), Card Status (CMD13 с расшифровкой 9 полей), Raw CMD, ExtCSD Write |
| 3 | Partitions | Ctrl+3 | GPT/MBR parsing, таблица с кнопкой "ext4" для Linux/Data партиций → автопереход в Filesystem |
| 4 | Hex Editor | Ctrl+4 | Hex view/edit, undo/redo (Ctrl+Z/Y), Write Back to eMMC |
| 5 | Filesystem | Ctrl+5 | ext4 browse: Load FS, Navigate, Read/Save files, Search, Overwrite, Create |
| 6 | Image Manager | Ctrl+6 | Load/compare dump images, diff view |

## Chip Database (ChipInfo tab)

Встроенная база `chip_db.json` (30 производителей, 40+ продуктов). При Identify:
- **Manufacturer**: имя + страна (по JEDEC MID)
- **Product**: серия (iNAND 7250, V-NAND...), тип NAND (3D TLC, MLC, Xtacking 2.0), версия eMMC, примечания
- Поиск: exact match → prefix match по MID + product name из CID

## ExtCSD Health Viewer (ChipInfo tab)

При `Read ExtCSD` парсит 512 байт через `emmc_core::card_info::ExtCsdInfo`:

- **Device Info**: Capacity, FW Version, Boot Partition Size, RPMB Size
- **Speed Modes**: HS26/HS52/DDR — цветные бейджи (зелёный = supported, серый = нет)
- **Boot Config**: Boot ACK, Boot Partition (0=not enabled, 1=Boot0, 2=Boot1), Partition Access
- **Health**:
  - Life Time A/B: `0x01..0x0B` → "0-10%..Exceeded" с цветовым кодом (зелёный <50%, жёлтый 50-80%, красный >80%) + прогресс-бар "N% remaining"
  - Pre-EOL: Normal (зелёный) / Warning (жёлтый) / Urgent (красный)

## Card Status (Operations tab)

CMD13 с расшифровкой 32-bit response: CURRENT_STATE (Idle/Ready/Transfer/...), READY_FOR_DATA, SWITCH_ERROR, ERASE_RESET, WP_ERASE_SKIP, ERROR, CC_ERROR, ADDRESS_ERROR.

## Raw CMD & ExtCSD Write (Operations tab)

- **Raw CMD**: CMD index + Arg (hex) + чекбоксы Response/Busy/Data → SendRawCmd
- **ExtCSD Write**: Index (dec) + Value (hex) → CMD6 SWITCH

## Partition → ext4 Link (Partitions tab)

Кнопка "ext4" рядом с каждой Linux/Data/Basic Data партицией. Клик → заполняет LBA → переключает на Filesystem tab → автозагрузка ext4.

---

# Legacy GUI (emmc-gui/)

Кросс-платформенное GUI приложение на Rust + egui, полный паритет с Python CLI.

```bash
cd emmc-gui && cargo run --release
```

## Архитектура

Workspace из 3 крейтов:
- **emmc-core** — протокол eMMC, ext4, Transport trait (UART/FIFO) (без UI)
- **emmc-app** — состояние приложения, worker-операции (crossbeam-channel)
- **emmc-gui** — egui UI панели, theme module, keyboard shortcuts

Транспорт: `Transport` trait в emmc-core абстрагирует UART (`SerialTransport`) и FIFO (`FifoTransport`, feature `fifo` — default). `EmmcConnection::connect("fifo://", ...)` авто-выбирает FIFO. В FIFO режиме baud switch → no-op, keepalive отключен.

Worker pattern: UI отправляет `WorkerMessage` в фоновый поток, поток выполняет I/O через `EmmcConnection`, отправляет результат обратно. Confirm dialog использует `pending_action` в `AppState` — действие диспатчится в `app.rs::dispatch_pending_action()` где доступен `worker_tx`.

Speed Profile: `connect()` автоматически переключает eMMC CLK (set_clk_speed) и UART baud (set_baud + reconnect) в единой последовательности. Keepalive thread шлёт PING каждые ~5с для предотвращения сброса FPGA baud watchdog (~18с). `port_busy` флаг (AtomicBool) в `set_running()`/`set_completed()` предотвращает коллизию keepalive с рабочими операциями на serial port.

## Горячие клавиши

| Shortcut | Действие |
|----------|----------|
| Ctrl+1..5 | Переключение табов (eMMC Info, Sectors, Partitions, ext4, Hex Editor) |
| Ctrl+L | Показать/скрыть лог-панель |
| Escape | Отмена текущей операции |

## Theme (theme.rs)

Централизованные константы цветов и layout:
- `COLOR_SUCCESS` / `COLOR_ERROR` / `COLOR_WARNING` / `COLOR_ORANGE` — статусные цвета
- `COLOR_CONNECTED` / `COLOR_DISCONNECTED` — цвета состояния подключения
- `SECTION_SPACING` / `GROUP_SPACING` / `INLINE_SPACING` — сетка отступов
- `SCROLL_SMALL..SCROLL_HEX` — высоты scroll area

## Вкладки

| Вкладка | Функции |
|---------|---------|
| Connection | Transport (UART/FIFO), Speed Profile (Fast/Medium/Safe), Initial Baud, Connect/Disconnect, Partition switch, Status, Card Status, Re-Init, Speed Control (collapsible: eMMC CLK, UART Baud, Bus Width 1/4-bit), Raw eMMC CMD |
| Sectors | Read, Write, Erase, Verify vs File, Full Dump/Restore, Readback Verify checkboxes |
| Hex Editor | Hex view/edit, Write Back to eMMC |
| ext4 Browser | Load FS, Navigate, Read/Save files, Overwrite, Create |
| Log | Timestamped log с фильтрацией |

## ext4 файловая система (tools/ext4_utils.py)

Модуль для чтения/записи ext4 через sector-based eMMC I/O. Поддерживает:
- Superblock, group descriptors (32/64-byte), inode table
- Extent trees (leaf + index nodes)
- Directory traversal (linked-list entries)
- File read/overwrite/create с полной поддержкой **metadata_csum** (CRC-32C)
- Directory entry rename (same-length only)
- Bitmap-based allocation для inodes и blocks

## Readback Verify (Sectors tab)

Два чекбокса в панели Sectors:
- **Verify after write/restore** — после записи/восстановления выполняет полный readback и побайтовое сравнение с оригиналом. При несовпадении — FAIL с списком проблемных LBA.
- **Verify after dump** — после дампа перечитывает все секторы и сравнивает с дамп-файлом. При несовпадении — WARNING (не FAIL, т.к. breadboard noise может вызвать единичные расхождения).

Verify использует retry=3 на каждый chunk чтобы отличить UART noise от реальных ошибок flash.
