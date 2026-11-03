// -----------------------------------------------------------------------------
// File   : npu_ddr_read_bridge.v
// Author : Codex
// Date   : 2026-09-12
// Description: One-request bundled-data CDC, 16-bit NPU ABI to 128-bit DDR.
// Change Log: 2026-09-12 v1.0 Four-phase ownership and client-reset cancellation.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none
module npu_ddr_read_bridge (
    input wire clk_npu,
    input wire clk_ddr,
    input wire rst_n,
    input wire i_client_rst_n,
    input wire i_params_ready,
    input wire [22:0] i_size_halfwords,
    output wire o_params_ready_npu,
    output wire o_paused,
    input wire i_req_valid,
    output wire o_req_ready,
    input wire [23:0] i_req_addr,
    input wire [15:0] i_req_len,
    output wire o_rd_valid,
    output wire [15:0] o_rd_data,
    output wire o_ddr_valid,
    input wire i_ddr_ready,
    output wire [24:0] o_ddr_addr,
    input wire i_ddr_rd_valid,
    input wire [127:0] i_ddr_rd_data,
    output wire o_error
);
    localparam [2:0] N_IDLE=3'd0, N_WAIT=3'd1, N_LOW=3'd2, N_HIGH=3'd3, N_DRAIN=3'd4;
    localparam [1:0] D_IDLE=2'd0, D_REQ=2'd1, D_WAIT=2'd2, D_DONE=2'd3;
    reg [2:0] nstate_reg;
    reg [1:0] dstate_reg;
    reg request_reg, done_reg, cancel_reg, valid_reg, error_reg;
    reg [23:0] address_reg;
    reg [15:0] length_reg, data_reg;
    reg [31:0] response_reg;
    (* async_reg="true" *) reg [1:0] request_sync, done_sync, ready_sync, paused_sync;
    wire address_ok = address_reg >= 24'hc00000 && !address_reg[0] && length_reg==16'd2 &&
                      {1'b0,address_reg[21:0]} < i_size_halfwords;
    wire paused_npu = !ready_sync[1] && nstate_reg==N_IDLE && !request_reg && !done_sync[1];
    // Logical c00000..ffffff halfwords map to native 1800000..1bfffff,
    // an 8 MiB reservation above all four existing video frame buffers.
    assign o_ddr_addr = 25'h1800000 + {3'd0,address_reg[21:3],3'b000};
    assign o_ddr_valid = dstate_reg==D_REQ;
    assign o_req_ready = rst_n && i_client_rst_n && ready_sync[1] && nstate_reg==N_IDLE;
    assign o_params_ready_npu = ready_sync[1];
    assign o_paused = paused_sync[1];
    assign o_rd_valid = valid_reg;
    assign o_rd_data = data_reg;
    assign o_error = error_reg;

    always @(posedge clk_npu or negedge rst_n) begin
        if (!rst_n) begin done_sync<=2'd0; ready_sync<=2'd0; end
        else begin
            done_sync<={done_sync[0],done_reg};
            ready_sync<={ready_sync[0],i_params_ready && !error_reg};
        end
    end
    always @(posedge clk_ddr or negedge rst_n) begin
        if (!rst_n) begin request_sync<=2'd0; paused_sync<=2'd0; end
        else begin
            request_sync<={request_sync[0],request_reg};
            paused_sync<={paused_sync[0],paused_npu};
        end
    end
    // Client reset does NOT reset transport ownership or the global read tags.
    // Finish/drain the old request, suppress its result, then permit a new one.
    always @(posedge clk_npu or negedge rst_n) begin
        if (!rst_n) begin
            nstate_reg<=N_IDLE; request_reg<=1'b0; cancel_reg<=1'b0;
            address_reg<=24'd0; length_reg<=16'd0; valid_reg<=1'b0; data_reg<=16'd0;
        end else begin
            valid_reg<=1'b0;
            if (!i_client_rst_n || !ready_sync[1]) cancel_reg<=1'b1;
            case(nstate_reg)
                N_IDLE: if (i_req_valid && o_req_ready) begin
                    address_reg<=i_req_addr; length_reg<=i_req_len;
                    request_reg<=1'b1; cancel_reg<=1'b0; nstate_reg<=N_WAIT;
                end
                N_WAIT: if (done_sync[1]) begin
                    if (cancel_reg || !i_client_rst_n || !ready_sync[1]) begin
                        request_reg<=1'b0; nstate_reg<=N_DRAIN;
                    end else nstate_reg<=N_LOW;
                end
                N_LOW: begin
                    if (!cancel_reg && i_client_rst_n && ready_sync[1]) begin
                        valid_reg<=1'b1; data_reg<=response_reg[15:0];
                    end
                    nstate_reg<=N_HIGH;
                end
                N_HIGH: begin
                    if (!cancel_reg && i_client_rst_n && ready_sync[1]) begin
                        valid_reg<=1'b1; data_reg<=response_reg[31:16];
                    end
                    request_reg<=1'b0; nstate_reg<=N_DRAIN;
                end
                N_DRAIN: if (!done_sync[1]) nstate_reg<=N_IDLE;
                default: nstate_reg<=N_IDLE;
            endcase
        end
    end
    always @(posedge clk_ddr or negedge rst_n) begin
        if (!rst_n) begin
            dstate_reg<=D_IDLE; done_reg<=1'b0; response_reg<=32'd0; error_reg<=1'b0;
        end else begin
            if (!i_params_ready) error_reg<=1'b0;
            case(dstate_reg)
                D_IDLE: if (request_sync[1]) begin
                    if (!i_params_ready || !address_ok) begin
                        response_reg<=32'd0; done_reg<=1'b1; dstate_reg<=D_DONE;
                        if (i_params_ready && !address_ok) error_reg<=1'b1;
                    end else dstate_reg<=D_REQ;
                end
                D_REQ: if (i_ddr_ready) dstate_reg<=D_WAIT;
                D_WAIT: if (i_ddr_rd_valid) begin
                    response_reg<=i_ddr_rd_data[address_reg[2:0]*16 +: 32];
                    done_reg<=1'b1; dstate_reg<=D_DONE;
                end
                D_DONE: if (!request_sync[1]) begin done_reg<=1'b0; dstate_reg<=D_IDLE; end
                default: dstate_reg<=D_IDLE;
            endcase
        end
    end
endmodule
`resetall
