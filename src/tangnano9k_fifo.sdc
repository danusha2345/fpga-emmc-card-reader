// Tang Nano 9K Timing Constraints
// eMMC Card Reader Project — FT245 FIFO variant

// Input clock: 27 MHz oscillator
create_clock -name clk_27m -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]

// PLL output: 60 MHz system clock
create_clock -name sys_clk -period 16.667 -waveform {0 8.333} [get_nets {sys_clk}]

// No real clock domain crossing between clk_27m and sys_clk (PLL handles it)
set_false_path -from [get_clocks {clk_27m}] -to [get_clocks {sys_clk}]
set_false_path -from [get_clocks {sys_clk}] -to [get_clocks {clk_27m}]

// eMMC I/O: async (clk_en strobe, not true clock domain)
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

// FT245 FIFO I/O: async signals, no timing constraint
set_false_path -from [get_ports {fifo_d[*]}]
set_false_path -to [get_ports {fifo_d[*]}]
set_false_path -from [get_ports {fifo_rxf_n}]
set_false_path -from [get_ports {fifo_txe_n}]
set_false_path -to [get_ports {fifo_rd_n}]
set_false_path -to [get_ports {fifo_wr_n}]

// Buttons: async inputs
set_false_path -from [get_ports {btn_s1}]
set_false_path -from [get_ports {btn_s2}]

// LEDs: no timing requirement
set_false_path -to [get_ports {led[*]}]
