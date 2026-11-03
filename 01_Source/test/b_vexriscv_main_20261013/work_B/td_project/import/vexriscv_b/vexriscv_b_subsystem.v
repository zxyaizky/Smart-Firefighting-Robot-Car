// -----------------------------------------------------------------------------
// File   : vexriscv_b_subsystem.v
// Author : Codex
// Date   : 2026-10-13
// -----------------------------------------------------------------------------
// Description:
//   Full Linux-capable CPU with local self-test memory, independent of B video.
//   A small main-top MARK_DEBUG sample consumes CPU execution and paging state.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-19  Codex  v1.2  Forward optional CPU UART serial pins.
//   2026-10-13  Codex  v1.0  B-board main-top CPU integration boundary.
//   2026-10-13  Codex  v1.1  Remove blanket keep; expose architectural debug state.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "true" *) module vexriscv_b_subsystem #
(
    // Local timer period in cycles; no board PLL or clock divider is added.
    parameter integer TIMER_PERIOD_CYCLES = 50000,
    // Test-memory response latency independent of DDR.
    parameter integer WAIT_CYCLES = 1,
    // Standalone local-ROM tests default off; the real main top enables DDR.
    parameter ENABLE_DDR = 1'b0,
    parameter DDR_BOOT_ENABLE = 1'b0,
    parameter UART_ENABLE = 1'b0,
    parameter DDR_WORD_RESPONSE = 0,
    parameter integer DDR_TIMEOUT_CYCLES = 1048576
)
(
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] cycle_count_o,
    output wire [31:0] status_o,
    output wire [31:0] heartbeat_o,
    output wire [31:0] last_trap_o,
    output wire [31:0] result_o,
    output wire        protocol_error_o,
    output wire [2:0]  debug_state_o,
    input  wire        ddr_ready_i,
    input  wire [1:0]  ddr_errors_i,
    output wire        ddr_req_valid_o,
    input  wire        ddr_req_ready_i,
    output wire        ddr_req_write_o,
    output wire [24:0] ddr_req_addr_o,
    output wire [127:0] ddr_req_wdata_o,
    output wire [15:0] ddr_req_mask_o,
    output wire [1:0] ddr_req_lane_o,
    output wire [3:0] ddr_req_select_o,
    input  wire        ddr_rsp_valid_i,
    output wire        ddr_rsp_ready_o,
    input  wire [(DDR_WORD_RESPONSE ? 32 : 128)-1:0] ddr_rsp_rdata_i,
    input  wire        ddr_rsp_error_i,
    output wire [31:0] ddr_status_o,
    output wire [31:0] ddr_heartbeat_o,
    output wire        ddr_busy_o,
    output wire        ddr_error_o,
    output wire        ddr_read_done_o,
    output wire        ddr_write_done_o,
    input  wire        uart_rx_i,
    output wire        uart_tx_o
);
    wire ibus_cyc, ibus_stb, ibus_we, ibus_ack, ibus_err;
    wire dbus_cyc, dbus_stb, dbus_we, dbus_ack, dbus_err;
    wire [29:0] ibus_adr, dbus_adr;
    wire [3:0] dbus_adr_low; //synthesis max_fanout=64
    assign dbus_adr[3:0] = dbus_adr_low;
    wire [31:0] ibus_read_data, ibus_write_data;
    wire [31:0] dbus_read_data, dbus_write_data;
    wire [3:0] ibus_sel, dbus_sel;
    wire [2:0] ibus_cti, dbus_cti;
    wire [1:0] ibus_bte, dbus_bte;
    wire timer_interrupt, software_interrupt;
    wire [31:0] external_interrupt_array;
    wire ibus_ddr_selected, dbus_ddr_selected;
    wire local_ibus_ack,local_ibus_err,local_dbus_ack,local_dbus_err;
    wire ddr_ibus_ack,ddr_ibus_err,ddr_dbus_ack,ddr_dbus_err;
    wire [31:0] local_ibus_data,local_dbus_data,ddr_ibus_data,ddr_dbus_data;
    wire [2:0] ddr_error_summary;

    cpu_wb_decoder #(.ENABLE_DDR(ENABLE_DDR)) decoder_inst (
        .ibus_adr_i(ibus_adr), .dbus_adr_i(dbus_adr),
        .ibus_ddr_o(ibus_ddr_selected), .dbus_ddr_o(dbus_ddr_selected)
    );
    assign ibus_ack=ibus_ddr_selected ? ddr_ibus_ack : local_ibus_ack;
    assign ibus_err=ibus_ddr_selected ? ddr_ibus_err : local_ibus_err;
    assign ibus_read_data=ibus_ddr_selected ? ddr_ibus_data : local_ibus_data;
    assign dbus_ack=dbus_ddr_selected ? ddr_dbus_ack : local_dbus_ack;
    assign dbus_err=dbus_ddr_selected ? ddr_dbus_err : local_dbus_err;
    assign dbus_read_data=dbus_ddr_selected ? ddr_dbus_data : local_dbus_data;
    assign ddr_error_summary=ENABLE_DDR ? {ddr_errors_i,ddr_error_o} : 3'd0;

    generate
        if (ENABLE_DDR) begin : cpu_ddr_enabled
            cpu_wb_ddr_bridge #(.TIMEOUT_CYCLES(DDR_TIMEOUT_CYCLES),.WORD_RESPONSE(DDR_WORD_RESPONSE)) bridge_inst (
                .clk(clk),.rst(rst),.ddr_ready_i(ddr_ready_i),
                .ibus_cyc_i(ibus_cyc && ibus_ddr_selected),
                .ibus_stb_i(ibus_stb && ibus_ddr_selected),
                .ibus_we_i(ibus_we),.ibus_adr_i(ibus_adr),.ibus_sel_i(ibus_sel),
                .ibus_cti_i(ibus_cti),.ibus_bte_i(ibus_bte),
                .ibus_ack_o(ddr_ibus_ack),.ibus_err_o(ddr_ibus_err),.ibus_data_o(ddr_ibus_data),
                .dbus_cyc_i(dbus_cyc && dbus_ddr_selected),
                .dbus_stb_i(dbus_stb && dbus_ddr_selected),
                .dbus_we_i(dbus_we),.dbus_adr_i(dbus_adr),.dbus_data_i(dbus_write_data),
                .dbus_sel_i(dbus_sel),.dbus_cti_i(dbus_cti),.dbus_bte_i(dbus_bte),
                .dbus_ack_o(ddr_dbus_ack),.dbus_err_o(ddr_dbus_err),.dbus_data_o(ddr_dbus_data),
                .req_valid_o(ddr_req_valid_o),.req_ready_i(ddr_req_ready_i),
                .req_write_o(ddr_req_write_o),.req_addr_o(ddr_req_addr_o),
                .req_wdata_o(ddr_req_wdata_o),.req_mask_o(ddr_req_mask_o),.req_lane_o(ddr_req_lane_o),.req_select_o(ddr_req_select_o),
                .rsp_valid_i(ddr_rsp_valid_i),.rsp_error_i(ddr_rsp_error_i),
                .rsp_rdata_i(ddr_rsp_rdata_i),.rsp_ready_o(ddr_rsp_ready_o),
                .busy_o(ddr_busy_o),.error_o(ddr_error_o),
                .read_done_o(ddr_read_done_o),.write_done_o(ddr_write_done_o)
            );
        end else begin : cpu_ddr_disabled
            assign ddr_ibus_ack=1'b0;assign ddr_ibus_err=1'b0;assign ddr_ibus_data=32'd0;
            assign ddr_dbus_ack=1'b0;assign ddr_dbus_err=1'b0;assign ddr_dbus_data=32'd0;
            assign ddr_req_valid_o=1'b0;assign ddr_req_write_o=1'b0;
            assign ddr_req_lane_o=2'd0;
            assign ddr_req_select_o=4'd0;
            assign ddr_req_addr_o=25'd0;assign ddr_req_wdata_o=128'd0;assign ddr_req_mask_o=16'hffff;
            assign ddr_rsp_ready_o=1'b1;assign ddr_busy_o=1'b0;assign ddr_error_o=1'b0;
            assign ddr_read_done_o=1'b0;assign ddr_write_done_o=1'b0;
        end
    endgenerate

    (* keep_hierarchy = "true" *) vexriscv_linux_top cpu_top_inst (
        .debug_state_o              (debug_state_o),
        .clk                        (clk),
        .rst                        (rst),
        .timer_interrupt_i          (timer_interrupt),
        .software_interrupt_i       (software_interrupt),
        .external_interrupt_array_i (external_interrupt_array),
        .ibus_cyc_o                 (ibus_cyc),
        .ibus_stb_o                 (ibus_stb),
        .ibus_we_o                  (ibus_we),
        .ibus_ack_i                 (ibus_ack),
        .ibus_err_i                 (ibus_err),
        .ibus_adr_o                 (ibus_adr),
        .ibus_dat_miso_i            (ibus_read_data),
        .ibus_dat_mosi_o            (ibus_write_data),
        .ibus_sel_o                 (ibus_sel),
        .ibus_cti_o                 (ibus_cti),
        .ibus_bte_o                 (ibus_bte),
        .dbus_cyc_o                 (dbus_cyc),
        .dbus_stb_o                 (dbus_stb),
        .dbus_we_o                  (dbus_we),
        .dbus_ack_i                 (dbus_ack),
        .dbus_err_i                 (dbus_err),
        .dbus_adr_o                 ({dbus_adr[29:4], dbus_adr_low}),
        .dbus_dat_miso_i            (dbus_read_data),
        .dbus_dat_mosi_o            (dbus_write_data),
        .dbus_sel_o                 (dbus_sel),
        .dbus_cti_o                 (dbus_cti),
        .dbus_bte_o                 (dbus_bte)
    );

    // Instruction Wishbone is read-only; the ROM rejects any WE=1 beat.
    (* keep_hierarchy = "true" *) vexriscv_b_memory #
    (
        .TIMER_PERIOD_CYCLES (TIMER_PERIOD_CYCLES),
        .WAIT_CYCLES         (WAIT_CYCLES),
        .DDR_BOOT_ENABLE     (DDR_BOOT_ENABLE),
        .UART_ENABLE         (UART_ENABLE)
    ) memory_inst (
        .clk                        (clk),
        .rst                        (rst),
        .ibus_cyc_i                 (ibus_cyc && !ibus_ddr_selected),
        .ibus_stb_i                 (ibus_stb && !ibus_ddr_selected),
        .ibus_we_i                  (ibus_we),
        .ibus_adr_i                 (ibus_adr),
        .ibus_sel_i                 (ibus_sel),
        .ibus_cti_i                 (ibus_cti),
        .ibus_bte_i                 (ibus_bte),
        .ibus_ack_o                 (local_ibus_ack),
        .ibus_err_o                 (local_ibus_err),
        .ibus_data_o                (local_ibus_data),
        .dbus_cyc_i                 (dbus_cyc && !dbus_ddr_selected),
        .dbus_stb_i                 (dbus_stb && !dbus_ddr_selected),
        .dbus_we_i                  (dbus_we),
        .dbus_adr_i                 (dbus_adr),
        .dbus_data_i                (dbus_write_data),
        .dbus_sel_i                 (dbus_sel),
        .dbus_cti_i                 (dbus_cti),
        .dbus_bte_i                 (dbus_bte),
        .dbus_ack_o                 (local_dbus_ack),
        .dbus_err_o                 (local_dbus_err),
        .dbus_data_o                (local_dbus_data),
        .timer_interrupt_o          (timer_interrupt),
        .software_interrupt_o       (software_interrupt),
        .external_interrupt_array_o (external_interrupt_array),
        .cycle_count_o              (cycle_count_o),
        .status_o                   (status_o),
        .heartbeat_o                (heartbeat_o),
        .last_trap_o                (last_trap_o),
        .result_o                   (result_o),
        .protocol_error_o           (protocol_error_o),
        .ddr_ready_i                (ENABLE_DDR ? ddr_ready_i : 1'b0),
        .ddr_busy_i                 (ddr_busy_o),
        .ddr_errors_i               (ddr_error_summary),
        .ddr_status_o               (ddr_status_o),
        .ddr_heartbeat_o            (ddr_heartbeat_o),
        .uart_rx_i                  (uart_rx_i),
        .uart_tx_o                  (uart_tx_o)
    );
endmodule
`resetall
