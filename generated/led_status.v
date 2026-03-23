// Generator : SpinalHDL v1.10.2a    git head : a348a60b7e8b6a455c72e1536ec3d74a2ea16935
// Component : led_status
// Git hash  : 65b423ab994fff1dea814b3ae3e828eee8a98f5c

`timescale 1ns/1ps

module led_status (
  input  wire          emmcActive,
  input  wire          uartActive,
  input  wire          emmcReady,
  input  wire          error,
  output reg  [5:0]    ledN,
  input  wire          clk,
  input  wire          resetn
);

  reg        [26:0]   hbCnt;
  reg        [21:0]   uartStretch;
  reg                 uartStretchActive;
  wire                when_LedStatus_l38;
  reg        [21:0]   emmcStretch;
  reg                 emmcStretchActive;
  wire                when_LedStatus_l51;

  assign when_LedStatus_l38 = (uartStretch == 22'h000001);
  assign when_LedStatus_l51 = (emmcStretch == 22'h000001);
  always @(*) begin
    ledN[0] = (! emmcStretchActive);
    ledN[1] = (! uartStretchActive);
    ledN[2] = (! emmcReady);
    ledN[3] = (! error);
    ledN[4] = 1'b1;
    ledN[5] = (! hbCnt[26]);
  end

  always @(posedge clk or negedge resetn) begin
    if(!resetn) begin
      hbCnt <= 27'h0;
      uartStretch <= 22'h0;
      uartStretchActive <= 1'b0;
      emmcStretch <= 22'h0;
      emmcStretchActive <= 1'b0;
    end else begin
      hbCnt <= (hbCnt + 27'h0000001);
      if(uartActive) begin
        uartStretch <= 22'h3fffff;
        uartStretchActive <= 1'b1;
      end else begin
        if(uartStretchActive) begin
          uartStretch <= (uartStretch - 22'h000001);
          if(when_LedStatus_l38) begin
            uartStretchActive <= 1'b0;
          end
        end
      end
      if(emmcActive) begin
        emmcStretch <= 22'h3fffff;
        emmcStretchActive <= 1'b1;
      end else begin
        if(emmcStretchActive) begin
          emmcStretch <= (emmcStretch - 22'h000001);
          if(when_LedStatus_l51) begin
            emmcStretchActive <= 1'b0;
          end
        end
      end
    end
  end


endmodule
