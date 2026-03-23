// Testbench: LED Status Controller
// Tests pulse stretching, direct LED mapping, heartbeat toggle

`timescale 1ns / 1ps

module tb_led_status;

    reg        clk;
    reg        rst_n;
    reg        emmc_active;
    reg        uart_active;
    reg        emmc_ready;
    reg        error;
    wire [5:0] led_n;

    led_status uut (
        .clk         (clk),
        .rst_n       (rst_n),
        .emmc_active (emmc_active),
        .uart_active (uart_active),
        .emmc_ready  (emmc_ready),
        .error       (error),
        .led_n       (led_n)
    );

    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz (close enough to 60 MHz for testing)

    integer errors = 0;

    // Watchdog
    initial begin
        #500_000;
        $display("FAIL: tb_led_status - timeout");
        $finish(1);
    end

    initial begin
        rst_n       = 0;
        emmc_active = 0;
        uart_active = 0;
        emmc_ready  = 0;
        error       = 0;

        repeat (8) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ============================================================
        // Test 1: Reset state — all LEDs off (led_n = 1)
        // ============================================================
        $display("  Test 1: Reset state...");
        if (led_n !== 6'b11_1111) begin
            $display("FAIL: reset led_n=0b%06b, expected 0b111111", led_n);
            errors = errors + 1;
        end

        // ============================================================
        // Test 2: eMMC activity stretch — single pulse → LED on
        // ============================================================
        $display("  Test 2: eMMC activity stretch...");
        emmc_active = 1'b1;
        @(posedge clk);
        emmc_active = 1'b0;
        repeat (4) @(posedge clk);  // let stretcher activate

        if (led_n[0] !== 1'b0) begin
            $display("FAIL: eMMC activity LED not on after pulse");
            errors = errors + 1;
        end

        // LED should stay on for ~4M cycles (22-bit counter at ~60 MHz)
        // Check it's still on after 100 cycles
        repeat (100) @(posedge clk);
        if (led_n[0] !== 1'b0) begin
            $display("FAIL: eMMC activity LED turned off too early");
            errors = errors + 1;
        end

        // Force stretch counter near end to verify turn-off
        force uut.emmc_stretch = 22'd2;
        @(posedge clk);
        release uut.emmc_stretch;
        repeat (4) @(posedge clk);

        if (led_n[0] !== 1'b1) begin
            $display("FAIL: eMMC activity LED did not turn off after stretch expired");
            errors = errors + 1;
        end

        // ============================================================
        // Test 3: UART activity stretch + re-trigger
        // ============================================================
        $display("  Test 3: UART activity stretch + re-trigger...");
        uart_active = 1'b1;
        @(posedge clk);
        uart_active = 1'b0;
        repeat (4) @(posedge clk);

        if (led_n[1] !== 1'b0) begin
            $display("FAIL: UART activity LED not on after pulse");
            errors = errors + 1;
        end

        // Re-trigger: force near end, then re-pulse
        force uut.uart_stretch = 22'd5;
        @(posedge clk);
        release uut.uart_stretch;
        repeat (2) @(posedge clk);

        // Re-trigger before expiry
        uart_active = 1'b1;
        @(posedge clk);
        uart_active = 1'b0;
        repeat (2) @(posedge clk);

        // Counter should be reloaded (all 1s), LED still on
        if (led_n[1] !== 1'b0) begin
            $display("FAIL: UART activity LED not on after re-trigger");
            errors = errors + 1;
        end

        // Force off
        force uut.uart_stretch = 22'd2;
        force uut.uart_stretch_active = 1'b1;
        @(posedge clk);
        release uut.uart_stretch;
        release uut.uart_stretch_active;
        repeat (4) @(posedge clk);

        // ============================================================
        // Test 4: Direct LEDs — emmc_ready and error
        // ============================================================
        $display("  Test 4: Direct LEDs...");
        emmc_ready = 1'b1;
        error      = 1'b0;
        @(posedge clk);

        if (led_n[2] !== 1'b0) begin
            $display("FAIL: emmc_ready LED not on");
            errors = errors + 1;
        end
        if (led_n[3] !== 1'b1) begin
            $display("FAIL: error LED should be off");
            errors = errors + 1;
        end
        if (led_n[4] !== 1'b1) begin
            $display("FAIL: free LED should always be off");
            errors = errors + 1;
        end

        error = 1'b1;
        @(posedge clk);
        if (led_n[3] !== 1'b0) begin
            $display("FAIL: error LED not on");
            errors = errors + 1;
        end

        emmc_ready = 1'b0;
        error      = 1'b0;
        @(posedge clk);

        // ============================================================
        // Test 5: Heartbeat toggle
        // ============================================================
        $display("  Test 5: Heartbeat toggle...");
        // Force heartbeat counter near toggle point
        force uut.hb_cnt = 27'h3FF_FFFE;
        @(posedge clk);
        release uut.hb_cnt;

        // Capture current heartbeat LED state
        begin
            reg prev_hb;
            prev_hb = led_n[5];
            // Wait a few clocks for counter to overflow and toggle
            repeat (4) @(posedge clk);
            if (led_n[5] === prev_hb) begin
                $display("FAIL: heartbeat LED did not toggle");
                errors = errors + 1;
            end
        end

        // ============================================================
        // Results
        // ============================================================
        repeat (4) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_led_status");
        else
            $display("[FAIL] tb_led_status (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
