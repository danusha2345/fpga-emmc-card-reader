// UART Receiver
// Parameterizable baud rate, 8N1 format
// Runtime-switchable clks_per_bit for baud rate changes without re-synthesis

module uart_rx #(
    parameter CLK_FREQ  = 60_000_000,
    parameter BAUD_RATE = 3_000_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,           // UART RX line
    input  wire [7:0] clks_per_bit, // Runtime override; 0 = use compile-time default
    output reg  [7:0] data_out,     // received byte
    output reg        data_valid,   // pulse when byte ready
    output reg        frame_err     // framing error (bad stop bit)
);

    localparam [7:0] DEFAULT_CPB = CLK_FREQ / BAUD_RATE;

    wire [7:0] active_cpb = (clks_per_bit != 8'd0) ? clks_per_bit : DEFAULT_CPB;
    wire [7:0] half_cpb   = {1'b0, active_cpb[7:1]};  // active_cpb >> 1

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [7:0]  clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift_reg;

    // Double-flop synchronizer for RX
    reg rx_sync1, rx_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end

    wire rx_s = rx_sync2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            clk_cnt    <= 0;
            bit_idx    <= 0;
            shift_reg  <= 0;
            data_out   <= 0;
            data_valid <= 1'b0;
            frame_err  <= 1'b0;
        end else begin
            data_valid <= 1'b0;
            frame_err  <= 1'b0;

            case (state)
                S_IDLE: begin
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (rx_s == 1'b0) begin  // start bit detected
                        state <= S_START;
                    end
                end

                S_START: begin
                    if (clk_cnt == half_cpb - 8'd1) begin
                        clk_cnt <= 0;
                        if (rx_s == 1'b0) begin  // still low at midpoint
                            state <= S_DATA;
                        end else begin
                            state <= S_IDLE;  // false start
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    if (clk_cnt == active_cpb - 8'd1) begin
                        clk_cnt <= 0;
                        shift_reg <= {rx_s, shift_reg[7:1]}; // LSB first
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    if (clk_cnt == active_cpb - 8'd1) begin
                        clk_cnt <= 0;
                        if (rx_s == 1'b1) begin  // valid stop bit
                            data_out   <= shift_reg;
                            data_valid <= 1'b1;
                        end else begin
                            frame_err <= 1'b1;
                        end
                        state <= S_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
