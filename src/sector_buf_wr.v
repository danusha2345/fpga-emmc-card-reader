// Write FIFO buffer (8192 bytes = 16 banks x 512)
// Split into 2 halves (2x 4096 bytes = 2x 2DPB) to avoid Gowin PnR
// routing degradation that causes bit errors at specific BRAM addresses.
// Previous: single mem[0:8191] (4 DPB) had marginal routing on addresses
// 24, 72, 200, 280, 296, 408, 424, 440 within each sector — bit 4 flips.
//
// Port A: eMMC read-only (reads data to write to card)
// Port B: UART write-only (receives data from PC)

module sector_buf_wr (
    input  wire        clk,

    // Port A (eMMC read side)
    input  wire [3:0]  rd_bank,    // 0-15
    input  wire [8:0]  rd_addr,    // 0-511 within bank
    output wire [7:0]  rd_data,

    // Port B (UART write side)
    input  wire [3:0]  wr_bank,    // 0-15
    input  wire [8:0]  wr_addr,    // 0-511 within bank
    input  wire [7:0]  wr_data,
    input  wire        wr_en
);

    // Split: bank[3] selects half, bank[2:0]+addr[8:0] = 12-bit address within half
    wire half_sel_rd = rd_bank[3];
    wire half_sel_wr = wr_bank[3];

    wire [11:0] half_rd_addr = {rd_bank[2:0], rd_addr};
    wire [11:0] half_wr_addr = {wr_bank[2:0], wr_addr};

    // Half 0: banks 0-7 (4096 bytes, 2 DPB)
    reg [7:0] mem_lo [0:4095];
    reg [7:0] rd_data_lo;

    always @(posedge clk) begin
        rd_data_lo <= mem_lo[half_rd_addr];
    end

    always @(posedge clk) begin
        if (wr_en && !half_sel_wr)
            mem_lo[half_wr_addr] <= wr_data;
    end

    // Half 1: banks 8-15 (4096 bytes, 2 DPB)
    reg [7:0] mem_hi [0:4095];
    reg [7:0] rd_data_hi;

    always @(posedge clk) begin
        rd_data_hi <= mem_hi[half_rd_addr];
    end

    always @(posedge clk) begin
        if (wr_en && half_sel_wr)
            mem_hi[half_wr_addr] <= wr_data;
    end

    // Output mux (registered half_sel for timing)
    reg half_sel_rd_r;
    always @(posedge clk) begin
        half_sel_rd_r <= half_sel_rd;
    end

    assign rd_data = half_sel_rd_r ? rd_data_hi : rd_data_lo;

endmodule
