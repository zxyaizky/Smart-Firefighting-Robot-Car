// Decode physical Wishbone WORD addresses. All local subregions and unmapped
// access errors remain implemented by the existing local memory slave.
`resetall
`timescale 1ns/1ps
`default_nettype none
module cpu_wb_decoder #
(
    // Disabled only for legacy standalone local-ROM regression configurations.
    parameter ENABLE_DDR = 1'b1
)
(
    input  wire [29:0] ibus_adr_i,
    input  wire [29:0] dbus_adr_i,
    output wire ibus_ddr_o,
    output wire dbus_ddr_o
);
    // CPU 0x40000000..0x41ffffff -> physical DDR byte 32..64 MiB.
    // CPU physical bit31 is zero: this CPU uses bit31=1 for uncached MMIO.
    assign ibus_ddr_o=ENABLE_DDR && ibus_adr_i[29:23]==7'h20;
    assign dbus_ddr_o=ENABLE_DDR && dbus_adr_i[29:23]==7'h20;
endmodule
`resetall
