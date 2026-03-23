// CRC-7 for eMMC CMD line
// Polynomial: x^7 + x^3 + 1 (0x09)
// Processes 1 bit per clock cycle

module emmc_crc7 (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clear,    // reset CRC to 0
    input  wire       enable,   // shift in one bit
    input  wire       bit_in,   // serial data input
    output wire [6:0] crc_out
);

    reg [6:0] crc;

    wire feedback = crc[6] ^ bit_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            crc <= 7'd0;
        else if (clear)
            crc <= 7'd0;
        else if (enable) begin
            crc[6] <= crc[5];
            crc[5] <= crc[4];
            crc[4] <= crc[3];
            crc[3] <= crc[2] ^ feedback;
            crc[2] <= crc[1];
            crc[1] <= crc[0];
            crc[0] <= feedback;
        end
    end

    assign crc_out = crc;

endmodule
