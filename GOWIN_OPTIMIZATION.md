# Настройки Gowin EDA для оптимизации таймингов

## Текущее состояние

- **Fmax**: 108.150 МГц (constraint 108.003 МГц, запас +0.147 МГц)
- **Setup violations**: 0, worst slack 0.013 нс
- **build.tcl**: `place_option 2`, `route_option 2`, `retiming 1`, `replicate_resources 1`

## Результаты экспериментов

| Конфигурация | Fmax (МГц) | Worst slack (нс) | Violations |
|-------------|-----------|------------------|------------|
| `place_option 1`, `route_option 2` (baseline) | 108.150 | 0.013 | 0 |
| + `place_option 2`, `retiming 1`, `replicate_resources 1`, `timing_driven 1` | 108.150 | 0.013 | 0 |

### Критические пути (топ-5)

| # | Slack (нс) | From | To | Data delay (нс) | Logic levels |
|---|-----------|------|----|-----------------|-------------|
| 1 | 0.013 | `uart_bridge/rx_state_2_s5` | `uart_bridge/info_shift_250_s0/D` | 8.846 | 5 |
| 2 | 0.015 | `emmc/u_dat/bit_cnt_7_s1` | `emmc/u_dat/state_0_s1/CE` | 9.201 | 5 |
| 3 | 0.026 | `uart_bridge/u_uart_rx/data_out_3` | `uart_bridge/rx_payload_cnt_9_s2/D` | 8.833 | 5 |
| 4 | 0.067 | `emmc/u_cmd/resp_status_31_s1` | `emmc/u_init/wait_cnt_0_s0/CE` | 9.148 | 5 |
| 5 | 0.080 | `emmc/u_dat/state_3_s1` | `emmc/u_dat/state_1_s1/CE` | 9.136 | 5 |

### Выводы

- `place_option 2`, `retiming 1`, `replicate_resources 1` не дали прироста Fmax
- Критические пути ограничены **логической глубиной** (5 уровней LUT), а не качеством размещения/маршрутизации
- 108.15 МГц — потолок без изменений RTL
- Дальнейшее улучшение требует разбиения комбинационных путей (pipeline-регистры в `uart_bridge`, `emmc_dat`)

---

## 1. Опции синтеза (GowinSynthesis) — `set_option`

| Опция | Значения | По умолчанию | Описание |
|-------|----------|--------------|----------|
| `-looplimit` | целое число | 2000 | Макс. число итераций оптимизации синтезатора |
| `-maxfan` | целое число | 10000 | Глобальный макс. fanout (дублирует драйверы при превышении) |
| `-retiming` | `0\|1` | 0 | Ретайминг — перемещение регистров через комбинационную логику для балансировки задержек |
| `-resource_sharing` | `0\|1` | 1 | Переиспользование арифметических блоков между взаимоисключающими путями |
| `-pipe` | `0\|1` | 0 | Пайплайнинг (автоматическая вставка pipeline-регистров) |
| `-symbolic_fsm_compiler` | `0\|1` | 1 | Автоматическое распознавание и оптимизация FSM |
| `-default_enum_encoding` | `default\|onehot\|gray\|sequential` | default | Кодирование FSM по умолчанию |
| `-fix_gated_and_generated_clocks` | `0\|1` | 0 | Преобразование gated clocks в CE |
| `-rw_check_on_ram` | `0\|1` | 0 | Bypass-логика для конфликтов чтения/записи RAM |
| `-frequency` | МГц | — | Целевая частота для синтеза |
| `-verilog_std` | `v1995\|v2001\|sysv2017` | v2001 | Стандарт Verilog |
| `-resolve_multiple_driver` | `0\|1` | 0 | Разрешение множественных драйверов |
| `-num_critical_paths` | целое число | — | Число критических путей для отчёта |

## 2. Опции Place & Route — `set_option`

| Опция | Значения | По умолчанию | Описание |
|-------|----------|--------------|----------|
| `-place_option` | `0\|1\|2\|3\|4` | 0 | Алгоритм размещения (0=быстрый, 1=стандарт, 2=timing-optimized) |
| `-route_option` | `0\|1\|2` | 0 | Алгоритм маршрутизации (0=быстрый, 1=timing-opt, 2=макс. усилие) |
| `-timing_driven` | `0\|1` | 1 | Timing-driven P&R |
| `-correct_hold_violation` | `0\|1` | 1 | Автокоррекция hold violations |
| `-replicate_resources` | `0\|1` | 0 | Репликация ресурсов для снижения fanout |
| `-route_maxfan` | целое число | 23 | Макс. fanout при маршрутизации |
| `-clock_route_order` | `0\|1` | 0 | Приоритет маршрутизации тактовых сигналов |
| `-reg_in_iob` | `0\|1` | 1 | Размещение регистров в IOB (общее) |
| `-ireg_in_iob` | `0\|1` | 1 | Входные регистры в IOB |
| `-oreg_in_iob` | `0\|1` | 1 | Выходные регистры в IOB |
| `-ioreg_in_iob` | `0\|1` | 1 | Двунаправленные регистры в IOB |
| `-cst_warn_to_error` | `0\|1` | 1 | Предупреждения constraints как ошибки |
| `-inc` | значение | 0 | Инкрементальный P&R |

