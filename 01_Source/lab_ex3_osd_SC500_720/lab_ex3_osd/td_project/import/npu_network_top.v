// -----------------------------------------------------------------------------
// File: npu_network_top.v | Author: Codex | Date: 2026-09-08
// Description: Generated descriptor boot, RGB CHW input and fire-only winner.
// Change Log: v1.0 Test-parameter 12-layer network integration (RTL validation).
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none
module npu_network_top #(
    parameter integer PARAM_ADDR_W = 21,
    parameter integer PING_BANK_DEPTH = 3600,
    parameter integer PONG_BANK_DEPTH = 5120,
    parameter [23:0] PARAM_BASE_16 = 24'hc00000
)(
    input wire clk,
    input wire rst_n,
    input wire i_frame_valid,
    input wire i_byte_valid,
    input wire [7:0] i_byte,
    output wire o_input_busy,
    output wire o_model_ready,
    output wire o_tile_ready,
    output wire o_tile_done,
    output wire o_tile_error,
    output wire o_layer_done,
    output wire o_inference_done,
    output wire o_tensor_valid,
    output wire [63:0] o_tensor_data,
    output wire [7:0] o_tensor_x,
    output wire [7:0] o_tensor_y,
    output wire o_sdram_rd_req_valid,
    input wire i_sdram_rd_req_ready,
    output wire [23:0] o_sdram_rd_addr,
    output wire [15:0] o_sdram_rd_len_halfwords,
    input wire [15:0] i_sdram_rd_data,
    input wire i_sdram_rd_valid,
    // Latency profiling readout.  i_dbg_perf_sel selects a statistic, the
    // matching NPU-cycle value appears on o_dbg_perf_data.  See the selector
    // table in npu_perf_profiler.v.  Tied off in a board build that does not
    // consume the numbers.
    input  wire [5:0]  i_dbg_perf_sel,
    output wire [31:0] o_dbg_perf_data
);
    // Pure Verilog case ROM generated alongside the binary/hex parameter image.
    // Parameters are TEST ONLY; this boot path does not imply trained recognition.
`ifdef NPU_TEST_MODEL
    `include "npu_test_model_config.vh"
`else
    `include "npu_model_config.vh"
`endif
`ifdef NPU_TEST_MODEL
    localparam integer MODEL_PONG_LARGE_BANKS = 16;
    localparam integer MODEL_PONG_SMALL_BANK_DEPTH = PONG_BANK_DEPTH;
`else
    // Production L0 has Cout=8. Lanes 8..15 are inactive at the only 4800-deep
    // layer; all later even layers need at most 1200 addresses on those lanes.
    localparam integer MODEL_PONG_LARGE_BANKS = 8;
    // Banks 8..15 are unused by L0 (Cout=8).  The first layer that writes
    // them is L2: two 20x15 output groups, hence 600 addresses maximum.
    localparam integer MODEL_PONG_SMALL_BANK_DEPTH = 600;
`endif
    reg [7:0] boot_address_reg;
    reg model_ready_reg;
    wire core_busy;
    wire tensor_valid;
    wire [127:0] tensor_data;
    reg input_frame_reg, input_admitted_reg;
    wire input_admitted = input_frame_reg ? input_admitted_reg :
        (model_ready_reg && !core_busy);
    wire desc_write = rst_n && !model_ready_reg;
    wire [31:0] desc_data = model_descriptor(boot_address_reg);
    assign o_model_ready = model_ready_reg;
    assign o_input_busy = !model_ready_reg || core_busy;
    assign o_tensor_valid = tensor_valid;
    // {gy,gx,fire,h,w,dy,dx,obj}; hardware still uses 16 lanes internally.
    assign o_tensor_data = tensor_data[63:0];
    assign o_tensor_x = tensor_data[55:48];
    assign o_tensor_y = tensor_data[63:56];

    // A source frame that starts during descriptor boot is rejected in full.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_frame_reg <= 1'b0;
            input_admitted_reg <= 1'b0;
        end else begin
            input_frame_reg <= i_frame_valid;
            if (!i_frame_valid) input_admitted_reg <= 1'b0;
            else if (!input_frame_reg)
                input_admitted_reg <= model_ready_reg && !core_busy;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            boot_address_reg <= 8'd0;
            model_ready_reg <= 1'b0;
        end else if (!model_ready_reg) begin
            if (boot_address_reg == 8'd255)
                model_ready_reg <= 1'b1;
            else boot_address_reg <= boot_address_reg + 8'd1;
        end
    end
    npu_top_with_sdram_dma #(
        .USE_DESC_RAM(1'b1), .PARAM_ADDR_W(PARAM_ADDR_W),
        .PING_BANK_DEPTH(PING_BANK_DEPTH), .PONG_BANK_DEPTH(PONG_BANK_DEPTH),
        .PONG_LARGE_BANKS(MODEL_PONG_LARGE_BANKS),
        .PONG_SMALL_BANK_DEPTH(MODEL_PONG_SMALL_BANK_DEPTH),
        .INPUT_FRAME_BYTES(57600), .PARAM_BASE_16(PARAM_BASE_16)
    ) u_npu (
        .clk(clk), .rst_n(rst_n),
        .i_frame_valid(i_frame_valid && input_admitted),
        .i_lbp_valid(i_byte_valid && input_admitted), .i_lbp_pixel(i_byte),
        .o_input_busy(core_busy), .o_tile_ready(o_tile_ready), .o_tile_done(o_tile_done),
        .o_tile_error(o_tile_error), .o_layer_done(o_layer_done),
        .i_desc_we(desc_write), .i_desc_layer(boot_address_reg[7:3]),
        .i_desc_word(boot_address_reg[2:0]), .i_desc_wdata(desc_data),
        .i_layer_count(MODEL_LAYER_COUNT[5:0]), .i_desc_mode(1'b1),
        .o_result_stream_valid(tensor_valid), .o_result_stream_data(tensor_data),
        .o_inference_done(o_inference_done), .o_bbox_valid(), .o_bbox_data(),
        .o_sdram_rd_req_valid(o_sdram_rd_req_valid),
        .i_sdram_rd_req_ready(i_sdram_rd_req_ready), .o_sdram_rd_addr(o_sdram_rd_addr),
        .o_sdram_rd_len_halfwords(o_sdram_rd_len_halfwords),
        .i_sdram_rd_data(i_sdram_rd_data), .i_sdram_rd_valid(i_sdram_rd_valid),
        .i_num4_sel(7'd0),
        .i_dbg_perf_sel(i_dbg_perf_sel),
        .o_dbg_perf_data(o_dbg_perf_data)
    );
endmodule
`resetall
