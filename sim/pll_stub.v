// PLL stub for simulation (replaces Gowin rPLL primitive)
// Generates 60 MHz clock from any input

module pll (
    input  wire clkin,
    output reg  clkout,
    output reg  lock
);

    initial begin
        clkout = 0;
        lock   = 0;
        #100 lock = 1;
    end

    // 60 MHz: period = 16.667 ns, half-period = 8.333 ns
    always #8.333 clkout = ~clkout;

endmodule
