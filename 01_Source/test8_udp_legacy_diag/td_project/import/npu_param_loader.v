// -----------------------------------------------------------------------------
// File   : npu_param_loader.v
// Author : Codex
// Date   : 2026-09-12
// Description: Sequential 128-bit parameter upload with CRC32 DDR readback.
// Change Log: 2026-09-12 v1.0 Pause NPU, write entire image, verify before release.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none
module npu_param_loader (
    input wire clk,
    input wire rst_n,
    input wire i_begin_valid,
    output wire o_begin_ready,
    input wire [23:0] i_size_bytes,
    input wire [31:0] i_crc32,
    input wire i_data_valid,
    output wire o_data_ready,
    input wire [127:0] i_data,
    input wire i_last,
    input wire i_npu_paused,
    output wire o_params_ready,
    output wire [22:0] o_size_halfwords,
    output wire o_busy,
    output wire o_error,
    output wire o_port_valid,
    output wire o_port_read,
    output wire [24:0] o_port_addr,
    output wire [127:0] o_port_data,
    input wire i_port_ready,
    input wire i_write_done,
    input wire i_read_valid,
    input wire [127:0] i_read_data
);
    localparam [2:0] IDLE=3'd0, PAUSE=3'd1, WRITE=3'd2, WRITE_WAIT=3'd3,
                     READ=3'd4, READ_WAIT=3'd5, READY=3'd6, ERROR=3'd7;
    reg [2:0] state_reg;
    reg [19:0] blocks_reg, index_reg;
    reg [31:0] expected_crc_reg, crc_reg;
    reg [127:0] crc_data_reg;
    reg [3:0] crc_steps_reg;
    reg bad_last_reg, write_done_seen_reg;
    wire final_block = index_reg==blocks_reg-20'd1;
    // Reflected CRC-32/ISO-HDLC, identical to Python zlib.crc32 on file bytes.
    // File byte zero occupies data[7:0]; no video RGB byte-order convention here.
    function [31:0] crc16_step;
        input [31:0] crc;
        input [15:0] data;
        reg [31:0] c;
        integer b;
        begin
            c=crc;
            for(b=0;b<16;b=b+1)
                c=(c>>1)^((c[0]^data[b]) ? 32'hedb88320 : 32'd0);
            crc16_step=c;
        end
    endfunction
    // Parameter loading is outside the real-time inference path.  Process one
    // 128-bit block as eight 16-bit CRC steps, preserving the exact reflected
    // bit order while replacing the fully-unrolled 128-bit XOR network.
    wire [31:0] crc_step_value = crc16_step(crc_reg, crc_data_reg[15:0]);
    assign o_size_halfwords = {blocks_reg,3'd0};
    assign o_begin_ready = rst_n && (state_reg==IDLE || state_reg==READY || state_reg==ERROR);
    assign o_data_ready = rst_n && state_reg==WRITE && i_port_ready;
    assign o_params_ready = state_reg==READY;
    assign o_busy = !o_begin_ready;
    assign o_error = state_reg==ERROR;
    assign o_port_valid = rst_n && ((state_reg==WRITE && i_data_valid) || state_reg==READ);
    assign o_port_read = state_reg==READ;
    assign o_port_addr = 25'h1800000 + {2'd0,index_reg,3'd0};
    assign o_port_data = i_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg<=IDLE; blocks_reg<=20'd0; index_reg<=20'd0;
            expected_crc_reg<=32'd0; crc_reg<=32'hffffffff;
            crc_data_reg<=128'd0; crc_steps_reg<=4'd0;
            bad_last_reg<=1'b0; write_done_seen_reg<=1'b0;
        end else begin
            if (i_begin_valid && o_begin_ready) begin
                blocks_reg<=i_size_bytes[23:4]; index_reg<=20'd0;
                expected_crc_reg<=i_crc32; crc_reg<=32'hffffffff;
                crc_data_reg<=128'd0; crc_steps_reg<=4'd0;
                bad_last_reg<=1'b0; write_done_seen_reg<=1'b0;
                if (i_size_bytes==24'd0 || i_size_bytes>24'h800000 || i_size_bytes[3:0]!=4'd0)
                    state_reg<=ERROR;
                else state_reg<=PAUSE;
            end else case(state_reg)
                PAUSE: if (i_npu_paused) state_reg<=WRITE;
                WRITE: if (i_data_valid && o_data_ready) begin
                    crc_data_reg<=i_data;
                    crc_steps_reg<=4'd8;
                    bad_last_reg<=i_last!=final_block;
                    write_done_seen_reg<=1'b0;
                    state_reg<=WRITE_WAIT;
                end
                WRITE_WAIT: begin
                    if (i_write_done)
                        write_done_seen_reg<=1'b1;
                    if (crc_steps_reg!=0) begin
                        crc_reg<=crc_step_value;
                        crc_data_reg<={16'd0,crc_data_reg[127:16]};
                        crc_steps_reg<=crc_steps_reg-4'd1;
                    end
                    if (crc_steps_reg==0 && (write_done_seen_reg || i_write_done)) begin
                        if (bad_last_reg) state_reg<=ERROR;
                        else if (final_block) begin
                            if ((crc_reg^32'hffffffff)!=expected_crc_reg) state_reg<=ERROR;
                            else begin
                                index_reg<=20'd0;
                                crc_reg<=32'hffffffff;
                                state_reg<=READ;
                            end
                        end else begin
                            index_reg<=index_reg+20'd1;
                            state_reg<=WRITE;
                        end
                    end
                end
                READ: if (i_port_ready) state_reg<=READ_WAIT;
                READ_WAIT: begin
                    if (i_read_valid && crc_steps_reg==0) begin
                        crc_data_reg<=i_read_data;
                        crc_steps_reg<=4'd8;
                    end else if (crc_steps_reg!=0) begin
                        crc_reg<=crc_step_value;
                        crc_data_reg<={16'd0,crc_data_reg[127:16]};
                        crc_steps_reg<=crc_steps_reg-4'd1;
                        if (crc_steps_reg==1) begin
                            if (final_block) begin
                                if ((crc_step_value^32'hffffffff)==expected_crc_reg)
                                    state_reg<=READY;
                                else
                                    state_reg<=ERROR;
                            end else begin
                                index_reg<=index_reg+20'd1;
                                state_reg<=READ;
                            end
                        end
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
`resetall
