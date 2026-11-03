// -----------------------------------------------------------------------------
// File   : npu_ddr_subsystem.v
// Author : Codex
// Date   : 2026-09-12
// Description: Shared official-video DDR access, verified upload and NPU CDC.
// Change Log: 2026-09-12 v1.0 Integrate scheduler, loader and read bridge.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none
module npu_ddr_subsystem (
    input wire clk_ddr,
    input wire clk_npu,
    input wire rst_n,
    input wire i_client_rst_n,
    input wire i_video_wr,
    input wire i_video_rd,
    input wire [24:0] i_video_addr,
    input wire [127:0] i_video_data,
    output wire o_video_ready,
    output wire o_video_rd_valid,
    output wire [127:0] o_video_rd_data,
    input wire i_load_begin_valid,
    output wire o_load_begin_ready,
    input wire [23:0] i_load_size_bytes,
    input wire [31:0] i_load_crc32,
    input wire i_load_valid,
    output wire o_load_ready,
    input wire [127:0] i_load_data,
    input wire i_load_last,
    output wire o_load_busy,
    output wire o_load_error,
    output wire o_params_ready_npu,
    input wire i_npu_req_valid,
    output wire o_npu_req_ready,
    input wire [23:0] i_npu_req_addr,
    input wire [15:0] i_npu_req_len,
    output wire o_npu_rd_valid,
    output wire [15:0] o_npu_rd_data,
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
    output wire o_transport_error
);
    (* async_reg="true" *) reg [1:0] reset_sync;
    wire ddr_rst_n;
    wire params_ready, paused, bridge_error, scheduler_error;
    wire [22:0] size_halfwords;
    wire load_valid, load_read, load_ready, load_write_done, load_rd_valid;
    wire [24:0] load_addr, npu_addr;
    wire [127:0] load_data, load_rd_data, npu_rd_data;
    wire npu_valid, npu_ready, npu_rd_valid;
    always @(posedge clk_ddr or negedge rst_n) begin
        if (!rst_n) reset_sync<=2'd0;
        else reset_sync<={reset_sync[0],1'b1};
    end
    assign ddr_rst_n=reset_sync[1];
    assign o_transport_error=bridge_error || scheduler_error;
    npu_param_loader loader_inst (
        .clk(clk_ddr), .rst_n(ddr_rst_n),
        .i_begin_valid(i_load_begin_valid), .o_begin_ready(o_load_begin_ready),
        .i_size_bytes(i_load_size_bytes), .i_crc32(i_load_crc32),
        .i_data_valid(i_load_valid), .o_data_ready(o_load_ready),
        .i_data(i_load_data), .i_last(i_load_last), .i_npu_paused(paused),
        .o_params_ready(params_ready), .o_size_halfwords(size_halfwords),
        .o_busy(o_load_busy), .o_error(o_load_error),
        .o_port_valid(load_valid), .o_port_read(load_read), .o_port_addr(load_addr),
        .o_port_data(load_data), .i_port_ready(load_ready), .i_write_done(load_write_done),
        .i_read_valid(load_rd_valid), .i_read_data(load_rd_data)
    );
    npu_ddr_read_bridge bridge_inst (
        .clk_npu(clk_npu), .clk_ddr(clk_ddr), .rst_n(rst_n),
        .i_client_rst_n(i_client_rst_n), .i_params_ready(params_ready && !scheduler_error),
        .i_size_halfwords(size_halfwords),
        .o_params_ready_npu(o_params_ready_npu), .o_paused(paused),
        .i_req_valid(i_npu_req_valid), .o_req_ready(o_npu_req_ready),
        .i_req_addr(i_npu_req_addr), .i_req_len(i_npu_req_len),
        .o_rd_valid(o_npu_rd_valid), .o_rd_data(o_npu_rd_data),
        .o_ddr_valid(npu_valid), .i_ddr_ready(npu_ready), .o_ddr_addr(npu_addr),
        .i_ddr_rd_valid(npu_rd_valid), .i_ddr_rd_data(npu_rd_data), .o_error(bridge_error)
    );
    npu_ddr_scheduler scheduler_inst (
        .clk(clk_ddr), .rst_n(ddr_rst_n),
        .i_video_wr(i_video_wr), .i_video_rd(i_video_rd),
        .i_video_addr(i_video_addr), .i_video_data(i_video_data),
        .o_video_ready(o_video_ready), .o_video_rd_valid(o_video_rd_valid),
        .o_video_rd_data(o_video_rd_data),
        .i_load_valid(load_valid), .i_load_read(load_read), .i_load_addr(load_addr),
        .i_load_data(load_data), .o_load_ready(load_ready),
        .o_load_write_done(load_write_done), .o_load_rd_valid(load_rd_valid),
        .o_load_rd_data(load_rd_data),
        .i_npu_valid(npu_valid), .i_npu_addr(npu_addr), .o_npu_ready(npu_ready),
        .o_npu_rd_valid(npu_rd_valid), .o_npu_rd_data(npu_rd_data),
        .o_app_en(o_app_en), .o_app_addr(o_app_addr), .o_app_cmd(o_app_cmd),
        .i_app_read_ready(i_app_read_ready), .i_app_write_ready(i_app_write_ready),
        .o_wdf_valid(o_wdf_valid), .o_wdf_data(o_wdf_data), .o_wdf_end(o_wdf_end),
        .o_wdf_mask(o_wdf_mask), .i_wdf_ready(i_wdf_ready),
        .i_rd_valid(i_rd_valid), .i_rd_end(i_rd_end), .i_rd_data(i_rd_data),
        .o_error(scheduler_error)
    );
endmodule
`resetall
