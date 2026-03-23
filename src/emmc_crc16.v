// CRC-16 CCITT for eMMC DAT lines
// Polynomial: x^16 + x^12 + x^5 + 1 (0x1021)
// Processes 1 bit per clock cycle
// Instantiate one per DAT line (4 instances for 4-bit mode)

module emmc_crc16 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,    // reset CRC to 0
    input  wire        enable,   // shift in one bit
    input  wire        bit_in,   // serial data input (one DAT line)
    output wire [15:0] crc_out
);

    reg [15:0] crc;

    wire feedback = crc[15] ^ bit_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            crc <= 16'd0;
        else if (clear)
            crc <= 16'd0;
        else if (enable) begin
            crc[15] <= crc[14];
            crc[14] <= crc[13];
            crc[13] <= crc[12];
            crc[12] <= crc[11] ^ feedback;
            crc[11] <= crc[10];
            crc[10] <= crc[9];
            crc[9]  <= crc[8];
            crc[8]  <= crc[7];
            crc[7]  <= crc[6];
            crc[6]  <= crc[5];
            crc[5]  <= crc[4] ^ feedback;
            crc[4]  <= crc[3];
            crc[3]  <= crc[2];
            crc[2]  <= crc[1];
            crc[1]  <= crc[0];
            crc[0]  <= feedback;
        end
    end

    assign crc_out = crc;

endmodule
