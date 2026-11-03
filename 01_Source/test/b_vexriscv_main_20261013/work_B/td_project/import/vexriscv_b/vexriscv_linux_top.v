// -----------------------------------------------------------------------------
// File   : vexriscv_linux_top.v
// Author : Codex
// Date   : 2026-10-13
// -----------------------------------------------------------------------------
// Description:
//   Linux CPU and caches with exposed Wishbone buses for test or future DDR.
//   Interrupts and bus responses are driven by the surrounding system.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-13  Codex  v1.0  Derive every connection from upstream CPU ports.
//   2026-10-13  Codex  v1.1  Expose read-only privilege/Sv32 state for TD debug.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module vexriscv_linux_top #
(
    // Physical reset address, held constant for the entire run.
    parameter [31:0] RESET_VECTOR = 32'h00000000
)
(
    input  wire          clk,
    input  wire          rst,
    input  wire          timer_interrupt_i,
    input  wire          software_interrupt_i,
    input  wire [31:0]   external_interrupt_array_i,
    output wire          ibus_cyc_o,
    output wire          ibus_stb_o,
    input  wire          ibus_ack_i,
    output wire          ibus_we_o,
    output wire [29:0]   ibus_adr_o,
    input  wire [31:0]   ibus_dat_miso_i,
    output wire [31:0]   ibus_dat_mosi_o,
    output wire [3:0]    ibus_sel_o,
    input  wire          ibus_err_i,
    output wire [2:0]    ibus_cti_o,
    output wire [1:0]    ibus_bte_o,
    output wire          dbus_cyc_o,
    output wire          dbus_stb_o,
    input  wire          dbus_ack_i,
    output wire          dbus_we_o,
    output wire [29:0]   dbus_adr_o,
    input  wire [31:0]   dbus_dat_miso_i,
    output wire [31:0]   dbus_dat_mosi_o,
    output wire [3:0]    dbus_sel_o,
    input  wire          dbus_err_i,
    output wire [2:0]    dbus_cti_o,
    output wire [1:0]    dbus_bte_o,
    output wire [2:0]    debug_state_o
);
    VexRiscv cpu_inst (
        .debug_state_o              (debug_state_o),
        .externalResetVector        (RESET_VECTOR),
        .timerInterrupt             (timer_interrupt_i),
        .softwareInterrupt          (software_interrupt_i),
        .externalInterruptArray     (external_interrupt_array_i),
        .iBusWishbone_CYC           (ibus_cyc_o),
        .iBusWishbone_STB           (ibus_stb_o),
        .iBusWishbone_ACK           (ibus_ack_i),
        .iBusWishbone_WE            (ibus_we_o),
        .iBusWishbone_ADR           (ibus_adr_o),
        .iBusWishbone_DAT_MISO      (ibus_dat_miso_i),
        .iBusWishbone_DAT_MOSI      (ibus_dat_mosi_o),
        .iBusWishbone_SEL           (ibus_sel_o),
        .iBusWishbone_ERR           (ibus_err_i),
        .iBusWishbone_CTI           (ibus_cti_o),
        .iBusWishbone_BTE           (ibus_bte_o),
        .dBusWishbone_CYC           (dbus_cyc_o),
        .dBusWishbone_STB           (dbus_stb_o),
        .dBusWishbone_ACK           (dbus_ack_i),
        .dBusWishbone_WE            (dbus_we_o),
        .dBusWishbone_ADR           (dbus_adr_o),
        .dBusWishbone_DAT_MISO      (dbus_dat_miso_i),
        .dBusWishbone_DAT_MOSI      (dbus_dat_mosi_o),
        .dBusWishbone_SEL           (dbus_sel_o),
        .dBusWishbone_ERR           (dbus_err_i),
        .dBusWishbone_CTI           (dbus_cti_o),
        .dBusWishbone_BTE           (dbus_bte_o),
        .clk                        (clk),
        .reset                      (rst)
    );
endmodule
`resetall
