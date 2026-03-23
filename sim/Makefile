IVERILOG = iverilog
VVP = vvp
SRCDIR = ../src
IFLAGS = -I $(SRCDIR) -g2005-sv

# Source file lists per test
SRC_CRC8       = $(SRCDIR)/crc8.v
SRC_CRC7       = $(SRCDIR)/emmc_crc7.v
SRC_CRC16      = $(SRCDIR)/emmc_crc16.v
SRC_UART_TX    = $(SRCDIR)/uart_tx.v
SRC_UART_RX    = $(SRCDIR)/uart_rx.v
SRC_SECTOR_BUF = $(SRCDIR)/sector_buf.v
SRC_SECTOR_BUF_WR = $(SRCDIR)/sector_buf_wr.v
SRC_EMMC_CMD   = $(SRCDIR)/emmc_cmd.v $(SRCDIR)/emmc_crc7.v
SRC_UART_BRIDGE = $(SRCDIR)/uart_bridge.v $(SRCDIR)/uart_rx.v $(SRCDIR)/uart_tx.v $(SRCDIR)/crc8.v
SRC_EMMC_CTRL  = $(SRCDIR)/emmc_controller.v $(SRCDIR)/emmc_cmd.v $(SRCDIR)/emmc_dat.v \
                 $(SRCDIR)/emmc_init.v $(SRCDIR)/emmc_crc7.v $(SRCDIR)/emmc_crc16.v \
                 $(SRCDIR)/sector_buf.v $(SRCDIR)/sector_buf_wr.v
SRC_EMMC_DAT   = $(SRCDIR)/emmc_dat.v $(SRCDIR)/emmc_crc16.v
SRC_EMMC_INIT  = $(SRCDIR)/emmc_init.v
SRC_LED_STATUS = $(SRCDIR)/led_status.v
SRC_TOP_INTEGRATION = $(SRC_UART_BRIDGE) $(SRC_EMMC_CTRL)

TESTS = test_crc8 test_crc7 test_crc16 test_uart_tx test_uart_rx test_uart_loopback \
        test_sector_buf test_sector_buf_wr test_emmc_cmd test_emmc_cmd_crc_verify \
        test_uart_bridge test_emmc_controller test_emmc_dat test_emmc_init test_led_status \
        test_top_integration

.PHONY: all clean waves $(TESTS)

all: $(TESTS)
	@echo ""
	@echo "All 16 tests executed."

test_crc8: tb_crc8.v $(SRC_CRC8)
	@$(IVERILOG) $(IFLAGS) -o sim_crc8 tb_crc8.v $(SRC_CRC8) && $(VVP) sim_crc8

test_crc7: tb_crc7.v $(SRC_CRC7)
	@$(IVERILOG) $(IFLAGS) -o sim_crc7 tb_crc7.v $(SRC_CRC7) && $(VVP) sim_crc7

test_crc16: tb_crc16.v $(SRC_CRC16)
	@$(IVERILOG) $(IFLAGS) -o sim_crc16 tb_crc16.v $(SRC_CRC16) && $(VVP) sim_crc16

test_uart_tx: tb_uart_tx.v $(SRC_UART_TX)
	@$(IVERILOG) $(IFLAGS) -o sim_uart_tx tb_uart_tx.v $(SRC_UART_TX) && $(VVP) sim_uart_tx

test_uart_rx: tb_uart_rx.v $(SRC_UART_RX)
	@$(IVERILOG) $(IFLAGS) -o sim_uart_rx tb_uart_rx.v $(SRC_UART_RX) && $(VVP) sim_uart_rx

test_uart_loopback: tb_uart_loopback.v $(SRC_UART_TX) $(SRC_UART_RX)
	@$(IVERILOG) $(IFLAGS) -o sim_uart_loopback tb_uart_loopback.v $(SRC_UART_TX) $(SRC_UART_RX) && $(VVP) sim_uart_loopback

test_sector_buf: tb_sector_buf.v $(SRC_SECTOR_BUF)
	@$(IVERILOG) $(IFLAGS) -o sim_sector_buf tb_sector_buf.v $(SRC_SECTOR_BUF) && $(VVP) sim_sector_buf

test_sector_buf_wr: tb_sector_buf_wr.v $(SRC_SECTOR_BUF_WR)
	@$(IVERILOG) $(IFLAGS) -o sim_sector_buf_wr tb_sector_buf_wr.v $(SRC_SECTOR_BUF_WR) && $(VVP) sim_sector_buf_wr

test_emmc_cmd: tb_emmc_cmd.v $(SRC_EMMC_CMD)
	@$(IVERILOG) $(IFLAGS) -o sim_emmc_cmd tb_emmc_cmd.v $(SRC_EMMC_CMD) && $(VVP) sim_emmc_cmd

test_emmc_cmd_crc_verify: tb_emmc_cmd_crc_verify.v $(SRC_EMMC_CMD)
	@$(IVERILOG) $(IFLAGS) -o sim_emmc_cmd_crc_verify tb_emmc_cmd_crc_verify.v $(SRC_EMMC_CMD) && $(VVP) sim_emmc_cmd_crc_verify

test_uart_bridge: tb_uart_bridge.v $(SRC_UART_BRIDGE)
	@$(IVERILOG) $(IFLAGS) -o sim_uart_bridge tb_uart_bridge.v $(SRC_UART_BRIDGE) && $(VVP) sim_uart_bridge

test_emmc_controller: tb_emmc_controller.v $(SRC_EMMC_CTRL)
	@$(IVERILOG) $(IFLAGS) -o sim_emmc_controller tb_emmc_controller.v $(SRC_EMMC_CTRL) && $(VVP) sim_emmc_controller

test_emmc_dat: tb_emmc_dat.v $(SRC_EMMC_DAT)
	@$(IVERILOG) $(IFLAGS) -o sim_emmc_dat tb_emmc_dat.v $(SRC_EMMC_DAT) && $(VVP) sim_emmc_dat

test_emmc_init: tb_emmc_init.v $(SRC_EMMC_INIT)
	@$(IVERILOG) $(IFLAGS) -o sim_emmc_init tb_emmc_init.v $(SRC_EMMC_INIT) && $(VVP) sim_emmc_init

test_led_status: tb_led_status.v $(SRC_LED_STATUS)
	@$(IVERILOG) $(IFLAGS) -o sim_led_status tb_led_status.v $(SRC_LED_STATUS) && $(VVP) sim_led_status

test_top_integration: tb_top_integration.v $(SRC_TOP_INTEGRATION)
	@$(IVERILOG) $(IFLAGS) -o sim_top_integration tb_top_integration.v $(SRC_TOP_INTEGRATION) && $(VVP) sim_top_integration

# Generate VCD waveforms for debugging
waves: IFLAGS += -DVCD_DUMP
waves: all

clean:
	rm -f sim_* *.vcd
