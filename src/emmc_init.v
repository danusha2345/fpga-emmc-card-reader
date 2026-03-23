// eMMC Initialization Sequence FSM
// Implements the eMMC boot/init sequence per JEDEC eMMC 5.1 spec:
//   1. Power-up: RST_n low 1ms, RST_n high, wait 50ms
//   2. CMD0 (GO_IDLE_STATE) - reset card
//   3. CMD1 (SEND_OP_COND) - negotiate voltage, poll until ready
//   4. CMD2 (ALL_SEND_CID) - get CID (R2 response)
//   5. CMD3 (SET_RELATIVE_ADDR) - assign RCA
//   6. CMD9 (SEND_CSD) - get CSD (R2 response)
//   7. CMD7 (SELECT_CARD) - select card (transfer state) + 1ms busy wait
//   8. CMD16 (SET_BLOCKLEN) - only for byte-addressed cards (OCR[30]=0)
// Note: 1-bit DAT0 mode (default after init, no CMD6 SWITCH needed)
// Note: Sector-addressed cards (OCR[30]=1) skip CMD16 (fixed 512B blocks)

module emmc_init #(
    parameter CLK_FREQ = 60_000_000
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         init_start,    // pulse to begin init
    output reg          init_done,     // init complete
    output reg          init_error,    // init failed
    output reg  [3:0]   init_state_dbg, // debug: current state

    // CMD interface
    output reg          cmd_start,
    output reg  [5:0]   cmd_index,
    output reg  [31:0]  cmd_argument,
    output reg          resp_type_long,
    output reg          resp_expected,
    input  wire         cmd_done,
    input  wire         cmd_timeout,
    input  wire         cmd_crc_err,
    input  wire [31:0]  resp_status,
    input  wire [127:0] resp_data,

    // Outputs
    output reg  [127:0] cid_reg,
    output reg  [127:0] csd_reg,
    output reg  [15:0]  rca_reg,
    output reg          info_valid,

    // Clock speed control
    output reg          use_fast_clk,  // 0=400kHz (init), 1=25MHz (transfer)

    // RST_n pin
    output reg          emmc_rstn_out,

    // Debug
    output wire [7:0]   dbg_retry_cnt  // CMD1 retry count from last init
);

    // Timing constants (in sys_clk cycles)
    localparam TICKS_1MS  = CLK_FREQ / 1000;
    localparam TICKS_50MS = CLK_FREQ / 20;          // 50ms post-reset (JEDEC min 1ms, real cards need more)
    localparam TICKS_74CLK = 200;                    // 74 eMMC clocks at 400kHz ~ 185us, use 200 cycles
    localparam MAX_CMD1_RETRIES = 16'd1400;

    // Init FSM states
    localparam SI_IDLE          = 4'd0;
    localparam SI_RESET_LOW     = 4'd1;
    localparam SI_RESET_HIGH    = 4'd2;
    localparam SI_CMD0          = 4'd3;
    localparam SI_CMD1          = 4'd4;
    localparam SI_CMD1_WAIT     = 4'd5;
    localparam SI_CMD2          = 4'd6;
    localparam SI_CMD3          = 4'd7;
    localparam SI_CMD9          = 4'd8;
    localparam SI_CMD7          = 4'd9;
    localparam SI_CMD16         = 4'd11;
    localparam SI_DONE          = 4'd12;
    localparam SI_ERROR         = 4'd13;
    localparam SI_WAIT_CMD      = 4'd14;
    localparam SI_CMD7_WAIT    = 4'd15;  // 1ms delay after CMD7 (R1b busy)

    reg [3:0]  state;
    reg [3:0]  next_state;
    reg [23:0] wait_cnt;
    reg        wait_cnt_zero; // pre-computed: (wait_cnt == 1) one cycle early
    reg [15:0] retry_cnt;
    reg        waiting_cmd;
    reg        is_sector_mode; // OCR[30]: 1=sector addressing (skip CMD16)

    // Pre-register init_start to break cross-module timing path
    reg        init_start_r;

    assign dbg_retry_cnt = (retry_cnt > 16'd255) ? 8'd255 : retry_cnt[7:0];

    always @(*) init_state_dbg = state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= SI_IDLE;
            next_state     <= SI_IDLE;
            wait_cnt       <= 0;
            wait_cnt_zero  <= 1'b1;
            retry_cnt      <= 0;
            waiting_cmd    <= 0;
            is_sector_mode <= 1'b0;
            init_done      <= 1'b0;
            init_error     <= 1'b0;
            init_start_r   <= 1'b0;
            cmd_start     <= 1'b0;
            cmd_index     <= 0;
            cmd_argument  <= 0;
            resp_type_long<= 0;
            resp_expected <= 0;
            cid_reg       <= 0;
            csd_reg       <= 0;
            rca_reg       <= 16'h0001; // default RCA
            info_valid    <= 1'b0;
            use_fast_clk  <= 1'b0;
            emmc_rstn_out <= 1'b0;
        end else begin
            cmd_start    <= 1'b0;
            init_start_r <= init_start;

            case (state)
                SI_IDLE: begin
                    init_done  <= 1'b0;
                    init_error <= 1'b0;
                    if (init_start_r) begin
                        info_valid    <= 1'b0;  // clear only on new init start
                        use_fast_clk  <= 1'b0;  // 400 kHz for init
                        emmc_rstn_out <= 1'b0;  // assert reset
                        wait_cnt      <= TICKS_1MS[23:0];
                        wait_cnt_zero <= 1'b0;  // ensure timer runs full duration
                        state         <= SI_RESET_LOW;
                    end
                end

                SI_RESET_LOW: begin
                    // Hold RST_n low for at least 1ms (down-counter)
                    wait_cnt      <= wait_cnt - 1'b1;
                    wait_cnt_zero <= (wait_cnt == 24'd1);
                    if (wait_cnt_zero) begin
                        emmc_rstn_out <= 1'b1;  // release reset
                        wait_cnt      <= TICKS_50MS[23:0];
                        wait_cnt_zero <= 1'b0;
                        state         <= SI_RESET_HIGH;
                    end
                end

                SI_RESET_HIGH: begin
                    // Wait 50ms after RST_n goes high for power stabilization (down-counter)
                    wait_cnt      <= wait_cnt - 1'b1;
                    wait_cnt_zero <= (wait_cnt == 24'd1);
                    if (wait_cnt_zero) begin
                        state <= SI_CMD0;
                    end
                end

                SI_CMD0: begin
                    // GO_IDLE_STATE - no response
                    cmd_index     <= 6'd0;
                    cmd_argument  <= 32'h00000000;
                    resp_type_long<= 1'b0;
                    resp_expected <= 1'b0;
                    cmd_start     <= 1'b1;
                    next_state    <= SI_CMD1;
                    retry_cnt     <= 0;  // init retry counter ONCE before CMD1 loop
                    wait_cnt      <= 0;
                    state         <= SI_WAIT_CMD;
                end

                SI_CMD1: begin
                    // SEND_OP_COND - R3 response (no CRC check)
                    // Arg: [31] sector mode, [30:24] voltage window 2.7-3.6V
                    cmd_index     <= 6'd1;
                    cmd_argument  <= 32'h40FF8080; // sector mode + 2.7-3.6V + 1.7-1.95V (dual voltage)
                    resp_type_long<= 1'b0;
                    resp_expected <= 1'b1;
                    cmd_start     <= 1'b1;
                    next_state    <= SI_CMD1_WAIT;
                    state         <= SI_WAIT_CMD;
                end

                SI_CMD1_WAIT: begin
                    // Check if card is ready (busy bit [31] in OCR)
                    if (resp_status[31]) begin
                        // Card ready — save sector mode flag (OCR[30])
                        is_sector_mode <= resp_status[30];
                        state <= SI_CMD2;
                    end else begin
                        // Card busy, retry CMD1
                        retry_cnt <= retry_cnt + 1'b1;
                        if (retry_cnt >= MAX_CMD1_RETRIES) begin
                            state <= SI_ERROR;
                        end else begin
                            // Small delay before retry
                            wait_cnt <= 0;
                            state    <= SI_CMD1;
                        end
                    end
                end

                SI_CMD2: begin
                    // ALL_SEND_CID - R2 response (136-bit)
                    cmd_index     <= 6'd2;
                    cmd_argument  <= 32'h00000000;
                    resp_type_long<= 1'b1;
                    resp_expected <= 1'b1;
                    cmd_start     <= 1'b1;
                    next_state    <= SI_CMD3;
                    state         <= SI_WAIT_CMD;
                end

                SI_CMD3: begin
                    // Store CID from CMD2 response
                    cid_reg <= resp_data;

                    // SET_RELATIVE_ADDR - R1 response
                    // For eMMC, host assigns RCA (unlike SD where card proposes)
                    cmd_index     <= 6'd3;
                    cmd_argument  <= {rca_reg, 16'h0000};
                    resp_type_long<= 1'b0;
                    resp_expected <= 1'b1;
                    cmd_start     <= 1'b1;
                    next_state    <= SI_CMD9;
                    state         <= SI_WAIT_CMD;
                end

                SI_CMD9: begin
                    // SEND_CSD - R2 response (136-bit)
                    cmd_index     <= 6'd9;
                    cmd_argument  <= {rca_reg, 16'h0000};
                    resp_type_long<= 1'b1;
                    resp_expected <= 1'b1;
                    cmd_start     <= 1'b1;
                    next_state    <= SI_CMD7;
                    state         <= SI_WAIT_CMD;
                end

                SI_CMD7: begin
                    // Store CSD
                    csd_reg <= resp_data;

                    // SELECT_CARD - R1b response (with busy on DAT0)
                    cmd_index     <= 6'd7;
                    cmd_argument  <= {rca_reg, 16'h0000};
                    resp_type_long<= 1'b0;
                    resp_expected <= 1'b1;
                    cmd_start     <= 1'b1;
                    // Pre-load 1ms timer for CMD7 busy wait
                    wait_cnt      <= TICKS_1MS[23:0];
                    wait_cnt_zero <= 1'b0;
                    next_state    <= SI_CMD7_WAIT;
                    state         <= SI_WAIT_CMD;
                end

                SI_CMD7_WAIT: begin
                    // Fixed 1ms delay after CMD7 (R1b) — card transitions to transfer state.
                    // Full DAT0 polling would require wiring dat_in into emmc_init;
                    // 1ms is conservative (typ. <100us for tran state entry).
                    wait_cnt      <= wait_cnt - 1'b1;
                    wait_cnt_zero <= (wait_cnt == 24'd1);
                    if (wait_cnt_zero) begin
                        // Sector-mode cards (OCR[30]=1) have fixed 512B block size;
                        // CMD16 causes ILLEGAL_COMMAND on them
                        state <= is_sector_mode ? SI_DONE : SI_CMD16;
                    end
                end

                SI_CMD16: begin
                    // SET_BLOCKLEN = 512 bytes
                    cmd_index     <= 6'd16;
                    cmd_argument  <= 32'd512;
                    resp_type_long<= 1'b0;
                    resp_expected <= 1'b1;
                    cmd_start     <= 1'b1;
                    next_state    <= SI_DONE;
                    state         <= SI_WAIT_CMD;
                end

                SI_WAIT_CMD: begin
                    if (cmd_done) begin
                        if (cmd_timeout) begin
                            if (next_state == SI_CMD1_WAIT) begin
                                // CMD1 timeout: card may need time to wake up, retry
                                retry_cnt <= retry_cnt + 1'b1;
                                if (retry_cnt >= MAX_CMD1_RETRIES) begin
                                    state <= SI_ERROR;
                                end else begin
                                    state <= SI_CMD1;
                                end
                            end else begin
                                state <= SI_ERROR;
                            end
                        end else if (cmd_crc_err && next_state != SI_CMD1_WAIT) begin
                            // CRC error (skip for CMD1/R3 where CRC is invalid)
                            state <= SI_ERROR;
                        end else begin
                            state <= next_state;
                        end
                    end
                end

                SI_DONE: begin
                    info_valid   <= 1'b1;
                    init_done    <= 1'b1;
                    use_fast_clk <= 1'b1;  // switch to 25 MHz
                    state        <= SI_IDLE;
                end

                SI_ERROR: begin
                    init_error <= 1'b1;
                    state      <= SI_IDLE;
                end
            endcase
        end
    end

endmodule
