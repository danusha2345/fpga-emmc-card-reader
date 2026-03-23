// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : Crc16
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module Crc16 (
  input  wire          io_clear,
  input  wire          io_enable,
  input  wire          io_bitIn,
  output wire [15:0]   io_crcOut,
  input  wire          clk,
  input  wire          resetn
);

  reg        [15:0]   crc;
  wire                feedback;

  assign feedback = (crc[15] ^ io_bitIn);
  assign io_crcOut = crc;
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      crc <= 16'h0;
    end else begin
      if(io_clear) begin
        crc <= 16'h0;
      end else begin
        if(io_enable) begin
          crc[15] <= crc[14];
          crc[14] <= crc[13];
          crc[13] <= crc[12];
          crc[12] <= (crc[11] ^ feedback);
          crc[11] <= crc[10];
          crc[10] <= crc[9];
          crc[9] <= crc[8];
          crc[8] <= crc[7];
          crc[7] <= crc[6];
          crc[6] <= crc[5];
          crc[5] <= (crc[4] ^ feedback);
          crc[4] <= crc[3];
          crc[3] <= crc[2];
          crc[2] <= crc[1];
          crc[1] <= crc[0];
          crc[0] <= feedback;
        end
      end
    end
  end


endmodule