## 3. Опции генерации отчётов

| Опция | Значения | Описание |
|-------|----------|----------|
| `-gen_sdf` | `0\|1` | Генерация SDF файла для timing simulation |
| `-gen_text_timing_rpt` | `0\|1` | Текстовый timing report |
| `-gen_io_cst` | `0\|1` | Генерация constraint-файла портов |
| `-gen_verilog_sim_netlist` | `0\|1` | Post-PnR Verilog netlist |
| `-show_all_warn` | `0\|1` | Показать все предупреждения |

---

## 4. Синтезные атрибуты (прагмы в Verilog)

Из документации SUG550 — атрибуты GowinSynthesis:

| Атрибут | Синтаксис | Применение | Описание |
|---------|-----------|-----------|----------|
| `syn_keep` | `/* synthesis syn_keep=1 */` | wire/signal | Запрет оптимизации сети |
| `syn_preserve` | `/* synthesis syn_preserve=1 */` | reg | Запрет оптимизации регистра |
| `syn_maxfan` | `/* synthesis syn_maxfan=N */` | reg/wire/module | Макс. fanout (дублирует драйвер) |
| `syn_encoding` | `/* synthesis syn_encoding="onehot" */` | reg (FSM) | Кодирование FSM: `onehot`, `gray`, `sequential` |
| `syn_ramstyle` | `/* synthesis syn_ramstyle="block_ram" */` | reg/module | RAM: `registers`, `block_ram`, `distributed_ram` |
| `syn_romstyle` | `/* synthesis syn_romstyle="logic" */` | reg/module | ROM: `logic`, `block_rom`, `distributed_rom` |
| `syn_srlstyle` | `/* synthesis syn_srlstyle="registers" */` | reg/module | Shift reg: `registers`, `block_ram`, `distributed_ram` |
| `syn_dspstyle` | `/* synthesis syn_dspstyle="logic" */` | module/wire | Умножитель: `dsp`, `logic` |
| `syn_black_box` | `/* synthesis syn_black_box */` | module | Чёрный ящик |
| `syn_looplimit` | GSC: `GLOBAL syn_looplimit=N` | глобально | Макс. итераций синтеза |
| `syn_netlist_hierarchy` | `/* synthesis syn_netlist_hierarchy=0 */` | top module | 0=flat, 1=hierarchical netlist |
| `syn_radhardlevel` | `/* synthesis syn_radhardlevel=tmr */` | reg/module | TMR (Triple Modular Redundancy) |
| `syn_probe` | `/* synthesis syn_probe="name" */` | wire/reg | Probe-точка для отладки |
| `syn_dont_touch` | — | — | Запрет оптимизации |
| `parallel_case` | `/* synthesis parallel_case */` | case stmt | Параллельный MUX вместо priority encoder |
| `full_case` | `/* synthesis full_case */` | case stmt | Все значения покрыты, default latch не нужен |
| `translate_off/on` | `/* synthesis translate_off */` | код | Исключение блока из синтеза |

### GSC файл (GowinSynthesis Constraint)

```
INS "instance" attr=value;    // на экземпляр
NET "net_name" attr=value;    // на сеть
PORT "port" attr=value;       // на порт
GLOBAL attr=value;            // глобально
```

---

## 5. Рекомендуемый порядок экспериментов

1. ~~**`place_option 2`** — timing-optimized placement~~ — проверено, без эффекта
2. ~~**`retiming 1`** — автоматическая балансировка задержек~~ — проверено, без эффекта
3. ~~**`replicate_resources 1`** — снижение fanout через репликацию~~ — проверено, без эффекта
4. **`syn_maxfan`** на конкретных сигналах — точечное снижение fanout (не проверено)
5. **RTL-изменения** — pipeline-регистры в критических путях (единственный оставшийся вариант)

---

## 6. Ссылки

- [SUG550 — GowinSynthesis User Guide](https://cdn.gowinsemi.com.cn/SUG550E.pdf) — атрибуты синтеза
- [SUG100 — Gowin Software User Guide](https://cdn.gowinsemi.com.cn/SUG100E.pdf) — настройки проекта
- [SUG1220 — TCL Commands User Guide](https://www.gowinsemi.com/upload/database_doc/3262/document/68b8a001a6a92.pdf) — TCL-команды
- [SUG940 — Timing Constraints User Guide](https://cdn.gowinsemi.com.cn/SUG940E.pdf) — SDC constraints
- [Tips for Tang boards](https://nand2mario.github.io/posts/2024/tang_tips/) — практические советы
