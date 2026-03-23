// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : Crc8
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module Crc8 (
  input  wire          io_clear,
  input  wire          io_enable,
  input  wire [7:0]    io_dataIn,
  output wire [7:0]    io_crcOut,
  input  wire          clk,
  input  wire          resetn
);

  reg        [7:0]    crc;
  reg        [7:0]    nextCrc;

  always @(*) begin
    nextCrc[0] = (((((crc[0] ^ crc[6]) ^ crc[7]) ^ io_dataIn[0]) ^ io_dataIn[6]) ^ io_dataIn[7]);
    nextCrc[1] = (((((crc[0] ^ crc[1]) ^ crc[6]) ^ io_dataIn[0]) ^ io_dataIn[1]) ^ io_dataIn[6]);
    nextCrc[2] = (((((((crc[0] ^ crc[1]) ^ crc[2]) ^ crc[6]) ^ io_dataIn[0]) ^ io_dataIn[1]) ^ io_dataIn[2]) ^ io_dataIn[6]);
    nextCrc[3] = (((((((crc[1] ^ crc[2]) ^ crc[3]) ^ crc[7]) ^ io_dataIn[1]) ^ io_dataIn[2]) ^ io_dataIn[3]) ^ io_dataIn[7]);
    nextCrc[4] = (((((crc[2] ^ crc[3]) ^ crc[4]) ^ io_dataIn[2]) ^ io_dataIn[3]) ^ io_dataIn[4]);
    nextCrc[5] = (((((crc[3] ^ crc[4]) ^ crc[5]) ^ io_dataIn[3]) ^ io_dataIn[4]) ^ io_dataIn[5]);
    nextCrc[6] = (((((crc[4] ^ crc[5]) ^ crc[6]) ^ io_dataIn[4]) ^ io_dataIn[5]) ^ io_dataIn[6]);
    nextCrc[7] = (((((crc[5] ^ crc[6]) ^ crc[7]) ^ io_dataIn[5]) ^ io_dataIn[6]) ^ io_dataIn[7]);
  end

  assign io_crcOut = crc;
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      crc <= 8'h0;
    end else begin
      if(io_clear) begin
        crc <= 8'h0;
      end else begin
        if(io_enable) begin
          crc <= nextCrc;
        end
      end
    end
  end


endmodule
