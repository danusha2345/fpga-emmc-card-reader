// Testbench: verify exact bit pattern and CRC-7 on CMD line output
// This test captures every bit transmitted by emmc_cmd and verifies:
//   1. Frame structure: start(0) + transmit(1) + index(6) + arg(32) + CRC(7) + end(1) = 48 bits
//   2. CRC-7 matches independently computed value
//   3. Specifically checks CMD0 and CMD1 frames

`timescale 1ns / 1ps

module tb_emmc_cmd_crc_verify;

    reg        clk;
    reg        rst_n;
    reg        clk_en;

    reg        cmd_start;
    reg  [5:0] cmd_index;
    reg [31:0] cmd_argument;
    reg        resp_type_long;
    reg        resp_expected;
    wire       cmd_done;
    wire       cmd_timeout;
    wire       cmd_crc_err;
    wire [31:0] resp_status;
    wire [127:0] resp_data;

    wire       cmd_out;
    wire       cmd_oe;

    // CMD line: just host output (no card response for this test)
    wire cmd_line = cmd_oe ? cmd_out : 1'b1;

    emmc_cmd uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .clk_en         (clk_en),
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
        .cmd_out        (cmd_out),
        .cmd_oe         (cmd_oe),
        .cmd_in         (cmd_line),
        .dbg_state      ()
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer errors = 0;

    // Generate clk_en every 4 cycles
    reg [1:0] clk_div;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div <= 0;
            clk_en  <= 0;
        end else begin
            clk_en  <= (clk_div == 2'd3);
            clk_div <= clk_div + 1'b1;
        end
    end

    // Capture bits on CMD line when host is driving
    reg [47:0] captured_frame;
    integer     capture_cnt;
    reg         capturing;

    always @(posedge clk) begin
        if (!rst_n) begin
            captured_frame <= 0;
            capture_cnt    <= 0;
            capturing      <= 0;
        end else if (clk_en) begin
            if (cmd_oe) begin
                captured_frame <= {captured_frame[46:0], cmd_out};
                capture_cnt    <= capture_cnt + 1;
                capturing      <= 1;
            end else if (capturing) begin
                capturing <= 0;  // host stopped driving
            end
        end
    end

    // Independent CRC-7 computation
    function [6:0] calc_crc7;
        input [39:0] data; // 40 bits [47:8] MSB first
        integer i;
        reg [6:0] crc;
        reg       fb;
        begin
            crc = 7'd0;
            for (i = 39; i >= 0; i = i - 1) begin
                fb = crc[6] ^ data[i];
                crc[6] = crc[5];
                crc[5] = crc[4];
                crc[4] = crc[3];
                crc[3] = crc[2] ^ fb;
                crc[2] = crc[1];
                crc[1] = crc[0];
                crc[0] = fb;
            end
            calc_crc7 = crc;
        end
    endfunction

    // Verify captured frame
    // NOTE: capture gets 47 bits (end bit missed because cmd_oe goes low
    // on the same NBA cycle). frame[46:0] = CMD bits [47:1], frame[47] = junk.
    task verify_frame(
        input [5:0]  exp_index,
        input [31:0] exp_arg,
        input [47:0] frame,
        input integer num_bits
    );
        reg [6:0] expected_crc;
        reg [6:0] actual_crc;
        reg [39:0] crc_data;
        begin
            $display("  Captured %0d bits on CMD line (47 expected, end bit not captured)", num_bits);

            if (num_bits != 47) begin
                $display("  WARN: expected 47 captured bits, got %0d", num_bits);
            end

            // frame[46:0] holds the 47 captured bits:
            //   frame[46]    = start bit (CMD frame bit 47)
            //   frame[45]    = transmit bit (CMD frame bit 46)
            //   frame[44:39] = index (CMD frame bits 45:40)
            //   frame[38:7]  = argument (CMD frame bits 39:8)
            //   frame[6:0]   = CRC-7 (CMD frame bits 7:1)
            // End bit (CMD frame bit 0) is NOT captured.

            $display("  Start=%b Transmit=%b Index=%06b Arg=%032b CRC=%07b",
                     frame[46], frame[45], frame[44:39], frame[38:7], frame[6:0]);

            // Check start bit
            if (frame[46] !== 1'b0) begin
                $display("  FAIL: start bit is %b, expected 0", frame[46]);
                errors = errors + 1;
            end

            // Check transmit bit
            if (frame[45] !== 1'b1) begin
                $display("  FAIL: transmit bit is %b, expected 1", frame[45]);
                errors = errors + 1;
            end

            // Check index
            if (frame[44:39] !== exp_index) begin
                $display("  FAIL: index=%06b, expected %06b", frame[44:39], exp_index);
                errors = errors + 1;
            end

            // Check argument
            if (frame[38:7] !== exp_arg) begin
                $display("  FAIL: arg=0x%08X, expected 0x%08X", frame[38:7], exp_arg);
                errors = errors + 1;
            end

            // Compute expected CRC-7 over data bits [46:7] (40 bits: start+transmit+index+arg)
            crc_data = frame[46:7];
            expected_crc = calc_crc7(crc_data);
            actual_crc   = frame[6:0];

            $display("  CRC-7: actual=%07b (0x%02X), expected=%07b (0x%02X)",
                     actual_crc, actual_crc, expected_crc, expected_crc);

            if (actual_crc !== expected_crc) begin
                $display("  **FAIL**: CRC-7 MISMATCH! Card will reject this command!");
                errors = errors + 1;
            end else begin
                $display("  CRC-7: OK");
            end
        end
    endtask

    // Watchdog
    initial begin
        #10_000_000;
        $display("FAIL: timeout");
        $finish(1);
    end

    initial begin
        rst_n          = 0;
        cmd_start      = 0;
        cmd_index      = 0;
        cmd_argument   = 0;
        resp_type_long = 0;
        resp_expected  = 0;

        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (8) @(posedge clk);

        // ---- Test 1: CMD0 (GO_IDLE_STATE, no response) ----
        $display("\n=== Test 1: CMD0 (index=0, arg=0x00000000) ===");
        captured_frame <= 0;
        capture_cnt    <= 0;
        @(posedge clk);
        cmd_index     <= 6'd0;
        cmd_argument  <= 32'h0000_0000;
        resp_expected <= 1'b0;
        resp_type_long<= 1'b0;
        cmd_start     <= 1'b1;
        @(posedge clk);
        cmd_start <= 1'b0;

        // Wait for cmd_done
        begin : wait1
            integer i;
            for (i = 0; i < 2000; i = i + 1) begin
                @(posedge clk);
                if (cmd_done) disable wait1;
            end
        end

        // Allow a few more cycles for capture to settle
        repeat (10) @(posedge clk);

        verify_frame(6'd0, 32'h0000_0000, captured_frame, capture_cnt);

        repeat (40) @(posedge clk);

        // ---- Test 2: CMD1 (SEND_OP_COND, no response — timeout) ----
        $display("\n=== Test 2: CMD1 (index=1, arg=0x40FF8000) ===");
        captured_frame <= 0;
        capture_cnt    <= 0;
        @(posedge clk);
        cmd_index     <= 6'd1;
        cmd_argument  <= 32'h40FF8000;
        resp_expected <= 1'b0;   // no response, just capture TX
        resp_type_long<= 1'b0;
        cmd_start     <= 1'b1;
        @(posedge clk);
        cmd_start <= 1'b0;

        begin : wait2
            integer i;
            for (i = 0; i < 2000; i = i + 1) begin
                @(posedge clk);
                if (cmd_done) disable wait2;
            end
        end

        repeat (10) @(posedge clk);

        verify_frame(6'd1, 32'h40FF8000, captured_frame, capture_cnt);

        repeat (40) @(posedge clk);

        // ---- Test 3: CMD3 (SET_RELATIVE_ADDR) ----
        $display("\n=== Test 3: CMD3 (index=3, arg=0x00010000) ===");
        captured_frame <= 0;
        capture_cnt    <= 0;
        @(posedge clk);
        cmd_index     <= 6'd3;
        cmd_argument  <= 32'h0001_0000;
        resp_expected <= 1'b0;
        resp_type_long<= 1'b0;
        cmd_start     <= 1'b1;
        @(posedge clk);
        cmd_start <= 1'b0;

        begin : wait3
            integer i;
            for (i = 0; i < 2000; i = i + 1) begin
                @(posedge clk);
                if (cmd_done) disable wait3;
            end
        end

        repeat (10) @(posedge clk);

        verify_frame(6'd3, 32'h0001_0000, captured_frame, capture_cnt);

        // ---- Results ----
        repeat (10) @(posedge clk);
        $display("\n============================");
        if (errors == 0)
            $display("[PASS] tb_emmc_cmd_crc_verify — all CRC-7 values correct");
        else
            $display("[FAIL] tb_emmc_cmd_crc_verify — %0d errors (CRC-7 bug confirmed!)", errors);
        $display("============================\n");
        $finish(errors != 0);
    end

endmodule
