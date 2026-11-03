// -----------------------------------------------------------------------------
// File: linux_timer.v
// Author: Codex
// Date: 2026-10-20
// Description: Single-hart CLINT registers; one tick per 50 MHz CPU clock.
//   Parent Wishbone adapter accepts requests and supplies ACK/ERR. write_i is
//   asserted only on the accepted beat. address_i is a byte offset from F0010000.
//   RV32 software must read high/low/high and update compare high=-1, low, high.
//   MTIP follows the registered comparison, including after compare writes.
// ChangeLog: 2026-10-20 v1.0 Initial Linux timer hardware (no extra RAM/CDC).
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module linux_timer (
    input  wire        clk,
    input  wire        rst,
    input  wire        write_i,
    input  wire [15:0] address_i,
    input  wire [31:0] data_i,
    input  wire [3:0]  select_i,
    output wire [31:0] data_o,
    output wire        timer_interrupt_o,
    output wire        software_interrupt_o
);
    reg [31:0] time_low_reg = 32'd0, time_low_next;
    reg [31:0] time_high_reg = 32'd0, time_high_next;
    reg [31:0] compare_low_reg = 32'hffffffff, compare_low_next;
    reg [31:0] compare_high_reg = 32'hffffffff, compare_high_next;
    reg software_reg = 1'b0, software_next;
    reg pending_reg = 1'b0, pending_next;
    reg [31:0] read_data;
    integer lane;

    assign data_o = read_data;
    assign timer_interrupt_o = pending_reg && !rst;
    assign software_interrupt_o = software_reg && !rst;

    always @* begin
        time_low_next = time_low_reg + 32'd1;
        time_high_next = time_high_reg;
        if (time_low_reg == 32'hffffffff)
            time_high_next = time_high_reg + 32'd1;
        compare_low_next = compare_low_reg;
        compare_high_next = compare_high_reg;
        software_next = software_reg;
        // Separate 32-bit comparisons end at this register, not at the CPU.
        pending_next = (time_high_reg > compare_high_reg) ||
            ((time_high_reg == compare_high_reg) && (time_low_reg >= compare_low_reg));
        read_data = 32'd0;
        case (address_i)
            16'h0000: read_data = {31'd0, software_reg};
            16'h4000: read_data = compare_low_reg;
            16'h4004: read_data = compare_high_reg;
            16'hbff8: read_data = time_low_reg;
            16'hbffc: read_data = time_high_reg;
            default: read_data = 32'd0;
        endcase
        if (write_i) begin
            if (address_i == 16'h0000 && select_i[0])
                software_next = data_i[0];
            if ((address_i == 16'hbff8 || address_i == 16'hbffc) && (|select_i)) begin
                // A partial time write preserves all other bytes, with no tick.
                time_low_next = time_low_reg;
                time_high_next = time_high_reg;
            end
            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (select_i[lane]) begin
                    case (address_i)
                        16'h4000: compare_low_next[lane*8 +: 8] = data_i[lane*8 +: 8];
                        16'h4004: compare_high_next[lane*8 +: 8] = data_i[lane*8 +: 8];
                        16'hbff8: time_low_next[lane*8 +: 8] = data_i[lane*8 +: 8];
                        16'hbffc: time_high_next[lane*8 +: 8] = data_i[lane*8 +: 8];
                        default: ;
                    endcase
                end
            end
        end
    end

    always @(posedge clk) begin
        time_low_reg <= time_low_next;
        time_high_reg <= time_high_next;
        compare_low_reg <= compare_low_next;
        compare_high_reg <= compare_high_next;
        software_reg <= software_next;
        pending_reg <= pending_next;
        if (rst) begin
            time_low_reg <= 32'd0;
            time_high_reg <= 32'd0;
            compare_low_reg <= 32'hffffffff;
            compare_high_reg <= 32'hffffffff;
            software_reg <= 1'b0;
            pending_reg <= 1'b0;
        end
    end
endmodule
`resetall
