// -----------------------------------------------------------------------------
// File   : bcu.v
// Author : OpenAI Codex (integration changes)
// Date   : 2026-09-07
// -----------------------------------------------------------------------------
// Description:
//   Scan padded halo rectangles per Cin; drain and commit before group completion.
// Change Log:
//   2026-09-08  Codex  v3.0  Limit read issuance to one reserved SRAM response.
//   2026-09-07  Codex  v2.0  Integrate and simulate two-row partial-sum tiling.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Module      : bcu_v2
// Description : NPU 缓存控制单元 (支持 FC 展平伪装与嵌套循环修正)
// -----------------------------------------------------------------------------
module bcu (
    input  wire         clk,
    input  wire         rst_n,

    // Historical layer_done port is a GROUP completion handshake, not layer EOF.
    input  wire         layer_start,
    output reg          layer_done,
    input  wire [7:0]    i_tile_y_base,
    input  wire [7:0]    i_tile_rows,
    input  wire          i_tile_ready,
    input  wire          i_tile_done,
    input  wire          i_tile_error,
    output wire          o_tile_done,
    output wire          o_tile_error,
    output wire          o_npu_pad_zero,

    // Microcode ROM Configs
    input  wire         i_is_fc_mode,     // 1: FC Mode (Flattening), 0: Conv Mode
    input  wire [7:0]   i_cfg_width,      // 物理真实宽度
    input  wire [7:0]   i_cfg_height,     // 物理真实高度
    input  wire [1:0]   i_cfg_kernel,     // 00: 1x1, 10: 3x3
    input  wire         i_cfg_pool_en,    // 1: 2x2 pooling enable
    input  wire         i_cfg_padding_en, // 1: same padding
    input  wire [7:0]   i_cfg_cin_total,  // 物理通道总数

    // Cout 分组控制 (来自 sequencer)
    input  wire [3:0]   i_oc_group_idx,   // 当前输出分组索引

    // Cin 分组控制 (来自 sequencer, Step 14.1b)
    input  wire [5:0]   i_cin_group_idx,        // 当前输入分组索引 (6-bit 支持 ≤ 1024 cin)
    input  wire [4:0]   i_cin_block_size,       // 当前组有效 Cin 通道数 (1..16)
    input  wire         i_is_first_cin_group,   // 当前是 cin_group=0 (需发 is_first_cin)
    input  wire         i_is_last_cin_group,    // 当前是 cin_group=last (需发 is_last_cin 触发 PSUM 输出与回写)

    // Layer-0 packed preload read mode.
    // 默认关闭；仅 layer-0 input preload 使用 packed cross-bank layout:
    // linear = abs_cin * W * H + pixel, bank = linear[3:0], addr = linear >> 4.
    input  wire         i_is_layer0,
    input  wire         i_l0_packed_read_en,

    // SRAM Array Read Interface
    // 读地址 15b：layer-0 读 LBP 输入缓冲区需要覆盖 19200 个地址 (>14b)
    // 高 2 位仅在 layer-0 读 LBP buffer 时使用；fm_bank_array 只取低 13 位
    output wire [14:0]  o_sram_rd_addr,
    output wire         o_sram_rd_en,
    output wire [3:0]   o_sram_cin_idx,   // FM bank 选择 (低4位)
    output wire [7:0]   o_cin_idx_full,   // 完整 Cin 索引 (供 weight_buffer 页深度寻址)

    // SRAM Array Write Interface (NPU 回写地址, 13b 对应 fm_bank_array 深度 8K)
    output wire [12:0]  o_sram_wr_addr,

    // NPU Compute Engine Dataflow Interface
    input  wire         i_npu_in_ready,
    output wire         o_npu_in_valid,
    output wire         o_npu_is_first_cin,
    output wire         o_npu_is_last_cin,
    input  wire         i_npu_out_valid,
    // Global post-pool coordinates determine the physical write address.
    input  wire [7:0]   i_conv_out_x,
    input  wire [7:0]   i_conv_out_y,

    // Includes window/MAC/accumulator/reorder/pool tails, not the PSUM lifetime.
    input  wire         i_pipeline_idle,

    output wire [31:0]  o_dbg0,
    output wire [31:0]  o_dbg1,
    output wire [31:0]  o_dbg2,
    output wire [31:0]  o_dbg3,
    output wire [31:0]  o_dbg4,
    output wire [31:0]  o_dbg5
);

    // Binary state encoding; configuration remains stable until group completion.
    localparam [2:0] ST_IDLE = 3'd0, ST_SETUP = 3'd1, ST_READ = 3'd2,
                     ST_DRAIN = 3'd3, ST_WAIT_WRITE = 3'd4, ST_ERROR = 3'd5;
    reg [2:0] state = ST_IDLE;
    reg [7:0] r_cin_idx = 8'd0;
    reg [8:0] scan_x = 9'd0, scan_y = 9'd0;
    reg [4:0] settle = 5'd0;
    reg [15:0] r_write_cnt = 16'd0;
    reg [23:0] r_global_cnt = 24'd0;
    reg r_rd_en_d1 = 1'b0, r_is_first_d1 = 1'b0, r_is_last_d1 = 1'b0;
    reg pad_zero_d1 = 1'b0, acc_done_seen = 1'b0;
    reg tile_done_reg = 1'b0, error_reg = 1'b0;

    wire [8:0] kernel_span = i_cfg_kernel == 2'b00 ? 9'd0 :
                              (i_cfg_kernel == 2'b01 ? 9'd1 : 9'd2);
    wire [8:0] pad = i_cfg_padding_en && i_cfg_kernel != 2'b00 ? 9'd1 : 9'd0;
    wire [8:0] conv_w = {1'b0, i_cfg_width} + (pad << 1) - kernel_span;
    wire [8:0] conv_h = {1'b0, i_cfg_height} + (pad << 1) - kernel_span;
    wire [8:0] scan_w = i_is_fc_mode ? {1'b0, i_cfg_width} : conv_w + kernel_span;
    wire [8:0] scan_h = i_is_fc_mode ? {1'b0, i_cfg_height} :
                        {1'b0, i_tile_rows} + kernel_span;
    wire [8:0] real_x = scan_x - (i_is_fc_mode ? 9'd0 : pad);
    wire [8:0] real_y = scan_y + (i_is_fc_mode ? 9'd0 : {1'b0, i_tile_y_base}) -
                        (i_is_fc_mode ? 9'd0 : pad);
    wire is_zero = real_x >= {1'b0, i_cfg_width} || real_y >= {1'b0, i_cfg_height};
    wire [15:0] img_pixels = i_cfg_width * i_cfg_height;
    wire [15:0] pixel_offset = real_y * {1'b0, i_cfg_width} + real_x;
    wire [8:0] final_w = i_cfg_pool_en ? conv_w >> 1 : conv_w;
    wire [8:0] final_h = i_cfg_pool_en ? conv_h >> 1 : conv_h;
    wire [15:0] expected_writes = !i_is_last_cin_group ? 16'd0 :
        (i_is_fc_mode ? 16'd1 :
         (i_cfg_pool_en ? final_w * (i_tile_rows >> 1) : conv_w * i_tile_rows));
    wire [23:0] total_reads = scan_w * scan_h * i_cin_block_size;
    wire last_sample = scan_x == scan_w - 9'd1 && scan_y == scan_h - 9'd1;
    wire last_cin = r_cin_idx == {3'd0, i_cin_block_size} - 8'd1;
    // One reserved response at a time. Never stall r_rd_en_d1: its request was
    // already accepted even if downstream ready has since fallen.
    wire fire = state == ST_READ && i_npu_in_ready && !r_rd_en_d1 &&
                !i_tile_error && !error_reg;
    wire config_ok = i_cfg_width != 0 && i_cfg_height != 0 &&
        i_cin_block_size != 0 && i_cin_block_size <= 16 && i_cfg_kernel != 2'b11 &&
        (i_is_fc_mode || (conv_w != 0 && conv_w <= 160 && conv_h != 0 && conv_h <= 255 &&
         i_tile_rows != 0 && i_tile_rows <= 2 && !i_tile_y_base[0] &&
         {1'b0, i_tile_y_base} + {1'b0, i_tile_rows} <= conv_h));
    wire [22:0] group_addr = i_cin_group_idx * img_pixels + pixel_offset;
    wire [9:0] abs_cin = {i_cin_group_idx, 4'd0} + {2'd0, r_cin_idx};
    // CHW byte offset stays wide through the channel multiply (B ends at
    // 57599 for 160x120 RGB). Convert to the physical 16-bank word only here.
    wire [31:0] packed_linear = {22'd0, abs_cin} * {16'd0, img_pixels} +
                                {16'd0, pixel_offset};
    wire packed_mode = i_is_layer0 && i_l0_packed_read_en;
    wire [31:0] wr_addr_full = i_is_fc_mode ? {28'd0, i_oc_group_idx} :
        i_oc_group_idx * final_w * final_h + i_conv_out_y * final_w + i_conv_out_x;

    assign o_sram_rd_addr = is_zero ? 15'd0 :
                           (packed_mode ? packed_linear[18:4] : group_addr[14:0]);
    assign o_sram_rd_en = fire && !is_zero;
    assign o_sram_cin_idx = packed_mode ? packed_linear[3:0] : r_cin_idx[3:0];
    assign o_cin_idx_full = r_cin_idx;
    assign o_sram_wr_addr = wr_addr_full[12:0];
    assign o_npu_in_valid = r_rd_en_d1;
    assign o_npu_is_first_cin = r_is_first_d1;
    assign o_npu_is_last_cin = r_is_last_d1;
    assign o_npu_pad_zero = pad_zero_d1;
    assign o_tile_done = tile_done_reg;
    assign o_tile_error = error_reg;
    assign o_dbg0 = {13'd0, i_pipeline_idle, i_npu_in_ready, r_is_last_d1,
                     r_is_first_d1, r_rd_en_d1, layer_done, state, r_cin_idx};
    assign o_dbg1 = {8'd0, r_global_cnt};
    assign o_dbg2 = {8'd0, total_reads};
    assign o_dbg3 = {r_write_cnt, expected_writes};
    assign o_dbg4 = {i_tile_y_base, i_tile_rows, scan_y[7:0], scan_x[7:0]};
    assign o_dbg5 = {expected_writes, img_pixels};

    always @(posedge clk) begin
        layer_done <= 1'b0;
        tile_done_reg <= 1'b0;
        r_rd_en_d1 <= fire;
        pad_zero_d1 <= is_zero;
        // Flags and the weight index stay on this Cin through the entire drain.
        r_is_first_d1 <= i_is_first_cin_group &&
            (i_is_fc_mode ? r_global_cnt == 0 : r_cin_idx == 0);
        r_is_last_d1 <= i_is_last_cin_group &&
            (i_is_fc_mode ? r_global_cnt == total_reads - 1 : last_cin);
        if (i_tile_done) acc_done_seen <= 1'b1;
        if (i_npu_out_valid) begin
            r_write_cnt <= r_write_cnt + 16'd1;
            if (wr_addr_full >= 8192 || r_write_cnt >= expected_writes) error_reg <= 1'b1;
        end
        case (state)
            ST_IDLE: begin
                if (layer_start) begin
                    r_cin_idx <= 8'd0;
                    scan_x <= 9'd0;
                    scan_y <= 9'd0;
                    r_global_cnt <= 24'd0;
                    r_write_cnt <= 16'd0;
                    acc_done_seen <= 1'b0;
                    settle <= 5'd12;
                    if (!config_ok || (i_is_first_cin_group && !i_tile_ready)) begin
                        error_reg <= 1'b1;
                        state <= ST_ERROR;
                    end else state <= ST_SETUP;
                end
            end
            ST_SETUP: begin
                if (settle != 0) settle <= settle - 5'd1;
                else state <= ST_READ;
            end
            ST_READ: begin
                if (fire) begin
                    // Diagnose physical address overflow before any subsequent work.
                    if (!is_zero && (packed_mode ? packed_linear >= 131072 : group_addr >= 8192))
                        error_reg <= 1'b1;
                    if (last_sample) begin
                        // Guard the registered SRAM response before sampling idle.
                        settle <= 5'd3;
                        state <= last_cin ? ST_WAIT_WRITE : ST_DRAIN;
                    end else begin
                        r_global_cnt <= r_global_cnt + 24'd1;
                        if (scan_x == scan_w - 9'd1) begin
                            scan_x <= 9'd0;
                            scan_y <= scan_y + 9'd1;
                        end else scan_x <= scan_x + 9'd1;
                    end
                end
            end
            ST_DRAIN: begin
                if (settle != 0) settle <= settle - 5'd1;
                else if (i_pipeline_idle) begin
                    r_cin_idx <= r_cin_idx + 8'd1;
                    r_global_cnt <= r_global_cnt + 24'd1;
                    scan_x <= 9'd0;
                    scan_y <= 9'd0;
                    state <= ST_READ;
                end
            end
            ST_WAIT_WRITE: begin
                if (settle != 0) settle <= settle - 5'd1;
                else if (r_write_cnt == expected_writes && i_pipeline_idle &&
                         (!i_is_last_cin_group || acc_done_seen)) begin
                    // SRAM writes commit on out_valid edges; idle includes that tail.
                    layer_done <= 1'b1;
                    tile_done_reg <= i_is_last_cin_group;
                    state <= ST_IDLE;
                end
            end
            ST_ERROR: state <= ST_ERROR;
            default: state <= ST_IDLE;
        endcase
        if (i_tile_error || error_reg) begin
            error_reg <= 1'b1;
            state <= ST_ERROR;
            layer_done <= 1'b0;
            tile_done_reg <= 1'b0;
        end
        if (!rst_n) begin
            state <= ST_IDLE;
            r_cin_idx <= 0;
            scan_x <= 0;
            scan_y <= 0;
            settle <= 0;
            r_write_cnt <= 0;
            r_global_cnt <= 0;
            r_rd_en_d1 <= 0;
            r_is_first_d1 <= 0;
            r_is_last_d1 <= 0;
            pad_zero_d1 <= 0;
            acc_done_seen <= 0;
            tile_done_reg <= 0;
            error_reg <= 0;
            layer_done <= 0;
        end
    end
endmodule

`resetall
