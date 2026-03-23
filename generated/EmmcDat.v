// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : EmmcDat
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module EmmcDat (
  input  wire          io_clkEn,
  input  wire          io_rdStart,
  output wire          io_rdDone,
  output wire          io_rdCrcErr,
  input  wire          io_wrStart,
  output wire          io_wrDone,
  output wire          io_wrCrcErr,
  output wire [7:0]    io_bufWrData,
  output wire [8:0]    io_bufWrAddr,
  output wire          io_bufWrEn,
  output wire [8:0]    io_bufRdAddr,
  input  wire [7:0]    io_bufRdData,
  output wire [3:0]    io_datOut,
  output wire          io_datOe,
  input  wire [3:0]    io_datIn,
  input  wire          io_busWidth4,
  output wire [3:0]    io_dbgState,
  input  wire          clk,
  input  wire          resetn
);

  wire                rdCrcs_0_io_bitIn;
  wire                rdCrcs_1_io_bitIn;
  wire                rdCrcs_2_io_bitIn;
  wire                rdCrcs_3_io_bitIn;
  wire                wrCrcs_0_io_bitIn;
  wire                wrCrcs_1_io_bitIn;
  wire                wrCrcs_2_io_bitIn;
  wire                wrCrcs_3_io_bitIn;
  wire       [15:0]   rdCrcs_0_io_crcOut;
  wire       [15:0]   rdCrcs_1_io_crcOut;
  wire       [15:0]   rdCrcs_2_io_crcOut;
  wire       [15:0]   rdCrcs_3_io_crcOut;
  wire       [15:0]   wrCrcs_0_io_crcOut;
  wire       [15:0]   wrCrcs_1_io_crcOut;
  wire       [15:0]   wrCrcs_2_io_crcOut;
  wire       [15:0]   wrCrcs_3_io_crcOut;
  wire       [3:0]    S_IDLE;
  wire       [3:0]    S_RD_WAIT_START;
  wire       [3:0]    S_RD_DATA;
  wire       [3:0]    S_RD_CRC;
  wire       [3:0]    S_RD_END;
  wire       [3:0]    S_WR_PREFETCH;
  wire       [3:0]    S_WR_START;
  wire       [3:0]    S_WR_DATA;
  wire       [3:0]    S_WR_CRC;
  wire       [3:0]    S_WR_END;
  wire       [3:0]    S_WR_CRC_STAT;
  wire       [3:0]    S_WR_BUSY;
  wire       [3:0]    S_WR_CRC_WAIT;
  wire       [3:0]    S_WR_PREFETCH2;
  reg        [3:0]    state;
  reg        [12:0]   bitCnt;
  reg        [15:0]   timeoutCnt;
  reg                 timeoutFlag;
  reg        [7:0]    byteAcc;
  reg        [2:0]    bitInByte;
  reg                 byteComplete;
  reg        [7:0]    wrByteReg;
  reg        [2:0]    wrBitIdx;
  reg                 rdDoneR;
  reg                 rdCrcErrR;
  reg                 wrDoneR;
  reg                 wrCrcErrR;
  reg        [7:0]    bufWrDataR;
  reg        [8:0]    bufWrAddrR;
  reg                 bufWrEnR;
  reg        [8:0]    bufRdAddrR;
  reg        [3:0]    datOutR;
  reg                 datOeR;
  reg                 nibblePhase;
  reg                 rdCrcClear;
  reg                 rdCrcEn;
  reg        [15:0]   crcRecvArr_0;
  reg        [15:0]   crcRecvArr_1;
  reg        [15:0]   crcRecvArr_2;
  reg        [15:0]   crcRecvArr_3;
  reg        [15:0]   crcRecv;
  reg                 wrCrcClear;
  reg                 wrCrcEn;
  reg        [3:0]    wrCrcBit;
  reg        [15:0]   wrCrcShiftArr_0;
  reg        [15:0]   wrCrcShiftArr_1;
  reg        [15:0]   wrCrcShiftArr_2;
  reg        [15:0]   wrCrcShiftArr_3;
  reg        [15:0]   wrCrcShift;
  reg        [2:0]    crcStatusReg;
  reg        [2:0]    crcStatusCnt;
  wire                when_EmmcDat_l141;
  wire                when_EmmcDat_l159;
  wire                when_EmmcDat_l168;
  wire                when_EmmcDat_l185;
  wire                when_EmmcDat_l206;
  wire                when_EmmcDat_l223;
  wire                when_EmmcDat_l243;
  wire                when_EmmcDat_l253;
  wire                when_EmmcDat_l257;
  wire                when_EmmcDat_l289;
  wire                when_EmmcDat_l306;
  wire                when_EmmcDat_l318;
  wire                when_EmmcDat_l328;
  wire                when_EmmcDat_l336;
  wire                when_EmmcDat_l366;
  wire                when_EmmcDat_l385;
  wire                when_EmmcDat_l391;
  wire                when_EmmcDat_l400;
  wire                when_EmmcDat_l387;
  wire                when_EmmcDat_l390;
  wire                when_EmmcDat_l414;
  wire                when_EmmcDat_l421;
  wire                when_EmmcDat_l416;
  wire                when_EmmcDat_l156;
  wire                when_EmmcDat_l179;
  wire                when_EmmcDat_l231;
  wire                when_EmmcDat_l248;
  wire                when_EmmcDat_l265;
  wire                when_EmmcDat_l268;
  wire                when_EmmcDat_l273;
  wire                when_EmmcDat_l283;
  wire                when_EmmcDat_l335;
  wire                when_EmmcDat_l348;
  wire                when_EmmcDat_l371;
  wire                when_EmmcDat_l382;
  wire                when_EmmcDat_l411;

  Crc16 rdCrcs_0 (
    .io_clear  (rdCrcClear              ), //i
    .io_enable (rdCrcEn                 ), //i
    .io_bitIn  (rdCrcs_0_io_bitIn       ), //i
    .io_crcOut (rdCrcs_0_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 rdCrcs_1 (
    .io_clear  (rdCrcClear              ), //i
    .io_enable (rdCrcEn                 ), //i
    .io_bitIn  (rdCrcs_1_io_bitIn       ), //i
    .io_crcOut (rdCrcs_1_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 rdCrcs_2 (
    .io_clear  (rdCrcClear              ), //i
    .io_enable (rdCrcEn                 ), //i
    .io_bitIn  (rdCrcs_2_io_bitIn       ), //i
    .io_crcOut (rdCrcs_2_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 rdCrcs_3 (
    .io_clear  (rdCrcClear              ), //i
    .io_enable (rdCrcEn                 ), //i
    .io_bitIn  (rdCrcs_3_io_bitIn       ), //i
    .io_crcOut (rdCrcs_3_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 wrCrcs_0 (
    .io_clear  (wrCrcClear              ), //i
    .io_enable (wrCrcEn                 ), //i
    .io_bitIn  (wrCrcs_0_io_bitIn       ), //i
    .io_crcOut (wrCrcs_0_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 wrCrcs_1 (
    .io_clear  (wrCrcClear              ), //i
    .io_enable (wrCrcEn                 ), //i
    .io_bitIn  (wrCrcs_1_io_bitIn       ), //i
    .io_crcOut (wrCrcs_1_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 wrCrcs_2 (
    .io_clear  (wrCrcClear              ), //i
    .io_enable (wrCrcEn                 ), //i
    .io_bitIn  (wrCrcs_2_io_bitIn       ), //i
    .io_crcOut (wrCrcs_2_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  Crc16 wrCrcs_3 (
    .io_clear  (wrCrcClear              ), //i
    .io_enable (wrCrcEn                 ), //i
    .io_bitIn  (wrCrcs_3_io_bitIn       ), //i
    .io_crcOut (wrCrcs_3_io_crcOut[15:0]), //o
    .clk       (clk                     ), //i
    .resetn    (resetn                  )  //i
  );
  assign S_IDLE = 4'b0000;
  assign S_RD_WAIT_START = 4'b0001;
  assign S_RD_DATA = 4'b0010;
  assign S_RD_CRC = 4'b0011;
  assign S_RD_END = 4'b0100;
  assign S_WR_PREFETCH = 4'b0101;
  assign S_WR_START = 4'b0110;
  assign S_WR_DATA = 4'b0111;
  assign S_WR_CRC = 4'b1000;
  assign S_WR_END = 4'b1001;
  assign S_WR_CRC_STAT = 4'b1010;
  assign S_WR_BUSY = 4'b1011;
  assign S_WR_CRC_WAIT = 4'b1100;
  assign S_WR_PREFETCH2 = 4'b1101;
  assign io_dbgState = state;
  assign io_rdDone = rdDoneR;
  assign io_rdCrcErr = rdCrcErrR;
  assign io_wrDone = wrDoneR;
  assign io_wrCrcErr = wrCrcErrR;
  assign io_bufWrData = bufWrDataR;
  assign io_bufWrAddr = bufWrAddrR;
  assign io_bufWrEn = bufWrEnR;
  assign io_bufRdAddr = bufRdAddrR;
  assign io_datOut = datOutR;
  assign io_datOe = datOeR;
  assign rdCrcs_0_io_bitIn = io_datIn[0];
  assign rdCrcs_1_io_bitIn = io_datIn[1];
  assign rdCrcs_2_io_bitIn = io_datIn[2];
  assign rdCrcs_3_io_bitIn = io_datIn[3];
  assign wrCrcs_0_io_bitIn = wrCrcBit[0];
  assign wrCrcs_1_io_bitIn = wrCrcBit[1];
  assign wrCrcs_2_io_bitIn = wrCrcBit[2];
  assign wrCrcs_3_io_bitIn = wrCrcBit[3];
  assign when_EmmcDat_l141 = (state == S_IDLE);
  assign when_EmmcDat_l159 = (! io_datIn[0]);
  assign when_EmmcDat_l168 = (timeoutCnt == 16'hfffe);
  assign when_EmmcDat_l185 = (! nibblePhase);
  assign when_EmmcDat_l206 = (bitCnt == 13'h03ff);
  assign when_EmmcDat_l223 = (bitCnt == 13'h0fff);
  assign when_EmmcDat_l243 = (bitCnt == 13'h000f);
  assign when_EmmcDat_l253 = ((((crcRecvArr_0 != rdCrcs_0_io_crcOut) || (crcRecvArr_1 != rdCrcs_1_io_crcOut)) || (crcRecvArr_2 != rdCrcs_2_io_crcOut)) || (crcRecvArr_3 != rdCrcs_3_io_crcOut));
  assign when_EmmcDat_l257 = (crcRecv != rdCrcs_0_io_crcOut);
  assign when_EmmcDat_l289 = (! nibblePhase);
  assign when_EmmcDat_l306 = (bitCnt == 13'h03ff);
  assign when_EmmcDat_l318 = (wrBitIdx == 3'b000);
  assign when_EmmcDat_l328 = (bitCnt == 13'h0fff);
  assign when_EmmcDat_l336 = bitCnt[0];
  assign when_EmmcDat_l366 = (bitCnt == 13'h000f);
  assign when_EmmcDat_l385 = ((! io_datIn[0]) && (crcStatusCnt == 3'b000));
  assign when_EmmcDat_l391 = (crcStatusReg == 3'b010);
  assign when_EmmcDat_l400 = (timeoutCnt == 16'hfffe);
  assign when_EmmcDat_l387 = ((3'b001 <= crcStatusCnt) && (crcStatusCnt <= 3'b011));
  assign when_EmmcDat_l390 = (3'b011 < crcStatusCnt);
  assign when_EmmcDat_l414 = (crcStatusCnt < 3'b111);
  assign when_EmmcDat_l421 = (timeoutCnt == 16'hfffe);
  assign when_EmmcDat_l416 = io_datIn[0];
  assign when_EmmcDat_l156 = (state == S_RD_WAIT_START);
  assign when_EmmcDat_l179 = (state == S_RD_DATA);
  assign when_EmmcDat_l231 = (state == S_RD_CRC);
  assign when_EmmcDat_l248 = (state == S_RD_END);
  assign when_EmmcDat_l265 = (state == S_WR_PREFETCH);
  assign when_EmmcDat_l268 = (state == S_WR_PREFETCH2);
  assign when_EmmcDat_l273 = (state == S_WR_START);
  assign when_EmmcDat_l283 = (state == S_WR_DATA);
  assign when_EmmcDat_l335 = (state == S_WR_CRC_WAIT);
  assign when_EmmcDat_l348 = (state == S_WR_CRC);
  assign when_EmmcDat_l371 = (state == S_WR_END);
  assign when_EmmcDat_l382 = (state == S_WR_CRC_STAT);
  assign when_EmmcDat_l411 = (state == S_WR_BUSY);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      state <= 4'b0000;
      bitCnt <= 13'h0;
      timeoutCnt <= 16'h0;
      timeoutFlag <= 1'b0;
      byteAcc <= 8'h0;
      bitInByte <= 3'b000;
      byteComplete <= 1'b0;
      wrByteReg <= 8'h0;
      wrBitIdx <= 3'b000;
      rdDoneR <= 1'b0;
      rdCrcErrR <= 1'b0;
      wrDoneR <= 1'b0;
      wrCrcErrR <= 1'b0;
      bufWrDataR <= 8'h0;
      bufWrAddrR <= 9'h0;
      bufWrEnR <= 1'b0;
      bufRdAddrR <= 9'h0;
      datOutR <= 4'b1111;
      datOeR <= 1'b0;
      nibblePhase <= 1'b0;
      rdCrcClear <= 1'b1;
      rdCrcEn <= 1'b0;
      crcRecvArr_0 <= 16'h0;
      crcRecvArr_1 <= 16'h0;
      crcRecvArr_2 <= 16'h0;
      crcRecvArr_3 <= 16'h0;
      crcRecv <= 16'h0;
      wrCrcClear <= 1'b1;
      wrCrcEn <= 1'b0;
      wrCrcBit <= 4'b1111;
      wrCrcShiftArr_0 <= 16'h0;
      wrCrcShiftArr_1 <= 16'h0;
      wrCrcShiftArr_2 <= 16'h0;
      wrCrcShiftArr_3 <= 16'h0;
      wrCrcShift <= 16'h0;
      crcStatusReg <= 3'b000;
      crcStatusCnt <= 3'b000;
    end else begin
      rdDoneR <= 1'b0;
      rdCrcErrR <= 1'b0;
      wrDoneR <= 1'b0;
      wrCrcErrR <= 1'b0;
      bufWrEnR <= 1'b0;
      rdCrcClear <= 1'b0;
      rdCrcEn <= 1'b0;
      wrCrcClear <= 1'b0;
      wrCrcEn <= 1'b0;
      if(when_EmmcDat_l141) begin
        datOeR <= 1'b0;
        datOutR <= 4'b1111;
        if(io_rdStart) begin
          rdCrcClear <= 1'b1;
          timeoutCnt <= 16'h0;
          timeoutFlag <= 1'b0;
          state <= S_RD_WAIT_START;
        end else begin
          if(io_wrStart) begin
            wrCrcClear <= 1'b1;
            bufRdAddrR <= 9'h0;
            bitCnt <= 13'h0;
            state <= S_WR_PREFETCH;
          end
        end
      end else begin
        if(when_EmmcDat_l156) begin
          if(io_clkEn) begin
            if(when_EmmcDat_l159) begin
              bitCnt <= 13'h0;
              bitInByte <= 3'b000;
              byteComplete <= 1'b0;
              bufWrAddrR <= 9'h1ff;
              nibblePhase <= 1'b0;
              state <= S_RD_DATA;
            end else begin
              timeoutCnt <= (timeoutCnt + 16'h0001);
              if(when_EmmcDat_l168) begin
                timeoutFlag <= 1'b1;
              end
              if(timeoutFlag) begin
                rdCrcErrR <= 1'b1;
                rdDoneR <= 1'b1;
                state <= S_IDLE;
              end
            end
          end
        end else begin
          if(when_EmmcDat_l179) begin
            if(io_clkEn) begin
              rdCrcEn <= 1'b1;
              if(io_busWidth4) begin
                if(when_EmmcDat_l185) begin
                  byteAcc[7] <= io_datIn[3];
                  byteAcc[6] <= io_datIn[2];
                  byteAcc[5] <= io_datIn[1];
                  byteAcc[4] <= io_datIn[0];
                  nibblePhase <= 1'b1;
                end else begin
                  byteAcc[3] <= io_datIn[3];
                  byteAcc[2] <= io_datIn[2];
                  byteAcc[1] <= io_datIn[1];
                  byteAcc[0] <= io_datIn[0];
                  nibblePhase <= 1'b0;
                  byteComplete <= 1'b1;
                  bufWrDataR <= {byteAcc[7 : 4],io_datIn};
                  bufWrEnR <= 1'b1;
                  bufWrAddrR <= (bufWrAddrR + 9'h001);
                end
                bitCnt <= (bitCnt + 13'h0001);
                if(when_EmmcDat_l206) begin
                  bitCnt <= 13'h0;
                  crcRecvArr_0 <= 16'h0;
                  crcRecvArr_1 <= 16'h0;
                  crcRecvArr_2 <= 16'h0;
                  crcRecvArr_3 <= 16'h0;
                  state <= S_RD_CRC;
                end
              end else begin
                byteAcc <= {byteAcc[6 : 0],io_datIn[0]};
                bitInByte <= (bitInByte + 3'b001);
                byteComplete <= (bitInByte == 3'b110);
                bufWrDataR <= {byteAcc[6 : 0],io_datIn[0]};
                bufWrEnR <= byteComplete;
                if(byteComplete) begin
                  bufWrAddrR <= (bufWrAddrR + 9'h001);
                end
                bitCnt <= (bitCnt + 13'h0001);
                if(when_EmmcDat_l223) begin
                  bitCnt <= 13'h0;
                  crcRecv <= 16'h0;
                  state <= S_RD_CRC;
                end
              end
            end
          end else begin
            if(when_EmmcDat_l231) begin
              if(io_clkEn) begin
                if(io_busWidth4) begin
                  crcRecvArr_0 <= {crcRecvArr_0[14 : 0],io_datIn[0]};
                  crcRecvArr_1 <= {crcRecvArr_1[14 : 0],io_datIn[1]};
                  crcRecvArr_2 <= {crcRecvArr_2[14 : 0],io_datIn[2]};
                  crcRecvArr_3 <= {crcRecvArr_3[14 : 0],io_datIn[3]};
                end else begin
                  crcRecv <= {crcRecv[14 : 0],io_datIn[0]};
                end
                bitCnt <= (bitCnt + 13'h0001);
                if(when_EmmcDat_l243) begin
                  state <= S_RD_END;
                end
              end
            end else begin
              if(when_EmmcDat_l248) begin
                if(io_clkEn) begin
                  if(io_busWidth4) begin
                    if(when_EmmcDat_l253) begin
                      rdCrcErrR <= 1'b1;
                    end
                  end else begin
                    if(when_EmmcDat_l257) begin
                      rdCrcErrR <= 1'b1;
                    end
                  end
                  rdDoneR <= 1'b1;
                  state <= S_IDLE;
                end
              end else begin
                if(when_EmmcDat_l265) begin
                  state <= S_WR_PREFETCH2;
                end else begin
                  if(when_EmmcDat_l268) begin
                    wrByteReg <= io_bufRdData;
                    bufRdAddrR <= 9'h001;
                    state <= S_WR_START;
                  end else begin
                    if(when_EmmcDat_l273) begin
                      if(io_clkEn) begin
                        wrBitIdx <= 3'b111;
                        datOeR <= 1'b1;
                        datOutR <= 4'b0000;
                        bitCnt <= 13'h0;
                        nibblePhase <= 1'b0;
                        state <= S_WR_DATA;
                      end
                    end else begin
                      if(when_EmmcDat_l283) begin
                        if(io_clkEn) begin
                          datOeR <= 1'b1;
                          if(io_busWidth4) begin
                            if(when_EmmcDat_l289) begin
                              datOutR <= {{{wrByteReg[7],wrByteReg[6]},wrByteReg[5]},wrByteReg[4]};
                              wrCrcBit <= {{{wrByteReg[7],wrByteReg[6]},wrByteReg[5]},wrByteReg[4]};
                              wrCrcEn <= 1'b1;
                              nibblePhase <= 1'b1;
                            end else begin
                              datOutR <= {{{wrByteReg[3],wrByteReg[2]},wrByteReg[1]},wrByteReg[0]};
                              wrCrcBit <= {{{wrByteReg[3],wrByteReg[2]},wrByteReg[1]},wrByteReg[0]};
                              wrCrcEn <= 1'b1;
                              nibblePhase <= 1'b0;
                              wrByteReg <= io_bufRdData;
                              bufRdAddrR <= (bufRdAddrR + 9'h001);
                            end
                            bitCnt <= (bitCnt + 13'h0001);
                            if(when_EmmcDat_l306) begin
                              bitCnt <= 13'h0;
                              state <= S_WR_CRC_WAIT;
                            end
                          end else begin
                            datOutR[0] <= wrByteReg[7];
                            datOutR[3 : 1] <= 3'b111;
                            wrCrcBit[0] <= wrByteReg[7];
                            wrCrcBit[3 : 1] <= 3'b111;
                            wrCrcEn <= 1'b1;
                            if(when_EmmcDat_l318) begin
                              wrByteReg <= io_bufRdData;
                              bufRdAddrR <= (bufRdAddrR + 9'h001);
                              wrBitIdx <= 3'b111;
                            end else begin
                              wrByteReg <= {wrByteReg[6 : 0],1'b0};
                              wrBitIdx <= (wrBitIdx - 3'b001);
                            end
                            bitCnt <= (bitCnt + 13'h0001);
                            if(when_EmmcDat_l328) begin
                              bitCnt <= 13'h0;
                              state <= S_WR_CRC_WAIT;
                            end
                          end
                        end
                      end else begin
                        if(when_EmmcDat_l335) begin
                          if(when_EmmcDat_l336) begin
                            if(io_busWidth4) begin
                              wrCrcShiftArr_0 <= wrCrcs_0_io_crcOut;
                              wrCrcShiftArr_1 <= wrCrcs_1_io_crcOut;
                              wrCrcShiftArr_2 <= wrCrcs_2_io_crcOut;
                              wrCrcShiftArr_3 <= wrCrcs_3_io_crcOut;
                            end else begin
                              wrCrcShift <= wrCrcs_0_io_crcOut;
                            end
                            bitCnt <= 13'h0;
                            state <= S_WR_CRC;
                          end else begin
                            bitCnt <= (bitCnt + 13'h0001);
                          end
                        end else begin
                          if(when_EmmcDat_l348) begin
                            if(io_clkEn) begin
                              datOeR <= 1'b1;
                              if(io_busWidth4) begin
                                datOutR[0] <= wrCrcShiftArr_0[15];
                                wrCrcShiftArr_0 <= {wrCrcShiftArr_0[14 : 0],1'b0};
                                datOutR[1] <= wrCrcShiftArr_1[15];
                                wrCrcShiftArr_1 <= {wrCrcShiftArr_1[14 : 0],1'b0};
                                datOutR[2] <= wrCrcShiftArr_2[15];
                                wrCrcShiftArr_2 <= {wrCrcShiftArr_2[14 : 0],1'b0};
                                datOutR[3] <= wrCrcShiftArr_3[15];
                                wrCrcShiftArr_3 <= {wrCrcShiftArr_3[14 : 0],1'b0};
                              end else begin
                                datOutR[0] <= wrCrcShift[15];
                                datOutR[3 : 1] <= 3'b111;
                                wrCrcShift <= {wrCrcShift[14 : 0],1'b0};
                              end
                              bitCnt <= (bitCnt + 13'h0001);
                              if(when_EmmcDat_l366) begin
                                state <= S_WR_END;
                              end
                            end
                          end else begin
                            if(when_EmmcDat_l371) begin
                              if(io_clkEn) begin
                                datOutR <= 4'b1111;
                                datOeR <= 1'b0;
                                crcStatusCnt <= 3'b000;
                                crcStatusReg <= 3'b000;
                                timeoutCnt <= 16'h0;
                                timeoutFlag <= 1'b0;
                                state <= S_WR_CRC_STAT;
                              end
                            end else begin
                              if(when_EmmcDat_l382) begin
                                if(io_clkEn) begin
                                  if(when_EmmcDat_l385) begin
                                    crcStatusCnt <= 3'b001;
                                  end else begin
                                    if(when_EmmcDat_l387) begin
                                      crcStatusReg <= {crcStatusReg[1 : 0],io_datIn[0]};
                                      crcStatusCnt <= (crcStatusCnt + 3'b001);
                                    end else begin
                                      if(when_EmmcDat_l390) begin
                                        if(when_EmmcDat_l391) begin
                                          state <= S_WR_BUSY;
                                        end else begin
                                          wrCrcErrR <= 1'b1;
                                          wrDoneR <= 1'b1;
                                          state <= S_IDLE;
                                        end
                                      end else begin
                                        timeoutCnt <= (timeoutCnt + 16'h0001);
                                        if(when_EmmcDat_l400) begin
                                          timeoutFlag <= 1'b1;
                                        end
                                        if(timeoutFlag) begin
                                          wrCrcErrR <= 1'b1;
                                          wrDoneR <= 1'b1;
                                          state <= S_IDLE;
                                        end
                                      end
                                    end
                                  end
                                end
                              end else begin
                                if(when_EmmcDat_l411) begin
                                  if(io_clkEn) begin
                                    if(when_EmmcDat_l414) begin
                                      crcStatusCnt <= (crcStatusCnt + 3'b001);
                                    end else begin
                                      if(when_EmmcDat_l416) begin
                                        wrDoneR <= 1'b1;
                                        state <= S_IDLE;
                                      end else begin
                                        timeoutCnt <= (timeoutCnt + 16'h0001);
                                        if(when_EmmcDat_l421) begin
                                          timeoutFlag <= 1'b1;
                                        end
                                        if(timeoutFlag) begin
                                          wrCrcErrR <= 1'b1;
                                          wrDoneR <= 1'b1;
                                          state <= S_IDLE;
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
      end
    end
  end


endmodule

//Crc16_7 replaced by Crc16

//Crc16_6 replaced by Crc16

//Crc16_5 replaced by Crc16

//Crc16_4 replaced by Crc16

//Crc16_3 replaced by Crc16

//Crc16_2 replaced by Crc16

//Crc16_1 replaced by Crc16

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
