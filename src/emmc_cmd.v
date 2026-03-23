// eMMC CMD Line Protocol Handler
// Sends 48-bit commands and receives 48-bit or 136-bit responses
// Works on eMMC clock domain (directly driven by clk_en strobe from controller)
//
// CMD frame (host->card, 48 bits):
//   [47] start=0, [46] transmit=1, [45:40] CMD index,
//   [39:8] argument, [7:1] CRC-7, [0] end=1
//
// Response R1 (card->host, 48 bits):
//   [47] start=0, [46] transmit=0, [45:40] CMD index,
//   [39:8] card status, [7:1] CRC-7, [0] end=1
//
// Response R2 (card->host, 136 bits):
//   [135] start=0, [134] transmit=0, [133:128] 111111,
//   [127:1] CID or CSD, [0] end=1

module emmc_cmd (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clk_en,       // eMMC clock enable strobe (one per eMMC CLK edge)

    // Command interface
    input  wire         cmd_start,    // pulse to send command
    input  wire [5:0]   cmd_index,    // CMD0, CMD1, etc.
    input  wire [31:0]  cmd_argument, // 32-bit argument
    input  wire         resp_type_long, // 0=R1(48-bit), 1=R2(136-bit)
    input  wire         resp_expected,  // 0=no response (CMD0), 1=expect response
    output reg          cmd_done,     // pulse: command+response complete
    output reg          cmd_timeout,  // pulse: response timeout
    output reg          cmd_crc_err,  // pulse: CRC error in response
    output reg  [31:0]  resp_status,  // R1: card status bits
    output reg  [127:0] resp_data,    // R2: CID or CSD (128 bits)

    // Physical CMD line
    output reg          cmd_out,      // CMD output
    output reg          cmd_oe,       // CMD output enable
    input  wire         cmd_in,       // CMD input (directly from pin)

    // Debug
    output wire [2:0]   dbg_state     // FSM state for diagnostics
);

    localparam S_IDLE    = 3'd0;
    localparam S_SEND    = 3'd1;
    localparam S_WAIT    = 3'd2;
    localparam S_RECV    = 3'd3;
    localparam S_DONE    = 3'd4;

    assign dbg_state = state;

    reg [2:0]   state;
    reg [7:0]   bit_cnt;
    reg [47:0]  tx_shift;     // outgoing command
    reg [135:0] rx_shift;     // incoming response
    reg [15:0]  timeout_cnt;
    reg         cmd_timeout_flag; // pre-computed: set when timeout_cnt == 1023
    reg         resp_long;
    reg         resp_exp;
    reg [6:0]   crc_shift;    // latched CRC for serial output
    reg         send_is_data_phase; // pre-computed: bit_cnt < 40
    reg         send_latch_crc;     // pre-computed: bit_cnt == 39
    reg         send_is_done;       // pre-computed: bit_cnt >= 47

    // CRC-7 instance
    reg         crc_clear;
    reg         crc_en;
    reg         crc_bit;
    wire [6:0]  crc_out;

    emmc_crc7 u_crc7 (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (crc_clear),
        .enable  (crc_en),
        .bit_in  (crc_bit),
        .crc_out (crc_out)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            bit_cnt     <= 0;
            tx_shift    <= 0;
            rx_shift    <= 0;
            timeout_cnt <= 0;
            cmd_timeout_flag <= 1'b0;
            cmd_out     <= 1'b1;
            cmd_oe      <= 1'b0;
            cmd_done    <= 1'b0;
            cmd_timeout <= 1'b0;
            cmd_crc_err <= 1'b0;
            resp_status <= 0;
            resp_data   <= 0;
            resp_long   <= 0;
            resp_exp    <= 0;
            crc_clear   <= 1'b1;
            crc_en      <= 1'b0;
            crc_bit     <= 1'b0;
            crc_shift   <= 7'd0;
            send_is_data_phase <= 1'b0;
            send_latch_crc     <= 1'b0;
            send_is_done       <= 1'b0;
        end else begin
            cmd_done    <= 1'b0;
            cmd_timeout <= 1'b0;
            cmd_crc_err <= 1'b0;
            crc_clear   <= 1'b0;
            crc_en      <= 1'b0;

            case (state)
                S_IDLE: begin
                    cmd_oe  <= 1'b0;
                    cmd_out <= 1'b1;
                    // Guard: don't latch new command on same cycle as cmd_done.
                    // Controller FSM updates mc_cmd_argument/mc_cmd_index via NBA
                    // in response to cmd_done — those values arrive next cycle.
                    if (cmd_start && !cmd_done) begin
                        // Build 48-bit command frame (CRC will be computed during send)
                        tx_shift[47]    <= 1'b0;                // start bit
                        tx_shift[46]    <= 1'b1;                // transmit bit
                        tx_shift[45:40] <= cmd_index;
                        tx_shift[39:8]  <= cmd_argument;
                        tx_shift[7:1]   <= 7'd0;               // placeholder for CRC
                        tx_shift[0]     <= 1'b1;                // end bit
                        resp_long <= resp_type_long;
                        resp_exp  <= resp_expected;
                        bit_cnt   <= 0;
                        crc_clear <= 1'b1;
                        send_is_data_phase <= 1'b1;
                        send_latch_crc     <= 1'b0;
                        send_is_done       <= 1'b0;
                        state     <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (clk_en) begin
                        cmd_oe <= 1'b1;

                        if (send_is_data_phase) begin
                            // Send data bits [47:8] (start + transmit + index + argument = 40 bits)
                            cmd_out <= tx_shift[47];
                            tx_shift <= {tx_shift[46:0], 1'b0};

                            // Feed CRC for all 40 data bits
                            crc_en  <= 1'b1;
                            crc_bit <= tx_shift[47];
                        end else if (send_latch_crc) begin
                            // bit_cnt=40: CRC-7 ready, first CRC bit direct from crc_out
                            cmd_out   <= crc_out[6];
                            crc_shift <= {crc_out[5:0], 1'b0};
                        end else if (!send_is_done) begin
                            // bit_cnt=41..46: remaining 6 CRC bits via shift register
                            cmd_out   <= crc_shift[6];
                            crc_shift <= {crc_shift[5:0], 1'b0};
                        end else begin
                            // bit_cnt=47: end bit
                            cmd_out <= 1'b1;
                        end

                        bit_cnt <= bit_cnt + 1'b1;

                        // Update pre-computed flags for next clk_en
                        send_is_data_phase <= (bit_cnt < 8'd39);
                        send_latch_crc     <= (bit_cnt == 8'd39);
                        send_is_done       <= (bit_cnt >= 8'd46);

                        if (send_is_done) begin
                            // Command fully sent
                            cmd_oe <= 1'b0;
                            cmd_out <= 1'b1;
                            if (resp_exp) begin
                                bit_cnt     <= 0;
                                timeout_cnt <= 0;
                                cmd_timeout_flag <= 1'b0;
                                crc_clear   <= 1'b1;
                                state       <= S_WAIT;
                            end else begin
                                state <= S_DONE;
                            end
                        end
                    end
                end

                S_WAIT: begin
                    // Wait for response start bit (CMD goes low)
                    if (clk_en) begin
                        if (cmd_in == 1'b0) begin
                            // Start bit detected
                            rx_shift <= 0;
                            rx_shift[135] <= 1'b0; // start bit
                            bit_cnt <= 8'd1;
                            state   <= S_RECV;
                        end else begin
                            timeout_cnt <= timeout_cnt + 1'b1;
                            if (timeout_cnt == 16'd1023)
                                cmd_timeout_flag <= 1'b1;
                            if (cmd_timeout_flag) begin // NCR max = 64 clocks, generous timeout
                                cmd_timeout <= 1'b1;
                                cmd_done    <= 1'b1;
                                state <= S_IDLE;
                            end
                        end
                    end
                end

                S_RECV: begin
                    if (clk_en) begin
                        rx_shift <= {rx_shift[134:0], cmd_in};
                        bit_cnt <= bit_cnt + 1'b1;

                        // Feed CRC for response validation
                        if (!resp_long) begin
                            // R1: CRC covers bits [47:8] = 40 bits (bit_cnt 1-40)
                            if (bit_cnt >= 8'd1 && bit_cnt <= 8'd39) begin
                                crc_en  <= 1'b1;
                                crc_bit <= cmd_in;
                            end
                        end
                        // For R2 (136-bit): CRC is internal, skip check

                        if (!resp_long && bit_cnt == 8'd47) begin
                            // R1: 48-bit response complete (extracted in S_DONE)
                            state <= S_DONE;
                        end else if (resp_long && bit_cnt == 8'd135) begin
                            // R2: 136-bit response complete
                            state <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    if (!resp_long && resp_exp) begin
                        // Extract R1 fields: rx_shift now has bits [46:0] (47 bits shifted after start)
                        resp_status <= rx_shift[39:8];
                        // CRC check
                        if (crc_out != rx_shift[7:1])
                            cmd_crc_err <= 1'b1;
                    end else if (resp_long) begin
                        // R2: bits [127:0] are the CID/CSD data
                        resp_data <= rx_shift[127:0];
                    end
                    cmd_done <= 1'b1;
                    state    <= S_IDLE;
                end
            endcase
        end
    end

endmodule
