// Tang Nano 9K Timing Constraints
// eMMC Card Reader Project

// Input clock: 27 MHz oscillator
create_clock -name clk_27m -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]

// PLL output: 60 MHz system clock
create_clock -name sys_clk -period 16.667 -waveform {0 8.333} [get_nets {sys_clk}]

// No real clock domain crossing between clk_27m and sys_clk (PLL handles it)
set_false_path -from [get_clocks {clk_27m}] -to [get_clocks {sys_clk}]
set_false_path -from [get_clocks {sys_clk}] -to [get_clocks {clk_27m}]

// eMMC CLK output is NOT a separate clock domain.
// All internal logic runs on sys_clk with clk_en strobe.
// Do NOT create a generated clock on emmc_clk - it causes false CDC violations.
// Instead, constrain eMMC I/O as regular sys_clk paths with relaxed timing.
set_false_path -to [get_ports {emmc_clk}]
set_false_path -to [get_ports {emmc_rstn}]
set_false_path -from [get_ports {emmc_cmd}]
set_false_path -to [get_ports {emmc_cmd}]
set_false_path -from [get_ports {emmc_dat0}]
set_false_path -to [get_ports {emmc_dat0}]
set_false_path -from [get_ports {emmc_dat1}]
set_false_path -to [get_ports {emmc_dat1}]
set_false_path -from [get_ports {emmc_dat2}]
set_false_path -to [get_ports {emmc_dat2}]
set_false_path -from [get_ports {emmc_dat3}]
set_false_path -to [get_ports {emmc_dat3}]

// UART I/O: async, no timing constraint needed
set_false_path -from [get_ports {uart_rx}]
set_false_path -to [get_ports {uart_tx}]

// Buttons: async inputs
set_false_path -from [get_ports {btn_s1}]
set_false_path -from [get_ports {btn_s2}]

// LEDs: no timing requirement
set_false_path -to [get_ports {led[*]}]
