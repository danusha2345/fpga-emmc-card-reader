// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : SectorBuf
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module SectorBuf (
  input  wire [1:0]    io_bufSelA,
  input  wire [8:0]    io_addrA,
  input  wire [7:0]    io_wdataA,
  input  wire          io_weA,
  output wire [7:0]    io_rdataA,
  input  wire [1:0]    io_bufSelB,
  input  wire [8:0]    io_addrB,
  input  wire [7:0]    io_wdataB,
  input  wire          io_weB,
  output wire [7:0]    io_rdataB,
  input  wire          clk,
  input  wire          resetn
);

  reg        [7:0]    mem_spinal_port0;
  reg        [7:0]    mem_spinal_port1;
  wire                _zz_mem_port;
  wire                _zz_io_rdataA_1;
  wire                _zz_mem_port_1;
  wire                _zz_io_rdataB_1;
  wire       [9:0]    fullAddrA;
  wire       [9:0]    fullAddrB;
  wire       [7:0]    _zz_io_rdataA;
  wire       [7:0]    _zz_io_rdataB;
  reg [7:0] mem [0:1023];

  assign _zz_io_rdataA_1 = 1'b1;
  assign _zz_io_rdataB_1 = 1'b1;
  always @(posedge clk) begin
    if(_zz_io_rdataA_1) begin
      mem_spinal_port0 <= mem[fullAddrA];
    end
  end

  always @(posedge clk) begin
    if(_zz_io_rdataA_1 && io_weA ) begin
      mem[fullAddrA] <= _zz_io_rdataA;
    end
  end

  always @(posedge clk) begin
    if(_zz_io_rdataB_1) begin
      mem_spinal_port1 <= mem[fullAddrB];
    end
  end

  always @(posedge clk) begin
    if(_zz_io_rdataB_1 && io_weB ) begin
      mem[fullAddrB] <= _zz_io_rdataB;
    end
  end

  assign fullAddrA = {io_bufSelA[0],io_addrA};
  assign fullAddrB = {io_bufSelB[0],io_addrB};
  assign _zz_io_rdataA = io_wdataA;
  assign io_rdataA = mem_spinal_port0;
  assign _zz_io_rdataB = io_wdataB;
  assign io_rdataB = mem_spinal_port1;

endmodule
