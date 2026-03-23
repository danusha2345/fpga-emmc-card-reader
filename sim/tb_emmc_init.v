// Testbench: eMMC Init Sequence FSM
// Unit test for emmc_init.v with mock CMD responder
// Uses CLK_FREQ=10000 for fast simulation (TICKS_1MS=10, TICKS_10MS=100)

`timescale 1ns / 1ps

module tb_emmc_init;

    reg         clk;
    reg         rst_n;
    reg         init_start;
    wire        init_done;
    wire        init_error;
    wire [3:0]  init_state_dbg;

    wire        cmd_start;
    wire [5:0]  cmd_index;
    wire [31:0] cmd_argument;
    wire        resp_type_long;
    wire        resp_expected;
    reg         cmd_done;
    reg         cmd_timeout;
    reg         cmd_crc_err;
    reg  [31:0] resp_status;
    reg [127:0] resp_data;

    wire [127:0] cid_reg;
    wire [127:0] csd_reg;
    wire [15:0]  rca_reg;
    wire         info_valid;
    wire         use_fast_clk;
    wire         emmc_rstn_out;

    emmc_init #(
        .CLK_FREQ(10000)
    ) uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .init_start     (init_start),
        .init_done      (init_done),
        .init_error     (init_error),
        .init_state_dbg (init_state_dbg),
        .cmd_start      (cmd_start),
        .cmd_index      (cmd_index),
        .cmd_argument   (cmd_argument),
        .resp_type_long (resp_type_long),
        .resp_expected  (resp_expected),
        .cmd_done       (cmd_done),
        .cmd_timeout    (cmd_timeout),
        .cmd_crc_err    (cmd_crc_err),
        .resp_status    (resp_status),
        .resp_data      (resp_data),
        .cid_reg        (cid_reg),
        .csd_reg        (csd_reg),
        .rca_reg        (rca_reg),
        .info_valid     (info_valid),
        .use_fast_clk   (use_fast_clk),
        .emmc_rstn_out  (emmc_rstn_out),
        .dbg_retry_cnt  ()
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    initial begin
        #10_000_000;
        $display("FAIL: tb_emmc_init - timeout");
        $finish(1);
    end

    // Test scenario control
    reg [7:0]  cmd1_ready_after;
    reg        inject_timeout_cmd;
    reg [5:0]  timeout_cmd_idx;
    reg        inject_crc_err_cmd;
    reg [5:0]  crc_err_cmd_idx;

    // CMD responder: responds 2 cycles after cmd_start rising edge
    reg        cmd_start_d1;
    reg        cmd_start_d2;
    reg        cmd_start_rising;
    reg [5:0]  cmd_start_d1_index;
    reg [7:0]  cmd1_retry_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_start_d1 <= 0;
            cmd_start_d2 <= 0;
            cmd_start_rising <= 0;
            cmd_start_d1_index <= 0;
        end else begin
            cmd_start_d1 <= cmd_start;
            cmd_start_d2 <= cmd_start_d1;
            cmd_start_rising <= cmd_start_d1 && !cmd_start_d2;
            if (cmd_start && !cmd_start_d1)
                cmd_start_d1_index <= cmd_index;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_done       <= 1'b0;
            cmd_timeout    <= 1'b0;
            cmd_crc_err    <= 1'b0;
            resp_status    <= 32'd0;
            resp_data      <= 128'd0;
            cmd1_retry_count <= 0;
        end else begin
            cmd_done    <= 1'b0;
            cmd_timeout <= 1'b0;
            cmd_crc_err <= 1'b0;

            if (cmd_start_rising) begin
                if (inject_timeout_cmd && cmd_start_d1_index == timeout_cmd_idx) begin
                    cmd_done    <= 1'b1;
                    cmd_timeout <= 1'b1;
                end
                else if (inject_crc_err_cmd && cmd_start_d1_index == crc_err_cmd_idx) begin
                    cmd_done    <= 1'b1;
                    cmd_crc_err <= 1'b1;
                    if (cmd_start_d1_index == 6'd1)
                        resp_status <= 32'hC0FF8080;
                end
                else begin
                    case (cmd_start_d1_index)
                        6'd0: cmd_done <= 1'b1;
                        6'd1: begin
                            cmd1_retry_count <= cmd1_retry_count + 1'b1;
                            cmd_done <= 1'b1;
                            if (cmd1_retry_count >= cmd1_ready_after)
                                resp_status <= 32'hC0FF8080;
                            else
                                resp_status <= 32'h00FF8080;
                        end
                        6'd2: begin
                            cmd_done  <= 1'b1;
                            resp_data <= 128'hDEAD_BEEF_1234_5678_ABCD_EF01_2345_6789;
                        end
                        6'd3: begin
                            cmd_done    <= 1'b1;
                            resp_status <= 32'h0000_0500;
                        end
                        6'd9: begin
                            cmd_done  <= 1'b1;
                            resp_data <= 128'hCAFE_BABE_9876_5432_FEDC_BA98_7654_3210;
                        end
                        6'd7: begin
                            cmd_done    <= 1'b1;
                            resp_status <= 32'h0000_0700;
                        end
                        6'd16: begin
                            cmd_done    <= 1'b1;
                            resp_status <= 32'h0000_0900;
                        end
                        default: begin
                            cmd_done    <= 1'b1;
                            resp_status <= 32'h0000_0900;
                        end
                    endcase
                end
            end
        end
    end

    // Sticky capture for 1-cycle pulse outputs
    reg         init_done_seen;
    reg         init_error_seen;
    reg         info_valid_seen;
    reg [127:0] captured_cid;
    reg [127:0] captured_csd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_done_seen  <= 0;
            init_error_seen <= 0;
            info_valid_seen <= 0;
            captured_cid    <= 0;
            captured_csd    <= 0;
        end else begin
            if (init_done)  init_done_seen  <= 1;
            if (init_error) init_error_seen <= 1;
            if (info_valid) begin
                info_valid_seen <= 1;
                captured_cid <= cid_reg;
                captured_csd <= csd_reg;
            end
        end
    end

    task do_reset;
        begin
            rst_n = 0;
            init_start = 0;
            repeat (8) @(posedge clk);
            #1;
            rst_n = 1;
            repeat (4) @(posedge clk);
        end
    endtask

    task start_and_wait;
        begin
            @(negedge clk);
            init_start = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            init_start = 1'b0;

            begin : wait_complete
                integer cnt;
                for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                    @(posedge clk);
                    if (init_done_seen || init_error_seen)
                        disable wait_complete;
                end
            end
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        // ============================================================
        // Test 1: Happy path
        // ============================================================
        $display("  Test 1: Happy path...");
        cmd1_ready_after    = 8'd0;
        inject_timeout_cmd  = 1'b0;
        timeout_cmd_idx     = 6'd0;
        inject_crc_err_cmd  = 1'b0;
        crc_err_cmd_idx     = 6'd0;

        do_reset;
        start_and_wait;

        if (!init_done_seen) begin
            $display("FAIL: T1 init_done not set");
            errors = errors + 1;
        end
        if (init_error_seen) begin
            $display("FAIL: T1 unexpected init_error");
            errors = errors + 1;
        end
        if (!use_fast_clk) begin
            $display("FAIL: T1 use_fast_clk not set");
            errors = errors + 1;
        end
        if (!info_valid_seen) begin
            $display("FAIL: T1 info_valid not seen");
            errors = errors + 1;
        end
        if (captured_cid !== 128'hDEAD_BEEF_1234_5678_ABCD_EF01_2345_6789) begin
            $display("FAIL: T1 CID mismatch: 0x%032X", captured_cid);
            errors = errors + 1;
        end
        if (captured_csd !== 128'hCAFE_BABE_9876_5432_FEDC_BA98_7654_3210) begin
            $display("FAIL: T1 CSD mismatch: 0x%032X", captured_csd);
            errors = errors + 1;
        end

        // ============================================================
        // Test 2: CMD1 polling — ready after 5 retries
        // ============================================================
        $display("  Test 2: CMD1 polling (5 retries)...");
        cmd1_ready_after = 8'd5;
        inject_timeout_cmd  = 1'b0;
        inject_crc_err_cmd  = 1'b0;

        do_reset;
        start_and_wait;

        if (!init_done_seen) begin
            $display("FAIL: T2 init_done not set");
            errors = errors + 1;
        end
        if (init_error_seen) begin
            $display("FAIL: T2 unexpected init_error");
            errors = errors + 1;
        end

        // ============================================================
        // Test 3: CMD1 extended polling (50 retries)
        // ============================================================
        $display("  Test 3: CMD1 extended polling (50 retries)...");
        cmd1_ready_after = 8'd50;
        inject_timeout_cmd  = 1'b0;
        inject_crc_err_cmd  = 1'b0;

        do_reset;
        start_and_wait;

        if (!init_done_seen) begin
            $display("FAIL: T3 init_done not set");
            errors = errors + 1;
        end
        if (init_error_seen) begin
            $display("FAIL: T3 unexpected init_error");
            errors = errors + 1;
        end

        // ============================================================
        // Test 4: CMD timeout on CMD2
        // ============================================================
        $display("  Test 4: CMD timeout on CMD2...");
        cmd1_ready_after   = 8'd0;
        inject_timeout_cmd = 1'b1;
        timeout_cmd_idx    = 6'd2;
        inject_crc_err_cmd = 1'b0;

        do_reset;
        start_and_wait;

        if (init_done_seen) begin
            $display("FAIL: T4 init_done should not be set");
            errors = errors + 1;
        end
        if (!init_error_seen) begin
            $display("FAIL: T4 init_error not set");
            errors = errors + 1;
        end

        // ============================================================
        // Test 5: CRC error on CMD3
        // ============================================================
        $display("  Test 5: CRC error on CMD3...");
        cmd1_ready_after    = 8'd0;
        inject_timeout_cmd  = 1'b0;
        inject_crc_err_cmd  = 1'b1;
        crc_err_cmd_idx     = 6'd3;

        do_reset;
        start_and_wait;

        if (init_done_seen) begin
            $display("FAIL: T5 init_done should not be set");
            errors = errors + 1;
        end
        if (!init_error_seen) begin
            $display("FAIL: T5 init_error not set");
            errors = errors + 1;
        end

        // ============================================================
        // Test 6: CRC error on CMD1 (ignored for R3)
        // ============================================================
        $display("  Test 6: CRC error on CMD1 (ignored for R3)...");
        cmd1_ready_after    = 8'd0;
        inject_timeout_cmd  = 1'b0;
        inject_crc_err_cmd  = 1'b1;
        crc_err_cmd_idx     = 6'd1;

        do_reset;
        start_and_wait;

        if (!init_done_seen) begin
            $display("FAIL: T6 init_done not set");
            errors = errors + 1;
        end
        if (init_error_seen) begin
            $display("FAIL: T6 unexpected init_error");
            errors = errors + 1;
        end

        // ============================================================
        // Test 7: RST_n timing
        // ============================================================
        $display("  Test 7: RST_n timing...");
        cmd1_ready_after    = 8'd0;
        inject_timeout_cmd  = 1'b0;
        inject_crc_err_cmd  = 1'b0;

        do_reset;

        if (emmc_rstn_out !== 1'b0) begin
            $display("FAIL: T7 RST_n should be low before init");
            errors = errors + 1;
        end

        @(negedge clk);
        init_start = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        init_start = 1'b0;

        // Wait for RST_n to go high
        begin : wait_rstn
            integer cnt;
            for (cnt = 0; cnt < 2000; cnt = cnt + 1) begin
                @(posedge clk);
                if (emmc_rstn_out === 1'b1)
                    disable wait_rstn;
            end
            $display("FAIL: T7 RST_n never went high");
            errors = errors + 1;
        end

        begin : wait_t7
            integer cnt;
            for (cnt = 0; cnt < 500_000; cnt = cnt + 1) begin
                @(posedge clk);
                if (init_done_seen || init_error_seen) disable wait_t7;
            end
        end

        if (!init_done_seen) begin
            $display("FAIL: T7 init_done not set");
            errors = errors + 1;
        end

        // ============================================================
        // Results
        // ============================================================
        repeat (4) @(posedge clk);
        if (errors == 0)
            $display("[PASS] tb_emmc_init");
        else
            $display("[FAIL] tb_emmc_init (%0d errors)", errors);
        $finish(errors != 0);
    end

endmodule
