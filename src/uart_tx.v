// UART Transmitter
// Parameterizable baud rate, 8N1 format
// Runtime-switchable clks_per_bit for baud rate changes without re-synthesis

module uart_tx #(
    parameter CLK_FREQ  = 60_000_000,
    parameter BAUD_RATE = 3_000_000
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data_in,      // byte to send
    input  wire       data_valid,   // pulse to start transmission
    input  wire [7:0] clks_per_bit, // Runtime override; 0 = use compile-time default
    output reg        tx,           // UART TX line
    output wire       busy          // high while transmitting
);

    localparam [7:0] DEFAULT_CPB = CLK_FREQ / BAUD_RATE;

    wire [7:0] active_cpb = (clks_per_bit != 8'd0) ? clks_per_bit : DEFAULT_CPB;

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [7:0]  clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift_reg;

    assign busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            clk_cnt   <= 0;
            bit_idx   <= 0;
            shift_reg <= 0;
            tx        <= 1'b1;
        end else begin
            case (state)
                S_IDLE: begin
                    tx      <= 1'b1;
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    if (data_valid) begin
                        shift_reg <= data_in;
                        state     <= S_START;
                    end
                end

                S_START: begin
                    tx <= 1'b0;  // start bit
                    if (clk_cnt == active_cpb - 8'd1) begin
                        clk_cnt <= 0;
                        state   <= S_DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    tx <= shift_reg[0];  // LSB first
                    if (clk_cnt == active_cpb - 8'd1) begin
                        clk_cnt   <= 0;
                        shift_reg <= {1'b0, shift_reg[7:1]};
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
                    tx <= 1'b1;  // stop bit
                    if (clk_cnt == active_cpb - 8'd1) begin
                        clk_cnt <= 0;
                        state   <= S_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
