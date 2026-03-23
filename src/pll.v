// PLL: 27 MHz input -> 60 MHz system clock
// Uses Gowin rPLL primitive for GW1NR-9
// fCLKOUT = 27 * (FBDIV+1) / (IDIV+1) = 27 * 20 / 9 = 60 MHz
// fVCO = fCLKOUT * ODIV = 60 * 8 = 480 MHz (valid range: 400-900 MHz)
// Clean UART baud: 60/20=3M, 60/10=6M, 60/5=12M

module pll (
    input  wire clkin,     // 27 MHz
    output wire clkout,    // 60 MHz
    output wire lock
);

    rPLL #(
        .FCLKIN       ("27"),      // Input freq (MHz)
        .DYN_IDIV_SEL ("false"),
        .IDIV_SEL     (8),         // IDIV = 8 -> divide by 9
        .DYN_FBDIV_SEL("false"),
        .FBDIV_SEL    (19),        // FBDIV = 19 -> multiply by 20
        .DYN_ODIV_SEL ("false"),
        .ODIV_SEL     (8),         // ODIV = 8 -> fVCO = 480 MHz, fCLKOUT = 60 MHz
        .PSDA_SEL     ("0000"),
        .DYN_DA_EN    ("false"),
        .DUTYDA_SEL   ("1000"),
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL    ("internal"),
        .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL (2),
        .CLKOUTD_SRC  ("CLKOUT"),
        .CLKOUTD3_SRC ("CLKOUT"),
        .DEVICE       ("GW1NR-9C")
    ) pll_inst (
        .CLKOUT   (clkout),
        .LOCK     (lock),
        .CLKOUTP  (),
        .CLKOUTD  (),
        .CLKOUTD3 (),
        .RESET    (1'b0),
        .RESET_P  (1'b0),
        .CLKIN    (clkin),
        .CLKFB    (1'b0),
        .FBDSEL   (6'b0),
        .IDSEL    (6'b0),
        .ODSEL    (6'b0),
        .PSDA     (4'b0),
        .DUTYDA   (4'b0),
        .FDLY     (4'b0)
    );

endmodule
