// LED Status Controller
// LED[0] = eMMC Activity (directly driven from external)
// LED[1] = UART Activity (directly driven from external)
// LED[2] = eMMC Ready (directly driven from external)
// LED[3] = Error (directly driven from external)
// LED[4] = Free
// LED[5] = Heartbeat (~1 Hz blink)
// Tang Nano 9K LEDs are active LOW

module led_status (
    input  wire       clk,        // 60 MHz
    input  wire       rst_n,
    input  wire       emmc_active,
    input  wire       uart_active,
    input  wire       emmc_ready,
    input  wire       error,
    output wire [5:0] led_n       // active low outputs
);

    // Heartbeat counter: 60 MHz / 2^27 ~ 0.45 Hz toggle -> ~2.2s blink period
    reg [26:0] hb_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            hb_cnt <= 0;
        else
            hb_cnt <= hb_cnt + 1'b1;
    end

    // UART activity pulse stretcher (make short pulses visible)
    // Pre-computed 1-bit flag replaces 22-bit != 0 OR tree
    reg [21:0] uart_stretch;
    reg        uart_stretch_active;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_stretch <= 0;
            uart_stretch_active <= 1'b0;
        end else if (uart_active) begin
            uart_stretch <= {22{1'b1}};  // ~70 ms at 60 MHz
            uart_stretch_active <= 1'b1;
        end else if (uart_stretch_active) begin
            uart_stretch <= uart_stretch - 1'b1;
            if (uart_stretch == 22'd1)
                uart_stretch_active <= 1'b0;
        end
    end

    // eMMC activity pulse stretcher
    // Pre-computed 1-bit flag replaces 22-bit != 0 OR tree
    reg [21:0] emmc_stretch;
    reg        emmc_stretch_active;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            emmc_stretch <= 0;
            emmc_stretch_active <= 1'b0;
        end else if (emmc_active) begin
            emmc_stretch <= {22{1'b1}};
            emmc_stretch_active <= 1'b1;
        end else if (emmc_stretch_active) begin
            emmc_stretch <= emmc_stretch - 1'b1;
            if (emmc_stretch == 22'd1)
                emmc_stretch_active <= 1'b0;
        end
    end

    // Active low: 0 = LED on, 1 = LED off
    assign led_n[0] = ~emmc_stretch_active; // eMMC Activity
    assign led_n[1] = ~uart_stretch_active; // UART Activity
    assign led_n[2] = ~emmc_ready;          // eMMC Ready
    assign led_n[3] = ~error;               // Error
    assign led_n[4] = 1'b1;                 // Off (free)
    assign led_n[5] = ~hb_cnt[26];          // Heartbeat

endmodule
