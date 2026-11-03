// File: cpu_wb_ddr_bridge.v
// Author: Codex
// Date: 2026-10-17
// Description: Single-outstanding, round-robin Wishbone to DDR mailbox bridge.
// Change Log: v1.0 Preserve byte selects, drain canceled/late native responses.
//             v1.1 Finish every WB beat with ERR while native is quarantined.
//             2026-10-17 v1.2 Hold one write word; mask selects its native lane.
`resetall
`timescale 1ns / 1ps
`default_nettype none

module cpu_wb_ddr_bridge #(
    parameter integer TIMEOUT_CYCLES = 1048576,
    // A DDR-side word service supplies the line buffer in this mode.
    parameter WORD_RESPONSE = 0
)(
    input wire clk,
    input wire rst,
    input wire ddr_ready_i,
    input wire ibus_cyc_i,
    input wire ibus_stb_i,
    input wire ibus_we_i,
    input wire [29:0] ibus_adr_i,
    input wire [3:0] ibus_sel_i,
    input wire [2:0] ibus_cti_i,
    input wire [1:0] ibus_bte_i,
    output wire ibus_ack_o,
    output wire ibus_err_o,
    output wire [31:0] ibus_data_o,
    input wire dbus_cyc_i,
    input wire dbus_stb_i,
    input wire dbus_we_i,
    input wire [29:0] dbus_adr_i,
    input wire [31:0] dbus_data_i,
    input wire [3:0] dbus_sel_i,
    input wire [2:0] dbus_cti_i,
    input wire [1:0] dbus_bte_i,
    output wire dbus_ack_o,
    output wire dbus_err_o,
    output wire [31:0] dbus_data_o,
    output wire req_valid_o,
    input wire req_ready_i,
    output wire req_write_o,
    output wire [24:0] req_addr_o,
    output wire [127:0] req_wdata_o,
    output wire [15:0] req_mask_o,
    output wire [1:0] req_lane_o,
    output wire [3:0] req_select_o,
    input wire rsp_valid_i,
    input wire rsp_error_i,
    input wire [(WORD_RESPONSE ? 32 : 128)-1:0] rsp_rdata_i,
    output wire rsp_ready_o,
    output wire busy_o,
    output wire error_o,
    output wire read_done_o,
    output wire write_done_o
);
    localparam [2:0] IDLE = 3'd0, READY = 3'd1, SEND = 3'd2,
        WAIT_RESPONSE = 3'd3, RESPONSE = 3'd4,
        POISON_SEND = 3'd5, POISON_WAIT = 3'd6;
    localparam integer TIMER_WIDTH = TIMEOUT_CYCLES > 1 ?
        $clog2(TIMEOUT_CYCLES) : 1;
    localparam [TIMER_WIDTH-1:0] TIMER_LAST = TIMEOUT_CYCLES > 0 ?
        TIMEOUT_CYCLES - 1 : 0;
    reg [2:0] state_reg = IDLE;
    reg owner_data_reg = 1'b0;
    reg last_owner_data_reg = 1'b1;
    reg [1:0] lane_reg = 2'd0;
    reg write_reg = 1'b0;
    reg [24:0] address_reg = 25'd0;
    reg [31:0] write_word_reg = 32'd0;
    reg [3:0] select_reg = 4'd0;
    reg canceled_reg = 1'b0;
    reg backend_fault_reg = 1'b0;
    reg quarantine_reg = 1'b0;
    reg [TIMER_WIDTH-1:0] timer_reg = {TIMER_WIDTH{1'b0}};
    reg response_reg = 1'b0;
    reg response_error_reg = 1'b0;
    reg [31:0] response_data_reg = 32'd0;
    reg error_reg = 1'b0;
    reg read_done_reg = 1'b0;
    reg write_done_reg = 1'b0;
    reg buffer_valid_reg = 1'b0;
    reg [21:0] buffer_tag_reg = 22'd0;
    reg [127:0] buffer_data_reg = 128'd0;

    wire irequest = ibus_cyc_i && ibus_stb_i;
    wire drequest = dbus_cyc_i && dbus_stb_i;
    wire choose_data = drequest && (!irequest || !last_owner_data_reg);
    wire owner_live = owner_data_reg ? drequest : irequest;
    wire [31:0] chosen_address = choose_data ? {dbus_adr_i, 2'b00} :
        {ibus_adr_i, 2'b00};
    wire chosen_write = choose_data ? dbus_we_i : ibus_we_i;
    wire [3:0] chosen_select = choose_data ? dbus_sel_i : ibus_sel_i;
    wire [2:0] chosen_cti = choose_data ? dbus_cti_i : ibus_cti_i;
    wire [1:0] chosen_bte = choose_data ? dbus_bte_i : ibus_bte_i;
    wire chosen_legal = chosen_address[31:25] == 7'h20 &&
        chosen_bte == 2'b00 &&
        (chosen_cti == 3'b000 || chosen_cti == 3'b010 || chosen_cti == 3'b111) &&
        (choose_data ? (chosen_select != 4'd0) :
         (!chosen_write && chosen_select == 4'hf));
    // Physical DDR byte offset 32 MiB, native units = two bytes, BL8 aligned.
    wire [24:0] chosen_native = {1'b1, chosen_address[24:4], 3'b000};
    wire chosen_buffer_hit = !WORD_RESPONSE && buffer_valid_reg && ddr_ready_i &&
        !chosen_write && buffer_tag_reg == chosen_native[24:3];
    wire timed_out = timer_reg == TIMER_LAST;

    function [31:0] word_from_line;
        input [127:0] line;
        input [1:0] lane;
        begin
            case (lane)
                2'd0: word_from_line = line[31:0];
                2'd1: word_from_line = line[63:32];
                2'd2: word_from_line = line[95:64];
                default: word_from_line = line[127:96];
            endcase
        end
    endfunction

    assign ibus_ack_o = response_reg && !owner_data_reg && owner_live &&
        !response_error_reg && !canceled_reg && !rst;
    assign ibus_err_o = response_reg && !owner_data_reg && owner_live &&
        response_error_reg && !canceled_reg && !rst;
    assign dbus_ack_o = response_reg && owner_data_reg && owner_live &&
        !response_error_reg && !canceled_reg && !rst;
    assign dbus_err_o = response_reg && owner_data_reg && owner_live &&
        response_error_reg && !canceled_reg && !rst;
    assign ibus_data_o = response_data_reg;
    assign dbus_data_o = response_data_reg;
    assign req_valid_o = (state_reg == SEND || state_reg == POISON_SEND) && !rst;
    assign req_write_o = write_reg;
    assign req_addr_o = address_reg;
    // Inactive native bytes are masked; identical lanes avoid four data banks.
    assign req_wdata_o = {4{write_word_reg}};
    // Native mask expansion belongs at the local DDR endpoint; the compact
    // CPU mailbox transports only the original four byte enables and lane.
    assign req_select_o = select_reg;
    assign req_mask_o[3:0]   = lane_reg==2'd0 ? ~select_reg : 4'hf;
    assign req_mask_o[7:4]   = lane_reg==2'd1 ? ~select_reg : 4'hf;
    assign req_mask_o[11:8]  = lane_reg==2'd2 ? ~select_reg : 4'hf;
    assign req_mask_o[15:12] = lane_reg==2'd3 ? ~select_reg : 4'hf;
    assign req_lane_o = lane_reg;
    wire [127:0] response_line = rsp_rdata_i;
    assign rsp_ready_o = (state_reg == WAIT_RESPONSE || state_reg == POISON_WAIT) && !rst;
    assign busy_o = state_reg != IDLE || quarantine_reg;
    assign error_o = error_reg;
    assign read_done_o = read_done_reg;
    assign write_done_o = write_done_reg;

    // All backend payload registers remain unchanged while SEND is stalled.
    // A timeout poisons the channel until reset; a previously asserted valid
    // remains asserted and its eventual response is drained, never reassigned.
    always @(posedge clk) begin
        response_reg <= 1'b0;
        read_done_reg <= 1'b0;
        write_done_reg <= 1'b0;
        if ((state_reg == READY || state_reg == SEND || state_reg == WAIT_RESPONSE) && !timed_out)
            timer_reg <= timer_reg + 1'b1;
        if (state_reg != IDLE && state_reg != RESPONSE) begin
            if (!owner_live) canceled_reg <= 1'b1;
            if (!ddr_ready_i) backend_fault_reg <= 1'b1;
        end
        case (state_reg)
            IDLE: begin
                if (irequest || drequest) begin
                    owner_data_reg <= choose_data;
                    last_owner_data_reg <= choose_data;
                    canceled_reg <= 1'b0;
                    backend_fault_reg <= 1'b0;
                    timer_reg <= {TIMER_WIDTH{1'b0}};
                    lane_reg <= chosen_address[3:2];
                    write_reg <= chosen_write;
                    address_reg <= chosen_native;
                    write_word_reg <= dbus_data_i;
                    select_reg <= chosen_select;
                    if (chosen_write) buffer_valid_reg <= 1'b0;
                    if (!chosen_legal || quarantine_reg) begin
                        response_error_reg <= 1'b1;
                        response_data_reg <= 32'd0;
                        response_reg <= 1'b1;
                        error_reg <= 1'b1;
                        state_reg <= RESPONSE;
                    end else if (chosen_buffer_hit) begin
                        response_error_reg <= 1'b0;
                        response_data_reg <= word_from_line(buffer_data_reg, chosen_address[3:2]);
                        response_reg <= 1'b1;
                        read_done_reg <= 1'b1;
                        state_reg <= RESPONSE;
                    end else begin
                        state_reg <= READY;
                    end
                end
            end
            READY: begin
                if (!owner_live) begin
                    state_reg <= IDLE;
                end else if (ddr_ready_i) begin
                    // Low ready before submission is expected, not a backend fault.
                    backend_fault_reg <= 1'b0;
                    state_reg <= SEND;
                end else if (timed_out) begin
                    response_error_reg <= 1'b1;
                    response_reg <= 1'b1;
                    error_reg <= 1'b1;
                    quarantine_reg <= 1'b1;
                    state_reg <= RESPONSE;
                end
            end
            SEND: begin
                if (req_ready_i) begin
                    state_reg <= WAIT_RESPONSE;
                end else if (timed_out) begin
                    response_error_reg <= 1'b1;
                    response_reg <= owner_live && !canceled_reg;
                    error_reg <= 1'b1;
                    quarantine_reg <= 1'b1;
                    state_reg <= POISON_SEND;
                end
            end
            WAIT_RESPONSE: begin
                if (rsp_valid_i) begin
                    state_reg <= RESPONSE;
                    response_reg <= owner_live && !canceled_reg;
                    response_error_reg <= rsp_error_i || backend_fault_reg || !ddr_ready_i;
                    response_data_reg <= WORD_RESPONSE ? rsp_rdata_i[31:0] : word_from_line(response_line, lane_reg);
                    if (rsp_error_i || backend_fault_reg || !ddr_ready_i) begin
                        error_reg <= 1'b1;
                        buffer_valid_reg <= 1'b0;
                    end else if (owner_live && !canceled_reg) begin
                        if (write_reg) begin
                            write_done_reg <= 1'b1;
                        end else begin
                            read_done_reg <= 1'b1;
                            if(!WORD_RESPONSE) begin
                                buffer_data_reg <= response_line;
                                buffer_tag_reg <= address_reg[24:3];
                                buffer_valid_reg <= 1'b1;
                            end
                        end
                    end
                end else if (timed_out) begin
                    response_error_reg <= 1'b1;
                    response_reg <= owner_live && !canceled_reg;
                    error_reg <= 1'b1;
                    quarantine_reg <= 1'b1;
                    buffer_valid_reg <= 1'b0;
                    state_reg <= POISON_WAIT;
                end
            end
            RESPONSE: state_reg <= IDLE;
            POISON_SEND, POISON_WAIT: begin
                // A cache-line fill still needs all of its beats terminated
                // after the first ERR. Native quarantine must not block these
                // local error responses while a backend reply never arrives.
                // The response pulse is consumed before another beat is
                // selected; this avoids accepting the previous held address.
                // Do not modify the old native address/data/mask/write fields.
                if (!response_reg && (irequest || drequest)) begin
                    owner_data_reg <= choose_data;
                    last_owner_data_reg <= choose_data;
                    canceled_reg <= 1'b0;
                    response_error_reg <= 1'b1;
                    response_data_reg <= 32'd0;
                    response_reg <= 1'b1;
                end
                if (state_reg == POISON_SEND) begin
                    if (req_ready_i) state_reg <= POISON_WAIT;
                end else if (rsp_valid_i) begin
                    // A response may be emitted above on this same edge.
                    // Keep a response phase so IDLE cannot reaccept that beat.
                    state_reg <= RESPONSE;
                end
            end
            default: begin
                state_reg <= IDLE;
                quarantine_reg <= 1'b1;
                error_reg <= 1'b1;
            end
        endcase
        if (!ddr_ready_i) buffer_valid_reg <= 1'b0;
        if (rst) begin
            state_reg <= IDLE;
            owner_data_reg <= 1'b0;
            last_owner_data_reg <= 1'b1;
            lane_reg <= 2'd0;
            write_reg <= 1'b0;
            address_reg <= 25'd0;
            write_word_reg <= 32'd0;
            select_reg <= 4'd0;
            canceled_reg <= 1'b0;
            backend_fault_reg <= 1'b0;
            quarantine_reg <= 1'b0;
            timer_reg <= {TIMER_WIDTH{1'b0}};
            response_reg <= 1'b0;
            response_error_reg <= 1'b0;
            response_data_reg <= 32'd0;
            error_reg <= 1'b0;
            read_done_reg <= 1'b0;
            write_done_reg <= 1'b0;
            buffer_valid_reg <= 1'b0;
            buffer_tag_reg <= 22'd0;
            buffer_data_reg <= 128'd0;
        end
    end
endmodule

`resetall
