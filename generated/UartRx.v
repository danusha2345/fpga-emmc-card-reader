// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : UartRx
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module UartRx (
  input  wire          io_rx,
  input  wire [7:0]    io_clksPerBit,
  output wire [7:0]    io_dataOut,
  output wire          io_dataValid,
  output wire          io_frameErr,
  input  wire          clk,
  input  wire          resetn
);

  wire       [7:0]    _zz_when_UartRx_l59;
  wire       [7:0]    _zz_when_UartRx_l70;
  wire       [7:0]    _zz_when_UartRx_l82;
  wire       [7:0]    activeCpb;
  wire       [7:0]    halfCpb;
  wire       [1:0]    sIdle;
  wire       [1:0]    sStart;
  wire       [1:0]    sData;
  wire       [1:0]    sStop;
  reg                 rxSync1;
  reg                 rxSync2;
  reg        [1:0]    state;
  reg        [7:0]    clkCnt;
  reg        [2:0]    bitIdx;
  reg        [7:0]    shiftReg;
  reg        [7:0]    dataOut;
  reg                 dataValid;
  reg                 frameErr;
  wire                when_UartRx_l52;
  wire                when_UartRx_l55;
  wire                when_UartRx_l59;
  wire                when_UartRx_l61;
  wire                when_UartRx_l70;
  wire                when_UartRx_l73;
  wire                when_UartRx_l82;
  wire                when_UartRx_l58;
  wire                when_UartRx_l69;
  wire                when_UartRx_l81;

  assign _zz_when_UartRx_l59 = (halfCpb - 8'h01);
  assign _zz_when_UartRx_l70 = (activeCpb - 8'h01);
  assign _zz_when_UartRx_l82 = (activeCpb - 8'h01);
  assign activeCpb = ((io_clksPerBit != 8'h0) ? io_clksPerBit : 8'h14);
  assign halfCpb = (activeCpb >>> 1);
  assign sIdle = 2'b00;
  assign sStart = 2'b01;
  assign sData = 2'b10;
  assign sStop = 2'b11;
  assign io_dataOut = dataOut;
  assign io_dataValid = dataValid;
  assign io_frameErr = frameErr;
  assign when_UartRx_l52 = (state == sIdle);
  assign when_UartRx_l55 = (! rxSync2);
  assign when_UartRx_l59 = (clkCnt == _zz_when_UartRx_l59);
  assign when_UartRx_l61 = (! rxSync2);
  assign when_UartRx_l70 = (clkCnt == _zz_when_UartRx_l70);
  assign when_UartRx_l73 = (bitIdx == 3'b111);
  assign when_UartRx_l82 = (clkCnt == _zz_when_UartRx_l82);
  assign when_UartRx_l58 = (state == sStart);
  assign when_UartRx_l69 = (state == sData);
  assign when_UartRx_l81 = (state == sStop);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      rxSync1 <= 1'b1;
      rxSync2 <= 1'b1;
      state <= 2'b00;
      clkCnt <= 8'h0;
      bitIdx <= 3'b000;
      shiftReg <= 8'h0;
      dataOut <= 8'h0;
      dataValid <= 1'b0;
      frameErr <= 1'b0;
    end else begin
      rxSync1 <= io_rx;
      rxSync2 <= rxSync1;
      dataValid <= 1'b0;
      frameErr <= 1'b0;
      if(when_UartRx_l52) begin
        clkCnt <= 8'h0;
        bitIdx <= 3'b000;
        if(when_UartRx_l55) begin
          state <= sStart;
        end
      end else begin
        if(when_UartRx_l58) begin
          if(when_UartRx_l59) begin
            clkCnt <= 8'h0;
            if(when_UartRx_l61) begin
              state <= sData;
            end else begin
              state <= sIdle;
            end
          end else begin
            clkCnt <= (clkCnt + 8'h01);
          end
        end else begin
          if(when_UartRx_l69) begin
            if(when_UartRx_l70) begin
              clkCnt <= 8'h0;
              shiftReg <= {rxSync2,shiftReg[7 : 1]};
              if(when_UartRx_l73) begin
                state <= sStop;
              end else begin
                bitIdx <= (bitIdx + 3'b001);
              end
            end else begin
              clkCnt <= (clkCnt + 8'h01);
            end
          end else begin
            if(when_UartRx_l81) begin
              if(when_UartRx_l82) begin
                clkCnt <= 8'h0;
                if(rxSync2) begin
                  dataOut <= shiftReg;
                  dataValid <= 1'b1;
                end else begin
                  frameErr <= 1'b1;
                end
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
