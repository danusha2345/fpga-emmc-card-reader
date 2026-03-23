// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : ft245_fifo
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module ft245_fifo (
  input  wire [7:0]    fifoDataRead,
  output wire [7:0]    fifoDataWrite,
  output wire          fifoDataOe,
  input  wire          fifoRxfN,
  input  wire          fifoTxeN,
  output wire          fifoRdN,
  output wire          fifoWrN,
  output wire [7:0]    rxDataOut,
  output wire          rxDataValid,
  input  wire [7:0]    txDataIn,
  input  wire          txDataValid,
  output wire          txBusy,
  input  wire          rxSuppress,
  input  wire          clk,
  input  wire          resetn
);

  reg                 rxfSync1;
  reg                 rxfSync2;
  reg                 txeSync1;
  reg                 txeSync2;
  wire                rxfActive;
  wire                txeActive;
  wire       [1:0]    S_IDLE;
  wire       [1:0]    S_READ;
  wire       [1:0]    S_WRITE;
  reg        [1:0]    state;
  reg        [2:0]    cycleCnt;
  reg                 txPending;
  reg        [7:0]    txHold;
  wire                when_Ft245Fifo_l72;
  reg                 rdNR;
  reg                 wrNR;
  reg                 dataOeR;
  reg        [7:0]    dataWriteR;
  reg        [7:0]    rxDataR;
  reg                 rxValidR;
  wire                when_Ft245Fifo_l96;
  wire                when_Ft245Fifo_l103;
  wire                when_Ft245Fifo_l108;
  wire                when_Ft245Fifo_l118;
  wire                when_Ft245Fifo_l121;
  wire                when_Ft245Fifo_l124;
  wire                when_Ft245Fifo_l130;
  wire                when_Ft245Fifo_l140;
  wire                when_Ft245Fifo_l143;
  wire                when_Ft245Fifo_l146;
  wire                when_Ft245Fifo_l114;
  wire                when_Ft245Fifo_l138;

  assign rxfActive = (! rxfSync2);
  assign txeActive = (! txeSync2);
  assign S_IDLE = 2'b00;
  assign S_READ = 2'b01;
  assign S_WRITE = 2'b10;
  assign when_Ft245Fifo_l72 = (txDataValid && (! txPending));
  assign fifoRdN = rdNR;
  assign fifoWrN = wrNR;
  assign fifoDataOe = dataOeR;
  assign fifoDataWrite = dataWriteR;
  assign rxDataOut = rxDataR;
  assign rxDataValid = rxValidR;
  assign txBusy = txPending;
  assign when_Ft245Fifo_l96 = (state == S_IDLE);
  assign when_Ft245Fifo_l103 = (txPending && txeActive);
  assign when_Ft245Fifo_l108 = (rxfActive && (! rxSuppress));
  assign when_Ft245Fifo_l118 = (cycleCnt == 3'b000);
  assign when_Ft245Fifo_l121 = (cycleCnt == 3'b001);
  assign when_Ft245Fifo_l124 = (cycleCnt == 3'b010);
  assign when_Ft245Fifo_l130 = (cycleCnt <= 3'b101);
  assign when_Ft245Fifo_l140 = (cycleCnt == 3'b000);
  assign when_Ft245Fifo_l143 = (cycleCnt == 3'b001);
  assign when_Ft245Fifo_l146 = (cycleCnt == 3'b010);
  assign when_Ft245Fifo_l114 = (state == S_READ);
  assign when_Ft245Fifo_l138 = (state == S_WRITE);
  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      rxfSync1 <= 1'b1;
      rxfSync2 <= 1'b1;
      txeSync1 <= 1'b1;
      txeSync2 <= 1'b1;
      state <= 2'b00;
      cycleCnt <= 3'b000;
      txPending <= 1'b0;
      txHold <= 8'h0;
      rdNR <= 1'b1;
      wrNR <= 1'b1;
      dataOeR <= 1'b0;
      dataWriteR <= 8'h0;
      rxDataR <= 8'h0;
      rxValidR <= 1'b0;
    end else begin
      rxfSync1 <= fifoRxfN;
      rxfSync2 <= rxfSync1;
      txeSync1 <= fifoTxeN;
      txeSync2 <= txeSync1;
      if(when_Ft245Fifo_l72) begin
        txPending <= 1'b1;
        txHold <= txDataIn;
      end
      rxValidR <= 1'b0;
      if(when_Ft245Fifo_l96) begin
        rdNR <= 1'b1;
        wrNR <= 1'b1;
        dataOeR <= 1'b0;
        if(when_Ft245Fifo_l103) begin
          state <= S_WRITE;
          cycleCnt <= 3'b000;
          dataOeR <= 1'b1;
          dataWriteR <= txHold;
        end else begin
          if(when_Ft245Fifo_l108) begin
            state <= S_READ;
            cycleCnt <= 3'b000;
            rdNR <= 1'b0;
          end
        end
      end else begin
        if(when_Ft245Fifo_l114) begin
          if(when_Ft245Fifo_l118) begin
            cycleCnt <= 3'b001;
          end else begin
            if(when_Ft245Fifo_l121) begin
              cycleCnt <= 3'b010;
            end else begin
              if(when_Ft245Fifo_l124) begin
                rxDataR <= fifoDataRead;
                rxValidR <= 1'b1;
                rdNR <= 1'b1;
                cycleCnt <= 3'b011;
              end else begin
                if(when_Ft245Fifo_l130) begin
                  cycleCnt <= (cycleCnt + 3'b001);
                end else begin
                  state <= S_IDLE;
                end
              end
            end
          end
        end else begin
          if(when_Ft245Fifo_l138) begin
            if(when_Ft245Fifo_l140) begin
              wrNR <= 1'b0;
              cycleCnt <= 3'b001;
            end else begin
              if(when_Ft245Fifo_l143) begin
                cycleCnt <= 3'b010;
              end else begin
                if(when_Ft245Fifo_l146) begin
                  cycleCnt <= 3'b011;
                end else begin
                  wrNR <= 1'b1;
                  dataOeR <= 1'b0;
                  txPending <= 1'b0;
                  state <= S_IDLE;
                end
              end
            end
          end
        end
      end
    end
  end


endmodule
