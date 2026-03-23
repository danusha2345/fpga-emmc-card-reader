// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : SectorBufWr
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module SectorBufWr (
  input  wire [3:0]    io_rdBank,
  input  wire [8:0]    io_rdAddr,
  output wire [7:0]    io_rdData,
  input  wire [3:0]    io_wrBank,
  input  wire [8:0]    io_wrAddr,
  input  wire [7:0]    io_wrData,
  input  wire          io_wrEn,
  input  wire          clk,
  input  wire          resetn
);

  reg        [7:0]    memLo_spinal_port0;
  reg        [7:0]    memHi_spinal_port0;
  wire                _zz_memLo_port;
  wire                _zz_rdDataLo;
  wire                _zz_memLo_port_1;
  wire                _zz_memHi_port;
  wire                _zz_rdDataHi;
  wire                _zz_memHi_port_1;
  wire                halfSelRd;
  wire                halfSelWr;
  wire       [11:0]   halfRdAddr;
  wire       [11:0]   halfWrAddr;
  wire       [7:0]    rdDataLo;
  wire       [7:0]    rdDataHi;
  reg                 halfSelRdR;
  reg [7:0] memLo [0:4095];
  reg [7:0] memHi [0:4095];

  assign _zz_rdDataLo = 1'b1;
  assign _zz_memLo_port_1 = (io_wrEn && (! halfSelWr));
  assign _zz_rdDataHi = 1'b1;
  assign _zz_memHi_port_1 = (io_wrEn && halfSelWr);
  always @(posedge clk) begin
    if(_zz_rdDataLo) begin
      memLo_spinal_port0 <= memLo[halfRdAddr];
    end
  end

  always @(posedge clk) begin
    if(_zz_memLo_port_1) begin
      memLo[halfWrAddr] <= io_wrData;
    end
  end

  always @(posedge clk) begin
    if(_zz_rdDataHi) begin
      memHi_spinal_port0 <= memHi[halfRdAddr];
    end
  end

  always @(posedge clk) begin
    if(_zz_memHi_port_1) begin
      memHi[halfWrAddr] <= io_wrData;
    end
  end

  assign halfSelRd = io_rdBank[3];
  assign halfSelWr = io_wrBank[3];
  assign halfRdAddr = {io_rdBank[2 : 0],io_rdAddr};
  assign halfWrAddr = {io_wrBank[2 : 0],io_wrAddr};
  assign rdDataLo = memLo_spinal_port0;
  assign rdDataHi = memHi_spinal_port0;
  assign io_rdData = (halfSelRdR ? rdDataHi : rdDataLo);
  always @(posedge clk) begin
    halfSelRdR <= halfSelRd;
  end


endmodule
