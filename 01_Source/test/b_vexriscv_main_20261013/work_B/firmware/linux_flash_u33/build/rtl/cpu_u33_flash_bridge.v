// -----------------------------------------------------------------------------
// File   : cpu_u33_flash_bridge.v
// Author : Codex
// Date   : 2026-10-20
// Description: One read-only Wishbone request serviced by the hard MCU XIP reader.
// Change Log: 2026-10-20 v1.0 Bundled-data toggle CDC; bounded fail-closed timeout.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module cpu_u33_flash_bridge #(
    parameter integer TIMEOUT_CYCLES = 50000000
) (
    input wire clk,
    input wire rst,
    input wire clk_ahb,
    input wire rst_ahb,
    input wire cyc_i,
    input wire stb_i,
    input wire we_i,
    input wire [29:0] address_i,
    output wire ack_o,
    output wire error_o,
    output wire [31:0] data_o,
    input wire [1:0] htrans_i,
    input wire hwrite_i,
    input wire [30:0] haddr_i,
    input wire [2:0] hsize_i,
    input wire [31:0] hwdata_i,
    output wire [31:0] hrdata_o,
    output wire [1:0] hresp_o,
    output wire hready_o
);
    localparam [1:0] IDLE = 2'd0, WAIT = 2'd1, RESPONSE = 2'd2;
    localparam integer COUNT_WIDTH = $clog2(TIMEOUT_CYCLES + 1);
    localparam [COUNT_WIDTH-1:0] LAST_CYCLE = TIMEOUT_CYCLES - 1;
    reg [1:0] state_reg = IDLE;
    reg [COUNT_WIDTH-1:0] count_reg = {COUNT_WIDTH{1'b0}};
    reg [31:0] request_address_reg = 32'd0;
    reg request_toggle_reg = 1'b0;
    reg [31:0] result_reg = 32'd0;
    reg result_error_reg = 1'b0;
    reg poisoned_reg = 1'b0;
    reg canceled_reg = 1'b0;
    (* async_reg = "true" *) reg [1:0] response_sync = 2'b00;
    (* async_reg = "true" *) reg [1:0] request_sync = 2'b00;
    reg response_toggle_reg = 1'b0;
    reg [31:0] response_data_reg = 32'd0;
    reg response_error_reg = 1'b0;
    reg data_phase_reg = 1'b0;
    reg write_phase_reg = 1'b0;
    reg [30:0] ahb_address_reg = 31'd0;
    reg [2:0] ahb_size_reg = 3'd0;
    reg [31:0] ahb_read_reg;
    wire pending;
    wire request;
    wire response_write;

    assign request = cyc_i && stb_i && !rst;
    assign pending = request_sync[1] != response_toggle_reg;
    assign response_write = data_phase_reg && write_phase_reg && pending;
    assign ack_o = state_reg == RESPONSE && request && !canceled_reg && !result_error_reg;
    assign error_o = state_reg == RESPONSE && request && !canceled_reg && result_error_reg;
    assign data_o = result_reg;
    assign hrdata_o = ahb_read_reg;
    assign hresp_o = 2'b00;
    assign hready_o = 1'b1;

    // Address/data buses remain stable from before the toggle until its reply.
    // Both domains must be reset together; top-level reset holds for 1024 clocks.
    always @(posedge clk) begin
        response_sync <= {response_sync[0], response_toggle_reg};
        if (rst) begin
            state_reg <= IDLE;
            count_reg <= {COUNT_WIDTH{1'b0}};
            request_address_reg <= 32'd0;
            request_toggle_reg <= 1'b0;
            result_reg <= 32'd0;
            result_error_reg <= 1'b0;
            poisoned_reg <= 1'b0;
            canceled_reg <= 1'b0;
            response_sync <= 2'b00;
        end else begin
            case (state_reg)
                IDLE: if (request) begin
                    result_error_reg <= 1'b0;
                    canceled_reg <= 1'b0;
                    if (we_i || address_i[29:22] != 8'h20 || poisoned_reg) begin
                        result_error_reg <= 1'b1;
                        state_reg <= RESPONSE;
                    end else begin
                        request_address_reg <= {address_i, 2'b00};
                        request_toggle_reg <= !request_toggle_reg;
                        count_reg <= {COUNT_WIDTH{1'b0}};
                        state_reg <= WAIT;
                    end
                end
                WAIT: begin
                    if (!request) canceled_reg <= 1'b1;
                    if (response_sync[1] == request_toggle_reg) begin
                        result_reg <= response_data_reg;
                        result_error_reg <= response_error_reg;
                        state_reg <= RESPONSE;
                    end else if (count_reg == LAST_CYCLE) begin
                        result_error_reg <= 1'b1;
                        poisoned_reg <= 1'b1;
                        state_reg <= RESPONSE;
                    end else count_reg <= count_reg + 1'b1;
                end
                RESPONSE: state_reg <= IDLE;
                default: state_reg <= IDLE;
            endcase
        end
    end

    // AHB address/control are captured separately from the following data phase.
    // 0: pending, 4: stable absolute XIP address, 8: write response word.
    always @* begin
        ahb_read_reg = 32'd0;
        if (data_phase_reg && !write_phase_reg && ahb_size_reg == 3'b010) begin
            case (ahb_address_reg)
                31'd0: ahb_read_reg = {31'd0, pending};
                31'd4: ahb_read_reg = request_address_reg;
                default: ahb_read_reg = 32'd0;
            endcase
        end
    end

    always @(posedge clk_ahb) begin
        request_sync <= {request_sync[0], request_toggle_reg};
        if (rst_ahb) begin
            request_sync <= 2'b00;
            response_toggle_reg <= 1'b0;
            response_data_reg <= 32'd0;
            response_error_reg <= 1'b0;
            data_phase_reg <= 1'b0;
            write_phase_reg <= 1'b0;
            ahb_address_reg <= 31'd0;
            ahb_size_reg <= 3'd0;
        end else begin
            data_phase_reg <= htrans_i[1];
            write_phase_reg <= hwrite_i;
            ahb_address_reg <= haddr_i;
            ahb_size_reg <= hsize_i;
            if (response_write) begin
                response_data_reg <= hwdata_i;
                response_error_reg <= ahb_address_reg != 31'd8 || ahb_size_reg != 3'b010;
                response_toggle_reg <= request_sync[1];
            end
        end
    end
endmodule
`resetall
