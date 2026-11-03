// -----------------------------------------------------------------------------
// File   : npu_ddr_scheduler.v
// Author : Codex
// Date   : 2026-09-12
// Description: Video-priority DDR command arbitration and ordered read routing.
// Change Log: 2026-09-12 v1.0 Independent command/data acceptance, response tags.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none
module npu_ddr_scheduler (
    input wire clk,
    input wire rst_n,
    input wire i_video_wr,
    input wire i_video_rd,
    input wire [24:0] i_video_addr,
    input wire [127:0] i_video_data,
    output wire o_video_ready,
    output wire o_video_rd_valid,
    output wire [127:0] o_video_rd_data,
    input wire i_load_valid,
    input wire i_load_read,
    input wire [24:0] i_load_addr,
    input wire [127:0] i_load_data,
    output wire o_load_ready,
    output wire o_load_write_done,
    output wire o_load_rd_valid,
    output wire [127:0] o_load_rd_data,
    input wire i_npu_valid,
    input wire [24:0] i_npu_addr,
    output wire o_npu_ready,
    output wire o_npu_rd_valid,
    output wire [127:0] o_npu_rd_data,
    output wire o_app_en,
    output wire [24:0] o_app_addr,
    output wire [2:0] o_app_cmd,
    input wire i_app_read_ready,
    input wire i_app_write_ready,
    output wire o_wdf_valid,
    output wire [127:0] o_wdf_data,
    output wire o_wdf_end,
    output wire [15:0] o_wdf_mask,
    input wire i_wdf_ready,
    input wire i_rd_valid,
    input wire i_rd_end,
    input wire [127:0] i_rd_data,
    output wire o_error
);
    localparam [1:0] OWNER_VIDEO=2'd0, OWNER_LOAD=2'd1, OWNER_NPU=2'd2;
    wire fifo_empty, fifo_afull, fifo_pop;
    wire [154:0] fifo_data;
    reg active_reg, read_reg, cmd_done_reg, data_done_reg;
    reg [1:0] owner_reg;
    reg [24:0] addr_reg;
    reg [127:0] data_reg;
    reg [1:0] tags [0:63];
    reg [5:0] head_reg, tail_reg;
    reg [6:0] count_reg;
    reg error_reg;
    wire tag_space = count_reg < 7'd64;
    wire video_read = fifo_data[153];
    wire video_write = fifo_data[154];
    // Keep the official video FIFO semantics: present the show-ahead head word
    // directly to the DDR interface and remove it only when both native ready
    // inputs are asserted.  Registering fifo_data on the pop edge skips the
    // head word with this SHOW_AHEAD FIFO and also inserts a throughput bubble.
    wire video_select = !active_reg && !fifo_empty &&
                        (!video_read || tag_space);
    wire video_native_ready = (video_read ? i_app_read_ready :
                                            i_app_write_ready) && i_wdf_ready;
    wire video_fire = rst_n && video_select && video_native_ready;
    wire cmd_fire = active_reg && !cmd_done_reg &&
                    (read_reg ? i_app_read_ready : i_app_write_ready);
    wire data_fire = active_reg && !read_reg && !data_done_reg && i_wdf_ready;
    wire complete = active_reg && (cmd_done_reg || cmd_fire) &&
                    (read_reg || data_done_reg || data_fire);
    wire active_read_push = cmd_fire && read_reg;
    wire video_read_push = video_fire && video_read;
    wire tag_push = active_read_push || video_read_push;
    wire [1:0] push_owner = video_read_push ? OWNER_VIDEO : owner_reg;
    wire response_present = count_reg != 7'd0 || tag_push;
    wire tag_pop = i_rd_valid && i_rd_end && response_present;
    // Empty-queue bypass also handles a zero-latency native read response.
    wire [1:0] response_owner = count_reg != 7'd0 ? tags[head_reg] : push_owner;

    assign fifo_pop = video_fire;
    assign o_video_ready = rst_n && !fifo_afull;
    assign o_load_ready = rst_n && !active_reg && fifo_empty &&
                          !i_video_wr && !i_video_rd &&
                          (!i_load_read || tag_space);
    assign o_npu_ready = rst_n && !active_reg && fifo_empty &&
                         !i_video_wr && !i_video_rd && !i_load_valid && tag_space;
    assign o_app_en = rst_n && (active_reg ? !cmd_done_reg : video_fire);
    assign o_app_cmd = active_reg ? (read_reg ? 3'd1 : 3'd0) :
                                   (video_read ? 3'd1 : 3'd0);
    assign o_app_addr = active_reg ? addr_reg : fifo_data[152:128];
    assign o_wdf_valid = rst_n && (active_reg ?
                         (!read_reg && !data_done_reg) :
                         (video_fire && video_write));
    assign o_wdf_data = active_reg ? data_reg : fifo_data[127:0];
    assign o_wdf_end = o_wdf_valid;
    // Native mask: zero enables all sixteen bytes, as in the official path.
    assign o_wdf_mask = 16'd0;
    assign o_load_write_done = complete && !read_reg && owner_reg == OWNER_LOAD;
    assign o_video_rd_valid = rst_n && tag_pop && response_owner == OWNER_VIDEO;
    assign o_load_rd_valid = rst_n && tag_pop && response_owner == OWNER_LOAD;
    assign o_npu_rd_valid = rst_n && tag_pop && response_owner == OWNER_NPU;
    assign o_video_rd_data = i_rd_data;
    assign o_load_rd_data = i_rd_data;
    assign o_npu_rd_data = i_rd_data;
    assign o_error = error_reg;

    // Preserve the official 512-entry command FIFO and its eight-beat grace
    // after almost-full. Arbitration occurs AFTER this queue, never at camera DE.
    w155_d512_fifo video_queue_inst (
        .clk(clk), .rst(~rst_n), .we(rst_n && (i_video_wr || i_video_rd)),
        .di({i_video_wr,i_video_rd,i_video_addr,i_video_data}),
        .afull(fifo_afull), .full_flag(), .wrusedw(), .re(fifo_pop),
        .valid(), .dout(fifo_data), .empty_flag(fifo_empty), .aempty(), .rdusedw()
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_reg<=1'b0; read_reg<=1'b0; owner_reg<=OWNER_VIDEO;
            cmd_done_reg<=1'b0; data_done_reg<=1'b0;
            addr_reg<=25'd0; data_reg<=128'd0;
        end else begin
            if (!active_reg) begin
                cmd_done_reg<=1'b0; data_done_reg<=1'b0;
                if (i_load_valid && o_load_ready) begin
                    active_reg<=1'b1; owner_reg<=OWNER_LOAD;
                    read_reg<=i_load_read; addr_reg<=i_load_addr; data_reg<=i_load_data;
                end else if (i_npu_valid && o_npu_ready) begin
                    active_reg<=1'b1; owner_reg<=OWNER_NPU;
                    read_reg<=1'b1; addr_reg<=i_npu_addr; data_reg<=128'd0;
                end
            end else begin
                if (cmd_fire) cmd_done_reg<=1'b1;
                if (data_fire) data_done_reg<=1'b1;
                if (complete) begin
                    cmd_done_reg<=1'b0;
                    data_done_reg<=1'b0;
                    active_reg<=1'b0;
                end
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_reg<=6'd0; tail_reg<=6'd0; count_reg<=7'd0; error_reg<=1'b0;
        end else begin
            if (tag_push) begin tags[tail_reg]<=push_owner; tail_reg<=tail_reg+6'd1; end
            if (tag_pop) head_reg<=head_reg+6'd1;
            case ({tag_push,tag_pop})
                2'b10: count_reg<=count_reg+7'd1;
                2'b01: count_reg<=count_reg-7'd1;
                default: ;
            endcase
            if ((i_rd_valid && (!response_present || !i_rd_end)) ||
                (i_video_wr && i_video_rd)) error_reg<=1'b1;
        end
    end
endmodule
`resetall
