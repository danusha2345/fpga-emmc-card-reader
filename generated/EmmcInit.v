// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : EmmcInit
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module EmmcInit (
  input  wire          io_initStart,
  output wire          io_initDone,
  output wire          io_initError,
  output wire [3:0]    io_initStateDbg,
  output wire          io_cmdStart,
  output wire [5:0]    io_cmdIndex,
  output wire [31:0]   io_cmdArgument,
  output wire          io_respTypeLong,
  output wire          io_respExpected,
  input  wire          io_cmdDone,
  input  wire          io_cmdTimeout,
  input  wire          io_cmdCrcErr,
  input  wire [31:0]   io_respStatus,
  input  wire [127:0]  io_respData,
  output wire [127:0]  io_cidReg,
  output wire [127:0]  io_csdReg,
  output wire [15:0]   io_rcaReg,
  output wire          io_infoValid,
  output wire          io_useFastClk,
  output wire          io_emmcRstnOut,
  output wire [7:0]    io_dbgRetryCnt,
  input  wire          clk,
  input  wire          resetn
);

  wire       [3:0]    SI_IDLE;
  wire       [3:0]    SI_RESET_LOW;
  wire       [3:0]    SI_RESET_HIGH;
  wire       [3:0]    SI_CMD0;
  wire       [3:0]    SI_CMD1;
  wire       [3:0]    SI_CMD1_WAIT;
  wire       [3:0]    SI_CMD2;
  wire       [3:0]    SI_CMD3;
  wire       [3:0]    SI_CMD9;
  wire       [3:0]    SI_CMD7;
  wire       [3:0]    SI_CMD16;
  wire       [3:0]    SI_DONE;
  wire       [3:0]    SI_ERROR;
  wire       [3:0]    SI_WAIT_CMD;
  wire       [3:0]    SI_CMD7_WAIT;
  reg        [3:0]    state;
  reg        [3:0]    nextState;
  reg        [23:0]   waitCnt;
  reg                 waitCntZero;
  reg        [15:0]   retryCnt;
  wire                waitingCmd;
  reg                 isSectorMode;
  reg                 initDoneR;
  reg                 initErrorR;
  reg                 initStartR;
  reg                 cmdStartR;
  reg        [5:0]    cmdIndexR;
  reg        [31:0]   cmdArgumentR;
  reg                 respTypeLongR;
  reg                 respExpectedR;
  reg        [127:0]  cidRegR;
  reg        [127:0]  csdRegR;
  wire       [15:0]   rcaRegR;
  reg                 infoValidR;
  reg                 useFastClkR;
  reg                 emmcRstnOutR;
  wire                when_EmmcInit_l100;
  wire                when_EmmcInit_l145;
  wire                when_EmmcInit_l150;
  wire                when_EmmcInit_l210;
  wire                when_EmmcInit_l212;
  wire                when_EmmcInit_l220;
  wire                when_EmmcInit_l111;
  wire                when_EmmcInit_l120;
  wire                when_EmmcInit_l126;
  wire                when_EmmcInit_l136;
  wire                when_EmmcInit_l144;
  wire                when_EmmcInit_l157;
  wire                when_EmmcInit_l165;
  wire                when_EmmcInit_l174;
  wire                when_EmmcInit_l182;
  wire                when_EmmcInit_l193;
  wire                when_EmmcInit_l199;
  wire                when_EmmcInit_l207;
  wire                when_EmmcInit_l226;
  wire                when_EmmcInit_l231;

  assign SI_IDLE = 4'b0000;
  assign SI_RESET_LOW = 4'b0001;
  assign SI_RESET_HIGH = 4'b0010;
  assign SI_CMD0 = 4'b0011;
  assign SI_CMD1 = 4'b0100;
  assign SI_CMD1_WAIT = 4'b0101;
  assign SI_CMD2 = 4'b0110;
  assign SI_CMD3 = 4'b0111;
  assign SI_CMD9 = 4'b1000;
  assign SI_CMD7 = 4'b1001;
  assign SI_CMD16 = 4'b1011;
  assign SI_DONE = 4'b1100;
  assign SI_ERROR = 4'b1101;
  assign SI_WAIT_CMD = 4'b1110;
  assign SI_CMD7_WAIT = 4'b1111;
  assign waitingCmd = 1'b0;
  assign rcaRegR = 16'h0001;
  assign io_initDone = initDoneR;
  assign io_initError = initErrorR;
  assign io_initStateDbg = state;
  assign io_cmdStart = cmdStartR;
  assign io_cmdIndex = cmdIndexR;
  assign io_cmdArgument = cmdArgumentR;
  assign io_respTypeLong = respTypeLongR;
  assign io_respExpected = respExpectedR;
  assign io_cidReg = cidRegR;
  assign io_csdReg = csdRegR;
  assign io_rcaReg = rcaRegR;
  assign io_infoValid = infoValidR;
  assign io_useFastClk = useFastClkR;
  assign io_emmcRstnOut = emmcRstnOutR;
  assign io_dbgRetryCnt = ((16'h00ff < retryCnt) ? 8'hff : retryCnt[7 : 0]);
  assign when_EmmcInit_l100 = (state == SI_IDLE);
  assign when_EmmcInit_l145 = io_respStatus[31];
  assign when_EmmcInit_l150 = (16'h0578 <= retryCnt);
  assign when_EmmcInit_l210 = (nextState == SI_CMD1_WAIT);
  assign when_EmmcInit_l212 = (16'h0578 <= retryCnt);
  assign when_EmmcInit_l220 = (io_cmdCrcErr && (nextState != SI_CMD1_WAIT));
  assign when_EmmcInit_l111 = (state == SI_RESET_LOW);
  assign when_EmmcInit_l120 = (state == SI_RESET_HIGH);
  assign when_EmmcInit_l126 = (state == SI_CMD0);
  assign when_EmmcInit_l136 = (state == SI_CMD1);
  assign when_EmmcInit_l144 = (state == SI_CMD1_WAIT);
  assign when_EmmcInit_l157 = (state == SI_CMD2);
  assign when_EmmcInit_l165 = (state == SI_CMD3);
  assign when_EmmcInit_l174 = (state == SI_CMD9);
  assign when_EmmcInit_l182 = (state == SI_CMD7);
  assign when_EmmcInit_l193 = (state == SI_CMD7_WAIT);
  assign when_EmmcInit_l199 = (state == SI_CMD16);
  assign when_EmmcInit_l207 = (state == SI_WAIT_CMD);
  assign when_EmmcInit_l226 = (state == SI_DONE);
  assign when_EmmcInit_l231 = (state == SI_ERROR);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      state <= 4'b0000;
      nextState <= 4'b0000;
      waitCnt <= 24'h0;
      waitCntZero <= 1'b1;
      retryCnt <= 16'h0;
      isSectorMode <= 1'b0;
      initDoneR <= 1'b0;
      initErrorR <= 1'b0;
      initStartR <= 1'b0;
      cmdStartR <= 1'b0;
      cmdIndexR <= 6'h0;
      cmdArgumentR <= 32'h0;
      respTypeLongR <= 1'b0;
      respExpectedR <= 1'b0;
      cidRegR <= 128'h0;
      csdRegR <= 128'h0;
      infoValidR <= 1'b0;
      useFastClkR <= 1'b0;
      emmcRstnOutR <= 1'b0;
    end else begin
      cmdStartR <= 1'b0;
      initStartR <= io_initStart;
      if(when_EmmcInit_l100) begin
        initDoneR <= 1'b0;
        initErrorR <= 1'b0;
        if(initStartR) begin
          infoValidR <= 1'b0;
          useFastClkR <= 1'b0;
          emmcRstnOutR <= 1'b0;
          waitCnt <= 24'h00ea60;
          waitCntZero <= 1'b0;
          state <= SI_RESET_LOW;
        end
      end else begin
        if(when_EmmcInit_l111) begin
          waitCnt <= (waitCnt - 24'h000001);
          waitCntZero <= (waitCnt == 24'h000001);
          if(waitCntZero) begin
            emmcRstnOutR <= 1'b1;
            waitCnt <= 24'h2dc6c0;
            waitCntZero <= 1'b0;
            state <= SI_RESET_HIGH;
          end
        end else begin
          if(when_EmmcInit_l120) begin
            waitCnt <= (waitCnt - 24'h000001);
            waitCntZero <= (waitCnt == 24'h000001);
            if(waitCntZero) begin
              state <= SI_CMD0;
            end
          end else begin
            if(when_EmmcInit_l126) begin
              cmdIndexR <= 6'h0;
              cmdArgumentR <= 32'h0;
              respTypeLongR <= 1'b0;
              respExpectedR <= 1'b0;
              cmdStartR <= 1'b1;
              nextState <= SI_CMD1;
              retryCnt <= 16'h0;
              waitCnt <= 24'h0;
              state <= SI_WAIT_CMD;
            end else begin
              if(when_EmmcInit_l136) begin
                cmdIndexR <= 6'h01;
                cmdArgumentR <= 32'h40ff8080;
                respTypeLongR <= 1'b0;
                respExpectedR <= 1'b1;
                cmdStartR <= 1'b1;
                nextState <= SI_CMD1_WAIT;
                state <= SI_WAIT_CMD;
              end else begin
                if(when_EmmcInit_l144) begin
                  if(when_EmmcInit_l145) begin
                    isSectorMode <= io_respStatus[30];
                    state <= SI_CMD2;
                  end else begin
                    retryCnt <= (retryCnt + 16'h0001);
                    if(when_EmmcInit_l150) begin
                      state <= SI_ERROR;
                    end else begin
                      waitCnt <= 24'h0;
                      state <= SI_CMD1;
                    end
                  end
                end else begin
                  if(when_EmmcInit_l157) begin
                    cmdIndexR <= 6'h02;
                    cmdArgumentR <= 32'h0;
                    respTypeLongR <= 1'b1;
                    respExpectedR <= 1'b1;
                    cmdStartR <= 1'b1;
                    nextState <= SI_CMD3;
                    state <= SI_WAIT_CMD;
                  end else begin
                    if(when_EmmcInit_l165) begin
                      cidRegR <= io_respData;
                      cmdIndexR <= 6'h03;
                      cmdArgumentR <= {rcaRegR,16'h0};
                      respTypeLongR <= 1'b0;
                      respExpectedR <= 1'b1;
                      cmdStartR <= 1'b1;
                      nextState <= SI_CMD9;
                      state <= SI_WAIT_CMD;
                    end else begin
                      if(when_EmmcInit_l174) begin
                        cmdIndexR <= 6'h09;
                        cmdArgumentR <= {rcaRegR,16'h0};
                        respTypeLongR <= 1'b1;
                        respExpectedR <= 1'b1;
                        cmdStartR <= 1'b1;
                        nextState <= SI_CMD7;
                        state <= SI_WAIT_CMD;
                      end else begin
                        if(when_EmmcInit_l182) begin
                          csdRegR <= io_respData;
                          cmdIndexR <= 6'h07;
                          cmdArgumentR <= {rcaRegR,16'h0};
                          respTypeLongR <= 1'b0;
                          respExpectedR <= 1'b1;
                          cmdStartR <= 1'b1;
                          waitCnt <= 24'h00ea60;
                          waitCntZero <= 1'b0;
                          nextState <= SI_CMD7_WAIT;
                          state <= SI_WAIT_CMD;
                        end else begin
                          if(when_EmmcInit_l193) begin
                            waitCnt <= (waitCnt - 24'h000001);
                            waitCntZero <= (waitCnt == 24'h000001);
                            if(waitCntZero) begin
                              state <= (isSectorMode ? SI_DONE : SI_CMD16);
                            end
                          end else begin
                            if(when_EmmcInit_l199) begin
                              cmdIndexR <= 6'h10;
                              cmdArgumentR <= 32'h00000200;
                              respTypeLongR <= 1'b0;
                              respExpectedR <= 1'b1;
                              cmdStartR <= 1'b1;
                              nextState <= SI_DONE;
                              state <= SI_WAIT_CMD;
                            end else begin
                              if(when_EmmcInit_l207) begin
                                if(io_cmdDone) begin
                                  if(io_cmdTimeout) begin
                                    if(when_EmmcInit_l210) begin
                                      retryCnt <= (retryCnt + 16'h0001);
                                      if(when_EmmcInit_l212) begin
                                        state <= SI_ERROR;
                                      end else begin
                                        state <= SI_CMD1;
                                      end
                                    end else begin
                                      state <= SI_ERROR;
                                    end
                                  end else begin
                                    if(when_EmmcInit_l220) begin
                                      state <= SI_ERROR;
                                    end else begin
                                      state <= nextState;
                                    end
                                  end
                                end
                              end else begin
                                if(when_EmmcInit_l226) begin
                                  infoValidR <= 1'b1;
                                  initDoneR <= 1'b1;
                                  useFastClkR <= 1'b1;
                                  state <= SI_IDLE;
                                end else begin
                                  if(when_EmmcInit_l231) begin
                                    initErrorR <= 1'b1;
                                    state <= SI_IDLE;
                                  end
                                end
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end


endmodule
