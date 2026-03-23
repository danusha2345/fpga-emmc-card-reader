// eMMC DAT0 Read/Write Handler (1-bit SDR mode)
//
// Read data format on DAT0:
//   [Start bit (0)] [Data: 4096 clocks = 512 bytes, MSB first]
//   [CRC-16: 16 clocks] [End bit (1)]
//
// Write data format on DAT0:
//   Same as read but driven by host
//   Card responds with CRC status on DAT0: start(0) + 3 bits (010=ok, 101=err) + end(1)
//   Then busy (DAT0 low) until write complete

module emmc_dat (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clk_en,          // eMMC clock strobe

    // Read control
    input  wire        rd_start,        // begin reading data block
    output reg         rd_done,         // data block received
    output reg         rd_crc_err,      // CRC mismatch

    // Write control
    input  wire        wr_start,        // begin writing data block
    output reg         wr_done,         // write complete (card not busy)
    output reg         wr_crc_err,      // card reported CRC error

    // Buffer interface - read path (write to buffer)
    output reg  [7:0]  buf_wr_data,
    output reg  [8:0]  buf_wr_addr,     // 0-511
    output reg         buf_wr_en,

    // Buffer interface - write path (read from buffer)
    output reg  [8:0]  buf_rd_addr,
    input  wire [7:0]  buf_rd_data,

    // Physical DAT0 line (active accent: just 1 bit now)
    output reg         dat_out,
    output reg         dat_oe,
    input  wire        dat_in,

    // Debug
    output wire [3:0]  dbg_state      // FSM state for diagnostics
);

    // FSM states
    localparam S_IDLE         = 4'd0;
    localparam S_RD_WAIT_START= 4'd1;
    localparam S_RD_DATA      = 4'd2;
    localparam S_RD_CRC       = 4'd3;
    localparam S_RD_END       = 4'd4;
    localparam S_WR_PREFETCH  = 4'd5;  // wait 1 cycle for BRAM read
    localparam S_WR_START     = 4'd6;
    localparam S_WR_DATA      = 4'd7;
    localparam S_WR_CRC       = 4'd8;
    localparam S_WR_END       = 4'd9;
    localparam S_WR_CRC_STAT  = 4'd10;
    localparam S_WR_BUSY      = 4'd11;
    localparam S_WR_CRC_WAIT  = 4'd12;
    localparam S_WR_PREFETCH2 = 4'd13;

    assign dbg_state = state;

    reg [3:0]  state;
    reg [12:0] bit_cnt;      // max 4096 data bits + CRC
    reg [15:0] timeout_cnt;
    reg        timeout_flag;  // pre-computed: set when timeout_cnt reaches limit
    reg [7:0]  byte_acc;     // byte accumulator (8 bits)
    reg [2:0]  bit_in_byte;  // 0-7 bit position within byte
    reg        byte_complete; // pre-computed: bit_in_byte == 7

    // Pre-fetched byte from BRAM for write path (shift register: MSB always has current bit)
    reg [7:0]  wr_byte_reg;
    reg [2:0]  wr_bit_idx;   // counts bits remaining (used for == 0 check only)

    // CRC-16 instance for read (single DAT0 line)
    reg        crc_clear;
    reg        crc_en;
    wire [15:0] crc_out;
    reg [15:0]  crc_recv;

    emmc_crc16 u_crc16 (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (crc_clear),
        .enable  (crc_en),
        .bit_in  (dat_in),
        .crc_out (crc_out)
    );

    // Write CRC instance (separate for TX data)
    reg        wr_crc_clear;
    reg        wr_crc_en;
    reg        wr_crc_bit;
    wire [15:0] wr_crc_out;

    emmc_crc16 u_wr_crc16 (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (wr_crc_clear),
        .enable  (wr_crc_en),
        .bit_in  (wr_crc_bit),
        .crc_out (wr_crc_out)
    );

    // Pre-registered CRC output for write (shift register)
    reg [15:0] wr_crc_shift;

    // CRC status receive
    reg [2:0] crc_status_reg;
    reg [2:0] crc_status_cnt;
    // Busy guard: crc_status_cnt == 4 on entry to S_WR_BUSY,
    // count to 7 (3 guard ticks) before checking dat_in (Nwr gap)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            bit_cnt     <= 0;
            timeout_cnt <= 0;
            timeout_flag<= 1'b0;
            byte_acc    <= 0;
            bit_in_byte <= 0;
            byte_complete <= 1'b0;
            wr_byte_reg <= 0;
            wr_bit_idx  <= 0;
            rd_done     <= 1'b0;
            rd_crc_err  <= 1'b0;
            wr_done     <= 1'b0;
            wr_crc_err  <= 1'b0;
            buf_wr_data <= 0;
            buf_wr_addr <= 0;
            buf_wr_en   <= 1'b0;
            buf_rd_addr <= 0;
            dat_out     <= 1'b1;
            dat_oe      <= 1'b0;
            crc_clear   <= 1'b1;
            crc_en      <= 1'b0;
            crc_recv    <= 0;
            wr_crc_clear<= 1'b1;
            wr_crc_en   <= 1'b0;
            wr_crc_bit  <= 1'b1;
            wr_crc_shift<= 0;
            crc_status_reg <= 0;
            crc_status_cnt <= 0;
        end else begin
            rd_done    <= 1'b0;
            rd_crc_err <= 1'b0;
            wr_done    <= 1'b0;
            wr_crc_err <= 1'b0;
            buf_wr_en  <= 1'b0;
            crc_clear  <= 1'b0;
            crc_en     <= 1'b0;
            wr_crc_clear <= 1'b0;
            wr_crc_en    <= 1'b0;

            case (state)
                S_IDLE: begin
                    dat_oe  <= 1'b0;
                    dat_out <= 1'b1;
                    if (rd_start) begin
                        crc_clear    <= 1'b1;
                        timeout_cnt  <= 0;
                        timeout_flag <= 1'b0;
                        state        <= S_RD_WAIT_START;
                    end else if (wr_start) begin
                        wr_crc_clear <= 1'b1;
                        buf_rd_addr  <= 0;
                        bit_cnt      <= 0;
                        state        <= S_WR_PREFETCH;
                    end
                end

                // =========================================================
                // READ PATH (1-bit: 4096 clocks for 512 bytes)
                // =========================================================
                S_RD_WAIT_START: begin
                    if (clk_en) begin
                        if (dat_in == 1'b0) begin
                            bit_cnt     <= 0;
                            bit_in_byte <= 0;
                            byte_complete <= 1'b0;
                            buf_wr_addr <= 9'h1FF;
                            state       <= S_RD_DATA;
                        end else begin
                            timeout_cnt <= timeout_cnt + 1'b1;
                            if (timeout_cnt == 16'hFFFE)
                                timeout_flag <= 1'b1;
                            if (timeout_flag) begin
                                rd_crc_err <= 1'b1;
                                rd_done    <= 1'b1;
                                state      <= S_IDLE;
                            end
                        end
                    end
                end

                S_RD_DATA: begin
                    if (clk_en) begin
                        crc_en <= 1'b1;

                        // Shift incoming bit into byte accumulator (MSB first)
                        byte_acc <= {byte_acc[6:0], dat_in};
                        bit_in_byte <= bit_in_byte + 1'b1;
                        byte_complete <= (bit_in_byte == 3'd6);

                        // Always update write data (overwritten each bit, valid on byte_complete)
                        buf_wr_data <= {byte_acc[6:0], dat_in};
                        // buf_wr_en and buf_wr_addr: only on byte boundary
                        buf_wr_en   <= byte_complete;
                        if (byte_complete)
                            buf_wr_addr <= buf_wr_addr + 1'b1;

                        bit_cnt <= bit_cnt + 1'b1;
                        if (bit_cnt == 13'd4095) begin
                            bit_cnt  <= 0;
                            crc_recv <= 0;
                            state    <= S_RD_CRC;
                        end
                    end
                end

                S_RD_CRC: begin
                    if (clk_en) begin
                        crc_recv <= {crc_recv[14:0], dat_in};
                        bit_cnt  <= bit_cnt + 1'b1;
                        if (bit_cnt == 13'd15)
                            state <= S_RD_END;
                    end
                end

                S_RD_END: begin
                    if (clk_en) begin
                        if (crc_recv != crc_out)
                            rd_crc_err <= 1'b1;
                        rd_done <= 1'b1;
                        state   <= S_IDLE;
                    end
                end

                // =========================================================
                // WRITE PATH (1-bit: 4096 clocks, pipelined BRAM prefetch)
                // =========================================================
                S_WR_PREFETCH: begin
                    // Cycle 1: BRAM address 0 applied (set in S_IDLE), wait for data
                    state <= S_WR_PREFETCH2;
                end

                S_WR_PREFETCH2: begin
                    // Cycle 2: BRAM output now valid for addr 0
                    wr_byte_reg <= buf_rd_data;
                    buf_rd_addr <= 1; // prefetch next byte
                    state       <= S_WR_START;
                end

                S_WR_START: begin
                    if (clk_en) begin
                        // wr_byte_reg already contains data[0], do NOT overwrite
                        wr_bit_idx  <= 3'd7; // start from MSB
                        // Send start bit (DAT0 low)
                        dat_oe  <= 1'b1;
                        dat_out <= 1'b0;
                        bit_cnt <= 0;
                        state   <= S_WR_DATA;
                    end
                end

                S_WR_DATA: begin
                    if (clk_en) begin
                        dat_oe <= 1'b1;
                        // Always output MSB — no MUX needed
                        dat_out    <= wr_byte_reg[7];
                        wr_crc_bit <= wr_byte_reg[7];
                        wr_crc_en  <= 1'b1;

                        if (wr_bit_idx == 3'd0) begin
                            // Last bit of current byte — load next from BRAM
                            wr_byte_reg <= buf_rd_data;
                            buf_rd_addr <= buf_rd_addr + 1'b1;
                            wr_bit_idx  <= 3'd7;
                        end else begin
                            // Shift left: next bit moves into MSB
                            wr_byte_reg <= {wr_byte_reg[6:0], 1'b0};
                            wr_bit_idx  <= wr_bit_idx - 1'b1;
                        end

                        bit_cnt <= bit_cnt + 1'b1;
                        if (bit_cnt == 13'd4095) begin
                            bit_cnt <= 0;
                            state   <= S_WR_CRC_WAIT;
                        end
                    end
                end

                S_WR_CRC_WAIT: begin
                    // Wait 2 sys_clk for CRC module to process last data bit:
                    // Cycle 1 (bit_cnt=0): wr_crc_en NBA applied, CRC module processes bit
                    // Cycle 2 (bit_cnt=1): crc_reg NBA applied, capture wr_crc_out
                    if (bit_cnt[0]) begin
                        wr_crc_shift <= wr_crc_out;
                        bit_cnt      <= 0;
                        state        <= S_WR_CRC;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end

                S_WR_CRC: begin
                    if (clk_en) begin
                        dat_oe  <= 1'b1;
                        // Shift out CRC MSB-first
                        dat_out      <= wr_crc_shift[15];
                        wr_crc_shift <= {wr_crc_shift[14:0], 1'b0};

                        bit_cnt <= bit_cnt + 1'b1;
                        if (bit_cnt == 13'd15)
                            state <= S_WR_END;
                    end
                end

                S_WR_END: begin
                    if (clk_en) begin
                        dat_out <= 1'b1; // end bit
                        dat_oe  <= 1'b0;
                        crc_status_cnt <= 0;
                        crc_status_reg <= 0;
                        timeout_cnt    <= 0;
                        timeout_flag   <= 1'b0;
                        state <= S_WR_CRC_STAT;
                    end
                end

                S_WR_CRC_STAT: begin
                    if (clk_en) begin
                        if (dat_in == 1'b0 && crc_status_cnt == 0) begin
                            crc_status_cnt <= 1;
                        end else if (crc_status_cnt >= 1 && crc_status_cnt <= 3) begin
                            crc_status_reg <= {crc_status_reg[1:0], dat_in};
                            crc_status_cnt <= crc_status_cnt + 1'b1;
                        end else if (crc_status_cnt > 3) begin
                            if (crc_status_reg == 3'b010) begin
                                state <= S_WR_BUSY;
                            end else begin
                                wr_crc_err <= 1'b1;
                                wr_done    <= 1'b1;
                                state      <= S_IDLE;
                            end
                        end else begin
                            // cnt == 0 && dat_in == 1: waiting for CRC status start bit
                            timeout_cnt <= timeout_cnt + 1'b1;
                            if (timeout_cnt == 16'hFFFE)
                                timeout_flag <= 1'b1;
                            if (timeout_flag) begin
                                wr_crc_err <= 1'b1;
                                wr_done    <= 1'b1;
                                state      <= S_IDLE;
                            end
                        end
                    end
                end

                S_WR_BUSY: begin
                    if (clk_en) begin
                        if (crc_status_cnt < 3'd7) begin
                            crc_status_cnt <= crc_status_cnt + 1'b1;
                        end else if (dat_in == 1'b1) begin
                            wr_done <= 1'b1;
                            state   <= S_IDLE;
                        end else begin
                            timeout_cnt <= timeout_cnt + 1'b1;
                            if (timeout_cnt == 16'hFFFE)
                                timeout_flag <= 1'b1;
                            if (timeout_flag) begin
                                wr_crc_err <= 1'b1;
                                wr_done    <= 1'b1;
                                state      <= S_IDLE;
                            end
                        end
                    end
                end
            endcase
        end
    end

endmodule
