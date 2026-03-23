// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : EmmcCmd
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module EmmcCmd (
  input  wire          io_clkEn,
  input  wire          io_cmdStart,
  input  wire [5:0]    io_cmdIndex,
  input  wire [31:0]   io_cmdArgument,
  input  wire          io_respTypeLong,
  input  wire          io_respExpected,
  output wire          io_cmdDone,
  output wire          io_cmdTimeout,
  output wire          io_cmdCrcErr,
  output wire [31:0]   io_respStatus,
  output wire [127:0]  io_respData,
  output wire          io_cmdOut,
  output wire          io_cmdOe,
  input  wire          io_cmdIn,
  output wire [2:0]    io_dbgState,
  input  wire          clk,
  input  wire          resetn
);

  wire       [6:0]    uCrc7_io_crcOut;
  wire       [2:0]    S_IDLE;
  wire       [2:0]    S_SEND;
  wire       [2:0]    S_WAIT;
  wire       [2:0]    S_RECV;
  wire       [2:0]    S_DONE;
  reg        [2:0]    state;
  reg        [7:0]    bitCnt;
  reg        [47:0]   txShift;
  reg        [135:0]  rxShift;
  reg        [15:0]   timeoutCnt;
  reg                 cmdTimeoutFlag;
  reg                 respLong;
  reg                 respExp;
  reg        [6:0]    crcShift;
  reg                 sendIsDataPhase;
  reg                 sendLatchCrc;
  reg                 sendIsDone;
  reg                 cmdDoneR;
  reg                 cmdTimeoutR;
  reg                 cmdCrcErrR;
  reg        [31:0]   respStatusR;
  reg        [127:0]  respDataR;
  reg                 cmdOutR;
  reg                 cmdOeR;
  reg                 crcClear;
  reg                 crcEn;
  reg                 crcBit;
  wire                when_EmmcCmd_l84;
  wire                when_EmmcCmd_l87;
  wire                when_EmmcCmd_l115;
  wire                when_EmmcCmd_l144;
  wire                when_EmmcCmd_l151;
  wire                when_EmmcCmd_l166;
  wire                when_EmmcCmd_l167;
  wire                when_EmmcCmd_l173;
  wire                when_EmmcCmd_l175;
  wire                when_EmmcCmd_l180;
  wire                when_EmmcCmd_l182;
  wire                when_EmmcCmd_l103;
  wire                when_EmmcCmd_l142;
  wire                when_EmmcCmd_l161;
  wire                when_EmmcCmd_l179;

  Crc7 uCrc7 (
    .io_clear  (crcClear            ), //i
    .io_enable (crcEn               ), //i
    .io_bitIn  (crcBit              ), //i
    .io_crcOut (uCrc7_io_crcOut[6:0]), //o
    .clk       (clk                 ), //i
    .resetn    (resetn              )  //i
  );
  assign S_IDLE = 3'b000;
  assign S_SEND = 3'b001;
  assign S_WAIT = 3'b010;
  assign S_RECV = 3'b011;
  assign S_DONE = 3'b100;
  assign io_dbgState = state;
  assign io_cmdDone = cmdDoneR;
  assign io_cmdTimeout = cmdTimeoutR;
  assign io_cmdCrcErr = cmdCrcErrR;
  assign io_respStatus = respStatusR;
  assign io_respData = respDataR;
  assign io_cmdOut = cmdOutR;
  assign io_cmdOe = cmdOeR;
  assign when_EmmcCmd_l84 = (state == S_IDLE);
  assign when_EmmcCmd_l87 = (io_cmdStart && (! cmdDoneR));
  assign when_EmmcCmd_l115 = (! sendIsDone);
  assign when_EmmcCmd_l144 = (! io_cmdIn);
  assign when_EmmcCmd_l151 = (timeoutCnt == 16'h03ff);
  assign when_EmmcCmd_l166 = (! respLong);
  assign when_EmmcCmd_l167 = ((8'h01 <= bitCnt) && (bitCnt <= 8'h27));
  assign when_EmmcCmd_l173 = ((! respLong) && (bitCnt == 8'h2f));
  assign when_EmmcCmd_l175 = (respLong && (bitCnt == 8'h87));
  assign when_EmmcCmd_l180 = ((! respLong) && respExp);
  assign when_EmmcCmd_l182 = (uCrc7_io_crcOut != rxShift[7 : 1]);
  assign when_EmmcCmd_l103 = (state == S_SEND);
  assign when_EmmcCmd_l142 = (state == S_WAIT);
  assign when_EmmcCmd_l161 = (state == S_RECV);
  assign when_EmmcCmd_l179 = (state == S_DONE);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      state <= 3'b000;
      bitCnt <= 8'h0;
      txShift <= 48'h0;
      rxShift <= 136'h0;
      timeoutCnt <= 16'h0;
      cmdTimeoutFlag <= 1'b0;
      respLong <= 1'b0;
      respExp <= 1'b0;
      crcShift <= 7'h0;
      sendIsDataPhase <= 1'b0;
      sendLatchCrc <= 1'b0;
      sendIsDone <= 1'b0;
      cmdDoneR <= 1'b0;
      cmdTimeoutR <= 1'b0;
      cmdCrcErrR <= 1'b0;
      respStatusR <= 32'h0;
      respDataR <= 128'h0;
      cmdOutR <= 1'b1;
      cmdOeR <= 1'b0;
      crcClear <= 1'b1;
      crcEn <= 1'b0;
      crcBit <= 1'b0;
    end else begin
      cmdDoneR <= 1'b0;
      cmdTimeoutR <= 1'b0;
      cmdCrcErrR <= 1'b0;
      crcClear <= 1'b0;
      crcEn <= 1'b0;
      if(when_EmmcCmd_l84) begin
        cmdOeR <= 1'b0;
        cmdOutR <= 1'b1;
        if(when_EmmcCmd_l87) begin
          txShift[47] <= 1'b0;
          txShift[46] <= 1'b1;
          txShift[45 : 40] <= io_cmdIndex;
          txShift[39 : 8] <= io_cmdArgument;
          txShift[7 : 1] <= 7'h0;
          txShift[0] <= 1'b1;
          respLong <= io_respTypeLong;
          respExp <= io_respExpected;
          bitCnt <= 8'h0;
          crcClear <= 1'b1;
          sendIsDataPhase <= 1'b1;
          sendLatchCrc <= 1'b0;
          sendIsDone <= 1'b0;
          state <= S_SEND;
        end
      end else begin
        if(when_EmmcCmd_l103) begin
          if(io_clkEn) begin
            cmdOeR <= 1'b1;
            if(sendIsDataPhase) begin
              cmdOutR <= txShift[47];
              txShift <= {txShift[46 : 0],1'b0};
              crcEn <= 1'b1;
              crcBit <= txShift[47];
            end else begin
              if(sendLatchCrc) begin
                cmdOutR <= uCrc7_io_crcOut[6];
                crcShift <= {uCrc7_io_crcOut[5 : 0],1'b0};
              end else begin
                if(when_EmmcCmd_l115) begin
                  cmdOutR <= crcShift[6];
                  crcShift <= {crcShift[5 : 0],1'b0};
                end else begin
                  cmdOutR <= 1'b1;
                end
              end
            end
            bitCnt <= (bitCnt + 8'h01);
            sendIsDataPhase <= (bitCnt < 8'h27);
            sendLatchCrc <= (bitCnt == 8'h27);
            sendIsDone <= (8'h2e <= bitCnt);
            if(sendIsDone) begin
              cmdOeR <= 1'b0;
              cmdOutR <= 1'b1;
              if(respExp) begin
                bitCnt <= 8'h0;
                timeoutCnt <= 16'h0;
                cmdTimeoutFlag <= 1'b0;
                crcClear <= 1'b1;
                state <= S_WAIT;
              end else begin
                state <= S_DONE;
              end
            end
          end
        end else begin
          if(when_EmmcCmd_l142) begin
            if(io_clkEn) begin
              if(when_EmmcCmd_l144) begin
                rxShift <= 136'h0;
                rxShift[135] <= 1'b0;
                bitCnt <= 8'h01;
                state <= S_RECV;
              end else begin
                timeoutCnt <= (timeoutCnt + 16'h0001);
                if(when_EmmcCmd_l151) begin
                  cmdTimeoutFlag <= 1'b1;
                end
                if(cmdTimeoutFlag) begin
                  cmdTimeoutR <= 1'b1;
                  cmdDoneR <= 1'b1;
                  state <= S_IDLE;
                end
              end
            end
          end else begin
            if(when_EmmcCmd_l161) begin
              if(io_clkEn) begin
                rxShift <= {rxShift[134 : 0],io_cmdIn};
                bitCnt <= (bitCnt + 8'h01);
                if(when_EmmcCmd_l166) begin
                  if(when_EmmcCmd_l167) begin
                    crcEn <= 1'b1;
                    crcBit <= io_cmdIn;
                  end
                end
                if(when_EmmcCmd_l173) begin
                  state <= S_DONE;
                end else begin
                  if(when_EmmcCmd_l175) begin
                    state <= S_DONE;
                  end
                end
              end
            end else begin
              if(when_EmmcCmd_l179) begin
                if(when_EmmcCmd_l180) begin
                  respStatusR <= rxShift[39 : 8];
                  if(when_EmmcCmd_l182) begin
                    cmdCrcErrR <= 1'b1;
                  end
                end else begin
                  if(respLong) begin
                    respDataR <= rxShift[127 : 0];
                  end
                end
                cmdDoneR <= 1'b1;
                state <= S_IDLE;
              end
            end
          end
        end
      end
    end
  end


endmodule

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
