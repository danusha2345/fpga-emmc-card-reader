// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : UartTx
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module UartTx (
  input  wire [7:0]    io_dataIn,
  input  wire          io_dataValid,
  input  wire [7:0]    io_clksPerBit,
  output wire          io_tx,
  output wire          io_busy,
  input  wire          clk,
  input  wire          resetn
);

  wire       [7:0]    _zz_when_UartTx_l47;
  wire       [7:0]    _zz_when_UartTx_l55;
  wire       [7:0]    _zz_when_UartTx_l68;
  wire       [7:0]    activeCpb;
  wire       [1:0]    sIdle;
  wire       [1:0]    sStart;
  wire       [1:0]    sData;
  wire       [1:0]    sStop;
  reg        [1:0]    state;
  reg        [7:0]    clkCnt;
  reg        [2:0]    bitIdx;
  reg        [7:0]    shiftReg;
  reg                 txReg;
  wire                when_UartTx_l37;
  wire                when_UartTx_l47;
  wire                when_UartTx_l55;
  wire                when_UartTx_l58;
  wire                when_UartTx_l68;
  wire                when_UartTx_l45;
  wire                when_UartTx_l53;
  wire                when_UartTx_l66;

  assign _zz_when_UartTx_l47 = (activeCpb - 8'h01);
  assign _zz_when_UartTx_l55 = (activeCpb - 8'h01);
  assign _zz_when_UartTx_l68 = (activeCpb - 8'h01);
  assign activeCpb = ((io_clksPerBit != 8'h0) ? io_clksPerBit : 8'h14);
  assign sIdle = 2'b00;
  assign sStart = 2'b01;
  assign sData = 2'b10;
  assign sStop = 2'b11;
  assign io_busy = (state != sIdle);
  assign io_tx = txReg;
  assign when_UartTx_l37 = (state == sIdle);
  assign when_UartTx_l47 = (clkCnt == _zz_when_UartTx_l47);
  assign when_UartTx_l55 = (clkCnt == _zz_when_UartTx_l55);
  assign when_UartTx_l58 = (bitIdx == 3'b111);
  assign when_UartTx_l68 = (clkCnt == _zz_when_UartTx_l68);
  assign when_UartTx_l45 = (state == sStart);
  assign when_UartTx_l53 = (state == sData);
  assign when_UartTx_l66 = (state == sStop);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      state <= 2'b00;
      clkCnt <= 8'h0;
      bitIdx <= 3'b000;
      shiftReg <= 8'h0;
      txReg <= 1'b1;
    end else begin
      if(when_UartTx_l37) begin
        txReg <= 1'b1;
        clkCnt <= 8'h0;
        bitIdx <= 3'b000;
        if(io_dataValid) begin
          shiftReg <= io_dataIn;
          state <= sStart;
        end
      end else begin
        if(when_UartTx_l45) begin
          txReg <= 1'b0;
          if(when_UartTx_l47) begin
            clkCnt <= 8'h0;
            state <= sData;
          end else begin
            clkCnt <= (clkCnt + 8'h01);
          end
        end else begin
          if(when_UartTx_l53) begin
            txReg <= shiftReg[0];
            if(when_UartTx_l55) begin
              clkCnt <= 8'h0;
              shiftReg <= {1'b0,shiftReg[7 : 1]};
              if(when_UartTx_l58) begin
                state <= sStop;
              end else begin
                bitIdx <= (bitIdx + 3'b001);
              end
            end else begin
              clkCnt <= (clkCnt + 8'h01);
            end
          end else begin
            if(when_UartTx_l66) begin
              txReg <= 1'b1;
              if(when_UartTx_l68) begin
                clkCnt <= 8'h0;
                state <= sIdle;
              end else begin
                clkCnt <= (clkCnt + 8'h01);
              end
            end
          end
        end
      end
    end
  end


endmodule
