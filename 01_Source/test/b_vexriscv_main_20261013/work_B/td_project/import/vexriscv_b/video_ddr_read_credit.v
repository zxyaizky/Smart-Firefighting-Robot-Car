// -----------------------------------------------------------------------------
// File   : video_ddr_read_credit.v
// Author : Codex
// Date   : 2026-10-17
// -----------------------------------------------------------------------------
// Description:
//   Reserve an output-FIFO slot for each video read before it enters the
//   shared MC command queue. Reservations cover queueing, DDR and return time.
//   The existing video_out burst generator and pixel format are unchanged.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-17  Codex  v1.0  Bound FIFO occupancy plus every unreturned read.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module video_ddr_read_credit #
(
    // Leave 31 physical FIFO entries for count/update and CDC conservatism.
    parameter integer CREDIT_LIMIT = 480
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire [8:0]  fifo_used_i,
    input  wire        read_request_i,
    input  wire        read_return_i,
    input  wire        downstream_ready_i,
    output wire        ready_o,
    output wire [9:0]  outstanding_o,
    output wire        error_o
);
    localparam [10:0] LIMIT = CREDIT_LIMIT;
    reg [9:0] outstanding_reg = 10'd0, outstanding_next;
    reg error_reg = 1'b0, error_next;
    wire [10:0] reserved_slots;
    wire accept_read;
    assign reserved_slots = {2'd0, fifo_used_i} + {1'b0, outstanding_reg};
    assign ready_o = !rst && !error_reg && downstream_ready_i && reserved_slots < LIMIT;
    assign accept_read = read_request_i && ready_o;
    assign outstanding_o = outstanding_reg;
    assign error_o = error_reg;

    always @* begin
        outstanding_next = outstanding_reg;
        error_next = error_reg;
        case ({accept_read, read_return_i})
            2'b10: begin
                if (outstanding_reg == 10'h3ff) error_next = 1'b1;
                else outstanding_next = outstanding_reg + 10'd1;
            end
            2'b01: begin
                if (outstanding_reg == 10'd0) error_next = 1'b1;
                else outstanding_next = outstanding_reg - 10'd1;
            end
            default: begin
                outstanding_next = outstanding_reg;
            end
        endcase
        if (read_request_i && !ready_o) error_next = 1'b1;
    end
    always @(posedge clk) begin
        outstanding_reg <= outstanding_next;
        error_reg <= error_next;
        // Reset with the MC/video request chain only. A display frame resets
        // its pixel FIFO, but must not erase read requests still inside MC.
        if (rst) begin
            outstanding_reg <= 10'd0;
            error_reg <= 1'b0;
        end
    end
endmodule
`resetall
