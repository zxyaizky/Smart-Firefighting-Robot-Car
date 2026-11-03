// DDR-side 16-byte read buffer and word selector. The native arbiter holds
// its last CPU read line until the next native request; video does not alter it.
`resetall
`timescale 1ns/1ps
`default_nettype none
module cpu_ddr_word_service #(
    parameter [24:0] CPU_NATIVE_BASE = 25'h1000000,
    parameter integer NATIVE_WORD_RESPONSE = 0,
    parameter integer NATIVE_WORD_REQUEST = 0
)(
    input wire clk, rst,
    input wire backend_ready_i, backend_error_i,
    input wire req_valid_i,
    output wire req_ready_o,
    // {write, native_address[24:0], write_word[31:0], select[3:0], lane[1:0]}.
    input wire [63:0] req_payload_i,
    output wire rsp_valid_o,
    input wire rsp_ready_i,
    output wire [32:0] rsp_payload_o,
    output wire native_req_valid_o,
    input wire native_req_ready_i,
    output wire native_req_write_o,
    output wire [24:0] native_req_addr_o,
    output wire [(NATIVE_WORD_REQUEST ? 32 : 128)-1:0] native_req_wdata_o,
    output wire [(NATIVE_WORD_REQUEST ? 4 : 16)-1:0] native_req_mask_o,
    input wire native_rsp_valid_i,
    output wire native_rsp_ready_o,
    input wire native_rsp_error_i,
    input wire [(NATIVE_WORD_RESPONSE ? 32 : 128)-1:0] native_rsp_rdata_i,
    output wire [1:0] native_rsp_lane_o
);
    localparam [1:0] IDLE=2'd0, SEND=2'd1, WAIT_RESPONSE=2'd2, REPLY=2'd3;
    reg [1:0] state_reg=IDLE;
    reg [63:0] request_payload_reg=64'd0;
    reg [32:0] word_response_payload_reg=33'd0;
    reg cache_valid_reg=1'b0;
    reg [21:0] cache_tag_reg=22'd0;
    reg backend_fault_reg=1'b0;
    wire address_legal = req_payload_i[62:38] >= CPU_NATIVE_BASE &&
                         req_payload_i[40:38] == 3'd0;
    wire cache_hit = cache_valid_reg && backend_ready_i && !backend_error_i &&
                     !req_payload_i[63] && address_legal &&
                     cache_tag_reg == req_payload_i[62:41];
    function [31:0] word_from_line;
        input [127:0] line;
        input [1:0] lane;
        begin
            case(lane)
                2'd0: word_from_line=line[31:0];
                2'd1: word_from_line=line[63:32];
                2'd2: word_from_line=line[95:64];
                default: word_from_line=line[127:96];
            endcase
        end
    endfunction
    wire [31:0] cache_hit_word, response_word;
    assign native_rsp_lane_o = state_reg == IDLE ? req_payload_i[1:0] : request_payload_reg[1:0];
    generate
        if (NATIVE_WORD_RESPONSE) begin : native_word
            assign cache_hit_word = native_rsp_rdata_i;
            assign response_word = native_rsp_rdata_i;
        end else begin : native_line
            assign cache_hit_word = word_from_line(native_rsp_rdata_i,req_payload_i[1:0]);
            assign response_word = word_from_line(native_rsp_rdata_i,request_payload_reg[1:0]);
        end
    endgenerate
    assign req_ready_o=state_reg==IDLE && !native_rsp_valid_i && !rst;
    assign rsp_valid_o=state_reg==REPLY && !rst;
    assign rsp_payload_o=word_response_payload_reg;
    assign native_req_valid_o=state_reg==SEND && !rst;
    assign native_req_write_o=request_payload_reg[63];
    assign native_req_addr_o=request_payload_reg[62:38];
    generate
        if (NATIVE_WORD_REQUEST) begin : word_request
            assign native_req_wdata_o=request_payload_reg[37:6];
            assign native_req_mask_o=~request_payload_reg[5:2];
        end else begin : line_request
        assign native_req_wdata_o={4{request_payload_reg[37:6]}};
        assign native_req_mask_o[3:0]   = request_payload_reg[1:0]==2'd0 ? ~request_payload_reg[5:2] : 4'hf;
        assign native_req_mask_o[7:4]   = request_payload_reg[1:0]==2'd1 ? ~request_payload_reg[5:2] : 4'hf;
        assign native_req_mask_o[11:8]  = request_payload_reg[1:0]==2'd2 ? ~request_payload_reg[5:2] : 4'hf;
        assign native_req_mask_o[15:12] = request_payload_reg[1:0]==2'd3 ? ~request_payload_reg[5:2] : 4'hf;
        end
    endgenerate
    // Drain an old reply before issuing a new native transaction.
    assign native_rsp_ready_o=state_reg!=REPLY && !rst;
    always @(posedge clk) begin
        case(state_reg)
            IDLE: begin
                if(native_rsp_valid_i) cache_valid_reg<=1'b0;
                if(req_valid_i && req_ready_o) begin
                    request_payload_reg<=req_payload_i;
                    backend_fault_reg<=!backend_ready_i || backend_error_i;
                    if(!address_legal || !backend_ready_i || backend_error_i) begin
                        word_response_payload_reg<={1'b1,32'd0};
                        cache_valid_reg<=1'b0;
                        state_reg<=REPLY;
                    end else if(cache_hit) begin
                        word_response_payload_reg<={1'b0,cache_hit_word};
                        state_reg<=REPLY;
                    end else begin
                        cache_valid_reg<=1'b0;
                        state_reg<=SEND;
                    end
                end
            end
            SEND: begin
                // Never withdraw a stalled native VALID, including on faults.
                if(native_req_ready_i) state_reg<=WAIT_RESPONSE;
            end
            WAIT_RESPONSE: begin
                if(native_rsp_valid_i) begin
                    word_response_payload_reg<=
                        {native_rsp_error_i || backend_fault_reg || !backend_ready_i || backend_error_i,
                         response_word};
                    if(!native_rsp_error_i && !backend_fault_reg && backend_ready_i && !backend_error_i &&
                       !request_payload_reg[63]) begin
                        cache_valid_reg<=1'b1;
                        cache_tag_reg<=request_payload_reg[62:41];
                    end
                    state_reg<=REPLY;
                end
            end
            REPLY: if(rsp_ready_i) state_reg<=IDLE;
            default: begin state_reg<=IDLE;cache_valid_reg<=1'b0;end
        endcase
        if(!backend_ready_i || backend_error_i) cache_valid_reg<=1'b0;
        if((state_reg==SEND || state_reg==WAIT_RESPONSE) &&
           (!backend_ready_i || backend_error_i)) backend_fault_reg<=1'b1;
        // Only the DDR-domain reset resets this service. A CPU-only reset is
        // handled by the original CDC's stale-reply drain, not a lost request.
        if(rst) begin
            state_reg<=IDLE;
            cache_valid_reg<=1'b0;
        end
    end
endmodule
`resetall
