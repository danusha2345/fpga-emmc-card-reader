// CRC-8 for UART protocol
// Polynomial: x^8 + x^2 + x + 1 (0x07)
// Processes 1 byte per clock cycle (parallel)

module crc8 (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clear,     // reset CRC to 0
    input  wire       enable,    // process one byte
    input  wire [7:0] data_in,   // byte input
    output wire [7:0] crc_out
);

    reg [7:0] crc;

    // Parallel CRC-8 calculation for 8 bits at once
    // Generated from polynomial 0x07
    wire [7:0] next_crc;
    wire [7:0] d = data_in;
    wire [7:0] c = crc;

    assign next_crc[0] = c[0] ^ c[6] ^ c[7] ^ d[0] ^ d[6] ^ d[7];
    assign next_crc[1] = c[0] ^ c[1] ^ c[6] ^ d[0] ^ d[1] ^ d[6];
    assign next_crc[2] = c[0] ^ c[1] ^ c[2] ^ c[6] ^ d[0] ^ d[1] ^ d[2] ^ d[6];
    assign next_crc[3] = c[1] ^ c[2] ^ c[3] ^ c[7] ^ d[1] ^ d[2] ^ d[3] ^ d[7];
    assign next_crc[4] = c[2] ^ c[3] ^ c[4] ^ d[2] ^ d[3] ^ d[4];
    assign next_crc[5] = c[3] ^ c[4] ^ c[5] ^ d[3] ^ d[4] ^ d[5];
    assign next_crc[6] = c[4] ^ c[5] ^ c[6] ^ d[4] ^ d[5] ^ d[6];
    assign next_crc[7] = c[5] ^ c[6] ^ c[7] ^ d[5] ^ d[6] ^ d[7];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            crc <= 8'd0;
        else if (clear)
            crc <= 8'd0;
        else if (enable)
            crc <= next_crc;
    end

    assign crc_out = crc;

endmodule
