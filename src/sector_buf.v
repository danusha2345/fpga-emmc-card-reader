// Dual-port sector buffer (1024 bytes = 2x512 for ping-pong / multi-sector)
// Port A: eMMC side (read/write)
// Port B: UART side (read/write)
// buf_sel_a/b: 2-bit bank select, but only LSB used (banks 0-1, wraps for 2-3)
// Write-through mode (WRITE_MODE=2'b01) supported by Gowin DPB
// Note: 2048-byte single-array causes Gowin DPB full-capacity routing degradation
// that breaks eMMC init timing on real hardware. Keeping 1024 bytes (half-DPB).

module sector_buf (
    input  wire        clk,

    // Port A (eMMC side)
    input  wire [1:0]  buf_sel_a,  // bank select (only bit 0 used)
    input  wire [8:0]  addr_a,     // 0-511 within selected bank
    input  wire [7:0]  wdata_a,
    input  wire        we_a,
    output reg  [7:0]  rdata_a,

    // Port B (UART side)
    input  wire [1:0]  buf_sel_b,  // bank select (only bit 0 used)
    input  wire [8:0]  addr_b,     // 0-511 within selected bank
    input  wire [7:0]  wdata_b,
    input  wire        we_b,
    output reg  [7:0]  rdata_b
);

    // 1024 bytes BRAM (2 banks x 512, fits 1 DPB at half-capacity)
    reg [7:0] mem [0:1023];

    // Full addresses: {buf_sel[0], addr[8:0]} = 10-bit address
    wire [9:0] full_addr_a = {buf_sel_a[0], addr_a};
    wire [9:0] full_addr_b = {buf_sel_b[0], addr_b};

    // Port A - write-through: on write, output new data; on read, output mem
    always @(posedge clk) begin
        if (we_a) begin
            mem[full_addr_a] <= wdata_a;
            rdata_a <= wdata_a;
        end else begin
            rdata_a <= mem[full_addr_a];
        end
    end

    // Port B - write-through
    always @(posedge clk) begin
        if (we_b) begin
            mem[full_addr_b] <= wdata_b;
            rdata_b <= wdata_b;
        end else begin
            rdata_b <= mem[full_addr_b];
        end
    end

endmodule
