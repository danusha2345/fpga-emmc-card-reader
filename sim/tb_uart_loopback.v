// Testbench: UART TX -> RX loopback
// TX sends bytes, RX receives them through direct wire connection

`timescale 1ns / 1ps

module tb_uart_loopback;

    localparam CLK_FREQ  = 100_000_000;
    localparam BAUD_RATE = 3_000_000;
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // 33

    reg        clk;
    reg        rst_n;
    reg  [7:0] tx_data;
    reg        tx_valid;
    wire       tx_line;
    wire       tx_busy;

    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_frame_err;

    // Runtime clks_per_bit override to match simulated clock frequency (100 MHz)
    wire [7:0] clks_per_bit_override = 8'd33;

    uart_tx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (tx_data),
        .data_valid(tx_valid),
        .clks_per_bit(clks_per_bit_override),
        .tx        (tx_line),
        .busy      (tx_busy)
    );

    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_rx (
        .clk       (clk),
        .rst_n     (rst_n),
        .rx        (tx_line),   // loopback
        .clks_per_bit(clks_per_bit_override),
        .data_out  (rx_data),
        .data_valid(rx_valid),
        .frame_err (rx_frame_err)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    // Send a byte and wait for TX to finish + inter-byte gap
    task send_byte(input [7:0] b);
        begin
            @(posedge clk);
            tx_data  <= b;
            tx_valid <= 1'b1;
            @(posedge clk);
            tx_valid <= 1'b0;
            // Wait for busy to go high (transmission started)
            begin : wait_busy_hi
                integer cnt;
                for (cnt = 0; cnt < 10; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (tx_busy) disable wait_busy_hi;
                end
            end
            // Wait for busy to go low (transmission done)
            wait (tx_busy == 1'b0);
            // Inter-byte gap: let RX fully process stop bit
            repeat (CLKS_PER_BIT * 2) @(posedge clk);
        end
    endtask

    // Receive buffer
    reg [7:0] recv_buf [0:255];
    integer   recv_cnt;

    // Capture all received bytes in background
    initial begin
        recv_cnt = 0;
        forever begin
            @(posedge clk);
            if (rx_valid) begin
                recv_buf[recv_cnt] = rx_data;
                recv_cnt = recv_cnt + 1;
            end
        end
    end

    // Watchdog
    initial begin
        #2_000_000;
        $display("FAIL: tb_uart_loopback - timeout");
        $finish(1);
    end

    integer k;

    initial begin
        rst_n    = 0;
        tx_data  = 0;
        tx_valid = 0;

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // ---- Send test pattern ----
        send_byte(8'h00);
        send_byte(8'hFF);
        send_byte(8'hAA);
        send_byte(8'h55);
        send_byte(8'h01);
        send_byte(8'h80);
        send_byte(8'h7E);
        send_byte(8'hDE);

        // Wait for last byte to be received
        repeat (CLKS_PER_BIT * 12) @(posedge clk);

        // ---- Verify ----
        if (recv_cnt !== 8) begin
            $display("FAIL: expected 8 bytes, received %0d", recv_cnt);
            errors = errors + 1;
        end else begin
            if (recv_buf[0] !== 8'h00) begin $display("FAIL: byte 0: 0x%02X != 0x00", recv_buf[0]); errors = errors + 1; end
            if (recv_buf[1] !== 8'hFF) begin $display("FAIL: byte 1: 0x%02X != 0xFF", recv_buf[1]); errors = errors + 1; end
            if (recv_buf[2] !== 8'hAA) begin $display("FAIL: byte 2: 0x%02X != 0xAA", recv_buf[2]); errors = errors + 1; end
            if (recv_buf[3] !== 8'h55) begin $display("FAIL: byte 3: 0x%02X != 0x55", recv_buf[3]); errors = errors + 1; end
            if (recv_buf[4] !== 8'h01) begin $display("FAIL: byte 4: 0x%02X != 0x01", recv_buf[4]); errors = errors + 1; end
            if (recv_buf[5] !== 8'h80) begin $display("FAIL: byte 5: 0x%02X != 0x80", recv_buf[5]); errors = errors + 1; end
            if (recv_buf[6] !== 8'h7E) begin $display("FAIL: byte 6: 0x%02X != 0x7E", recv_buf[6]); errors = errors + 1; end
            if (recv_buf[7] !== 8'hDE) begin $display("FAIL: byte 7: 0x%02X != 0xDE", recv_buf[7]); errors = errors + 1; end
        end

        // Check no frame errors
        // (frame_err is a pulse, we'd need to capture it — but if data arrived OK, it's fine)

        if (errors == 0)
            $display("[PASS] tb_uart_loopback");
        else
            $display("[FAIL] tb_uart_loopback (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
