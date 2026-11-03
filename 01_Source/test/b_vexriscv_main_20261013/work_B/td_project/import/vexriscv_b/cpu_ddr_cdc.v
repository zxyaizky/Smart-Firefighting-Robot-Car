// One-entry, four-phase bundled-data mailbox. No payload is synchronized bitwise.
// Request/response payloads stay held throughout two control synchronizer stages.
// Reset asserts asynchronously across this NEW CDC boundary, releases locally.
// A source-only reset abandons its reply; stray old downstream replies are drained.
`resetall
`timescale 1ns/1ps
`default_nettype none
module cpu_ddr_cdc #
(
    // {write,native_address[24:0],write_data[127:0],active_high_mask[15:0]}.
    parameter integer REQUEST_WIDTH = 170,
    // {error,read_data[127:0]}.
    parameter integer RESPONSE_WIDTH = 129,
    // The actual native arbiter holds its reply until the NEXT request.
    // Default buffering preserves the generic ready/valid interface contract.
    parameter integer RESPONSE_HELD_BY_TARGET = 0,
    // Receiver latches the held request on its ready/valid handshake. This
    // mode requires a receiver-local holding bank that survives source reset.
    parameter integer REQUEST_CAPTURED_BY_TARGET = 0
)
(
    input  wire s_clk,
    input  wire s_rst,
    input  wire m_clk,
    input  wire m_rst,
    input  wire s_req_valid_i,
    output wire s_req_ready_o,
    input  wire [REQUEST_WIDTH-1:0] s_req_payload_i,
    output wire s_rsp_valid_o,
    input  wire s_rsp_ready_i,
    output wire [RESPONSE_WIDTH-1:0] s_rsp_payload_o,
    output wire m_req_valid_o,
    input  wire m_req_ready_i,
    output wire [REQUEST_WIDTH-1:0] m_req_payload_o,
    input  wire m_rsp_valid_i,
    output wire m_rsp_ready_o,
    input  wire [RESPONSE_WIDTH-1:0] m_rsp_payload_i,
    output wire link_ready_o
);
    localparam [1:0] S_IDLE=2'd0, S_WAIT=2'd1, S_REPLY=2'd2, S_DROP=2'd3;
    localparam [1:0] M_IDLE=2'd0, M_ISSUE=2'd1, M_WAIT=2'd2, M_HOLD=2'd3;
    wire reset_any;
    reg [1:0] s_release_reg=2'b11;
    reg [1:0] m_release_reg=2'b11;
    reg [1:0] s_state_reg=S_IDLE, s_state_next;
    reg [1:0] m_state_reg=M_IDLE, m_state_next;
    reg request_level_reg=1'b0;
    reg acknowledge_level_reg=1'b0;
    (* async_reg="true" *) reg [1:0] request_sync_reg=2'b00;
    (* async_reg="true" *) reg [1:0] acknowledge_sync_reg=2'b00;
    (* async_reg="true" *) reg [1:0] online_sync_reg=2'b00;
    reg m_online_reg=1'b0;
    reg [REQUEST_WIDTH-1:0] request_hold_reg={REQUEST_WIDTH{1'b0}};


    assign reset_any=s_rst || m_rst;
    assign link_ready_o=online_sync_reg[1] && !s_release_reg[1] && !reset_any;
    assign s_req_ready_o=s_state_reg==S_IDLE && link_ready_o && !acknowledge_sync_reg[1];
    assign s_rsp_valid_o=s_state_reg==S_REPLY && !s_release_reg[1] && !reset_any;
    generate
        if (RESPONSE_HELD_BY_TARGET) begin : held_target_response
            // Native reply storage is the bundled-data holding bank.
            assign s_rsp_payload_o=m_rsp_payload_i;
        end else begin : buffered_target_response
            reg [RESPONSE_WIDTH-1:0] response_hold_reg={RESPONSE_WIDTH{1'b0}};
            assign s_rsp_payload_o=response_hold_reg;
            always @(posedge m_clk) begin
                if (!reset_any && !m_release_reg[1] &&
                    m_state_reg==M_WAIT && m_rsp_valid_i)
                    response_hold_reg<=m_rsp_payload_i;
            end
        end
    endgenerate
    assign m_req_valid_o=m_state_reg==M_ISSUE && !m_release_reg[1] && !reset_any;
    generate
        if(REQUEST_CAPTURED_BY_TARGET) begin : target_captured_request
            assign m_req_payload_o=request_hold_reg;
        end else begin : buffered_destination_request
            reg [REQUEST_WIDTH-1:0] destination_request_reg={REQUEST_WIDTH{1'b0}};
            assign m_req_payload_o=destination_request_reg;
            always @(posedge m_clk) begin
                if(!reset_any && !m_release_reg[1] &&
                   m_state_reg==M_IDLE && request_sync_reg[1])
                    destination_request_reg<=request_hold_reg;
            end
        end
    endgenerate
    // Native arbiter is single-transaction: an old reply must be drained before
    // it accepts the new request. Never capture such a reply as the new one.
    assign m_rsp_ready_o=m_state_reg!=M_HOLD;

    always @* begin
        s_state_next=s_state_reg;
        case(s_state_reg)
            S_IDLE: if(s_req_valid_i && s_req_ready_o) s_state_next=S_WAIT;
            S_WAIT: if(acknowledge_sync_reg[1]) s_state_next=S_REPLY;
            S_REPLY: if(s_rsp_ready_i) s_state_next=S_DROP;
            S_DROP: if(!acknowledge_sync_reg[1]) s_state_next=S_IDLE;
            default: s_state_next=S_IDLE;
        endcase
        if(s_release_reg[1]) s_state_next=S_IDLE;
    end
    always @* begin
        m_state_next=m_state_reg;
        case(m_state_reg)
            M_IDLE: if(request_sync_reg[1]) m_state_next=M_ISSUE;
            M_ISSUE: if(m_req_ready_i) m_state_next=M_WAIT;
            M_WAIT: if(m_rsp_valid_i) m_state_next=M_HOLD;
            M_HOLD: if(!request_sync_reg[1]) m_state_next=M_IDLE;
            default: m_state_next=M_IDLE;
        endcase
        if(m_release_reg[1]) m_state_next=M_IDLE;
    end
    always @(posedge s_clk or posedge reset_any) begin
        if(reset_any) begin
            s_release_reg<=2'b11;
            s_state_reg<=S_IDLE;
            request_level_reg<=1'b0;
            acknowledge_sync_reg<=2'b00;
            online_sync_reg<=2'b00;
        end else begin
            s_release_reg<={s_release_reg[0],1'b0};
            s_state_reg<=s_state_next;
            acknowledge_sync_reg<={acknowledge_sync_reg[0],acknowledge_level_reg};
            online_sync_reg<={online_sync_reg[0],m_online_reg};
            if(s_state_reg==S_IDLE && s_req_valid_i && s_req_ready_o) request_level_reg<=1'b1;
            if(s_state_reg==S_REPLY && s_rsp_ready_i) request_level_reg<=1'b0;
            if(s_release_reg[1]) request_level_reg<=1'b0;
        end
    end
    always @(posedge m_clk or posedge reset_any) begin
        if(reset_any) begin
            m_release_reg<=2'b11;
            m_state_reg<=M_IDLE;
            acknowledge_level_reg<=1'b0;
            request_sync_reg<=2'b00;
            m_online_reg<=1'b0;
        end else begin
            m_release_reg<={m_release_reg[0],1'b0};
            m_state_reg<=m_state_next;
            request_sync_reg<={request_sync_reg[0],request_level_reg};
            m_online_reg<=!m_release_reg[1];
            if(m_state_reg==M_WAIT && m_rsp_valid_i) acknowledge_level_reg<=1'b1;
            if(m_state_reg==M_HOLD && !request_sync_reg[1]) acknowledge_level_reg<=1'b0;
            if(m_release_reg[1]) acknowledge_level_reg<=1'b0;
        end
    end
    // Data banks have no runtime reset. Their valid/ownership flags above do.
    always @(posedge s_clk) begin
        if(!reset_any && !s_release_reg[1]) begin
            if(s_req_valid_i && s_req_ready_o) request_hold_reg<=s_req_payload_i;
        end
    end
endmodule
`resetall
