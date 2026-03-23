// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : Crc7
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module Crc7 (
  input  wire          io_clear,
  input  wire          io_enable,
  input  wire          io_bitIn,
  output wire [6:0]    io_crcOut,
  input  wire          clk,
  input  wire          resetn
);

  reg        [6:0]    crc;
  wire                feedback;

  assign feedback = (crc[6] ^ io_bitIn);
  assign io_crcOut = crc;
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      crc <= 7'h0;
    end else begin
      if(io_clear) begin
        crc <= 7'h0;
      end else begin
        if(io_enable) begin
          crc[6] <= crc[5];
          crc[5] <= crc[4];
          crc[4] <= crc[3];
          crc[3] <= (crc[2] ^ feedback);
          crc[2] <= crc[1];
          crc[1] <= crc[0];
          crc[0] <= feedback;
        end
      end
    end
  end


endmodule
