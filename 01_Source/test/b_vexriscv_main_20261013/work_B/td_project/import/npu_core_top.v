// -----------------------------------------------------------------------------
// File   : npu_core_top.v
// Author : OpenAI Codex (integration changes)
// Date   : 2026-09-07
// -----------------------------------------------------------------------------
// Description:
//   Integrate tile scheduling, zero padding, memory writeback and layer completion.
// Change Log:
//   2026-09-07  Codex  v2.0  Integrate and simulate two-row partial-sum tiling.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// Module      : npu_core_top
// Description : NPU 纯硬件自动化推理顶层 (No-CPU Architecture)
//               闆嗘垚浜?Microcode Sequencer, BCU_v2, Ping-Pong RAM, Compute Engine
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module npu_core_top #(
    parameter NUM_CHANNELS  = 16,
    parameter PIXEL_W       = 8,
    parameter WEIGHT_W      = 8,
    parameter ACC_WIDTH     = 32,
    parameter DSP_MAC_LANES = 9,
    parameter USE_DESC_RAM  = 1'b0,
    parameter USE_POOL_REORDER_AXI = 1'b0,
    parameter POOL_AXI_BURST_BEATS = 4,
    parameter POOL_REORDER_IMPL = 2,
    parameter integer PING_BANK_DEPTH = 4096,
    parameter integer PONG_BANK_DEPTH = 5120,
    parameter integer PARAM_ADDR_W = 17
)(
    input  wire         clk,
    input  wire         rst_n,
    output wire         o_tile_ready,
    output wire         o_tile_done,
    output wire         o_tile_error,
    output wire         o_layer_done,

    // ==========================================
    // 1. External LBP Sensor Interface (鍓嶇鎽勫儚澶村儚娴?
    // ==========================================
    input  wire         i_frame_valid,
    input  wire         i_lbp_valid,
    input  wire [7:0]   i_lbp_pixel,

    // ==========================================
    // 1a. Layer-0 input preload bypass
    // ==========================================
    input  wire         i_l0_input_preload_en,
    input  wire         i_l0_input_packed_en,
    input  wire         i_preload_wr_en,
    input  wire         i_preload_target,      // 第一版仅支持 0=PING
    input  wire [12:0]  i_preload_wr_addr,
    input  wire [15:0]  i_preload_wr_mask,
    input  wire [127:0] i_preload_wr_data,
    input  wire         i_skip_lbp_load,

    // ==========================================
    // 1b. Descriptor RAM Configuration Interface (杞欢鍙紪绋嬬綉缁滅粨鏋?
    // ==========================================
    input  wire         i_desc_we,
    input  wire [4:0]   i_desc_layer,
    input  wire [2:0]   i_desc_word,
    input  wire [31:0]  i_desc_wdata,
    input  wire [5:0]   i_layer_count,
    input  wire         i_desc_mode,

    // ==========================================
    // 2. DMA Weight Controller Interface (鍘诲線鐗囧 DDR/Flash 鎼繍鍣?
    // ==========================================
    output wire         o_dma_req,
    output wire [PARAM_ADDR_W-1:0] o_dma_base_addr,
    output wire [PARAM_ADDR_W-1:0] o_bias_base_addr,
    output wire [15:0]  o_dma_length,
    input  wire         i_dma_ack,
    input  wire         i_dma_done,

    // 鏁版嵁闈? DMA 鏉冮噸鐏屽叆鎬荤嚎
    input  wire[WEIGHT_W*9*2-1:0] weight_in_data,
    input  wire                  weight_in_valid,
    input  wire[9:0]            weight_in_addr,
    input  wire                  update_weights_en,

    // 鏁版嵁闈? DMA 鍋忕疆鐏屽叆鎬荤嚎
    input  wire [31:0]          bias_in_data,
    input  wire                 bias_in_valid,
    input  wire [4:0]           bias_in_addr,
    input  wire                 update_bias_en,

    // ==========================================
    // 2c. Pool reorder scratch memory AXI master
    // ==========================================
    input  wire [31:0]  i_pool_scratch_base_addr,
    output wire         o_pool_reorder_error,
    output wire [31:0]  o_pool_reorder_dbg0,
    output wire [31:0]  o_pool_reorder_dbg1,
    output wire [31:0]  o_pool_reorder_dbg2,
    output wire [31:0]  o_pool_reorder_dbg3,
    output wire [31:0]  o_pool_reorder_dbg4,
    output wire [31:0]  o_pool_reorder_dbg5,
    output wire [31:0]  o_pool_reorder_dbg6,
    output wire [31:0]  o_pool_reorder_dbg7,
    output wire [31:0]  o_pool_reorder_dbg8,
    output wire [31:0]  o_pool_reorder_dbg9,
    output wire [31:0]  o_pool_reorder_dbg10,
    output wire [31:0]  o_pool_reorder_dbg11,
    output wire [31:0]  o_pool_reorder_dbg12,
    output wire [31:0]  o_pool_reorder_dbg13,
    output wire [31:0]  o_pool_reorder_dbg14,
    output wire [31:0]  o_pool_reorder_dbg15,
    output wire [31:0]  o_pool_reorder_dbg16,
    output wire [31:0]  o_pool_reorder_dbg17,
    output wire [31:0]  o_pool_reorder_dbg18,

    input  wire [6:0]   i_layer_dbg_sel,
    output wire [31:0]  o_layer_dbg0,
    output wire [31:0]  o_layer_dbg1,
    output wire [31:0]  o_layer_dbg2,
    output wire [31:0]  o_layer_dbg3,
    output wire [31:0]  o_layer_dbg4,
    output wire [31:0]  o_layer_dbg5,
    output wire [31:0]  o_layer_dbg6,
    output wire [31:0]  o_layer_dbg7,

    // Live control-flow taps for low-intrusion board diagnostics.  All of
    // these signals are synchronous to clk and are intentionally kept out of
    // the compute datapath.
    output wire [4:0]   o_dbg_layer_id,
    output wire [3:0]   o_dbg_oc_group_idx,
    output wire [5:0]   o_dbg_cin_group_idx,
    output wire         o_dbg_layer_start,
    output wire         o_dbg_layer_done,
    output wire         o_dbg_pipeline_idle,
    output wire         o_dbg_npu_in_valid,
    output wire         o_dbg_npu_in_ready,
    output wire [7:0]   o_dbg_npu_pixel_in,
    output wire         o_dbg_npu_out_valid,
    output wire [127:0] o_dbg_npu_out_bus,
    output wire [12:0]  o_dbg_npu_write_addr,
    output wire [7:0]   o_dbg_stage_valid_flags,
    output wire [31:0]  o_dbg_start_cfg,
    output wire [31:0]  o_dbg_bcu0,
    output wire [31:0]  o_dbg_bcu1,
    output wire [31:0]  o_dbg_bcu2,
    output wire [31:0]  o_dbg_bcu3,
    output wire [31:0]  o_dbg_bcu4,
    output wire [31:0]  o_dbg_bcu5,

    output wire [3:0]   m_axi_arid,
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arlock,
    output wire [3:0]   m_axi_arcache,
    output wire [2:0]   m_axi_arprot,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [3:0]   m_axi_rid,
    input  wire [31:0]  m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,

    output wire [3:0]   m_axi_awid,
    output wire [31:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire         m_axi_awlock,
    output wire [3:0]   m_axi_awcache,
    output wire [2:0]   m_axi_awprot,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [3:0]   m_axi_wid,
    output wire [31:0]  m_axi_wdata,
    output wire [3:0]   m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [3:0]   m_axi_bid,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,

    // ==========================================
    // 2b. Sequencer 鎺у埗闈?snoop 杈撳嚭 (渚涘閮?DMA 閫傞厤鍣ㄤ娇鐢? Step 16.3 M3 鏂板)
    // ==========================================
    output wire [1:0]   o_kernel_size,     // 00=1x1 / 01=2x2 / 10=3x3

    // ==========================================
    // 3. Final Result Interface
    // ==========================================
    output wire         o_result_stream_valid,
    output wire [127:0] o_result_stream_data,
    output wire         o_inference_done,
    output wire         o_bbox_valid,
    output wire[39:0]  o_bbox_data
);

    generate
        if ((PARAM_ADDR_W < 17) || (PARAM_ADDR_W > 21)) begin : g_invalid_param_addr_w
            initial begin
                $error("npu_core_top PARAM_ADDR_W must be within 17..21");
                $finish;
            end
        end
    endgenerate

    // ==========================================
    // 内部互连信号声明
    // ==========================================
    
    // ---- Sequencer 控制流与配置广播 ----
    wire        w_is_init_phase;
    wire        w_layer_start, w_layer_done, w_pingpong_sel;
    wire        w_is_fc_mode;
    wire [1:0]  w_activation_type;
    wire        w_pool_en;
    wire        w_padding_en_uc;   // 微码�?[13]: 显式 padding 开�?
    wire [1:0]  w_kernel_size;
    assign o_kernel_size = w_kernel_size;
    wire [9:0]  w_cin_total, w_cout_total;
    wire [9:0]  w_img_width, w_img_height;
    wire [3:0]  w_shift_bits;
    wire [3:0]  w_oc_group_idx;
    wire [4:0]  w_oc_block_size;

    // ---- Cin Group 信号 (Step 14.1b) ----
    wire [5:0]  w_cin_group_idx;
    wire [4:0]  w_cin_block_size;
    wire        w_is_first_cin_group;
    wire        w_is_last_cin_group;

    // Legacy LBP input handshake is retained at the public interface, but
    // layer-0 storage uses packed PING preload rather than a dedicated buffer.
    wire        w_lbp_wr_en;
    wire [14:0] w_lbp_wr_addr;
    wire [7:0]  w_lbp_wr_data;
    wire [4:0]  w_layer_id;          // 褰撳墠灞?PC锛岀敤浜?layer-0 璇诲彇璺敱

    // ---- BCU 读写控制网格 ----
    // 读地址 15b：packed layer-0 uses [18:4] internally; fm_bank_array takes 13b.
    // 写地址 13b：对�?fm_bank_array 深度 8K
    wire [14:0] w_bcu_rd_addr;
    wire [12:0] w_bcu_wr_addr;
    wire        w_bcu_rd_en;
    wire [3:0]  w_bcu_cin_idx;      // FM bank 选择
    wire [7:0]  w_bcu_cin_idx_full; // 瀹屾暣 Cin 绱㈠紩 (渚?weight_buffer)
    // [Step 14.1l] BCU r_cin_idx -> SRAM 璇诲彇 (1 鎷?BRAM 寤惰繜) 鍚? 鏁版嵁鎵嶅埌杈?conv_engine_top.
    //   鍦ㄦ澶勫 cin_idx_full 鍔?1 鎷嶅瘎瀛樺櫒, 浣垮叾涓?SRAM 杈撳嚭鏁版嵁鐩镐綅瀵归綈;
    //   conv_engine_top 内部还会再加 1 拍以匹配 line_buffer p11 寄存�? 总共 2 拍延迟�?
    //   这样 mac_tree 同时收到 cin K 的数据和 cin K 的权�? 修正最�?2 个像素的 off-by-one bug�?
    reg [7:0]   r_bcu_cin_idx_full_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_bcu_cin_idx_full_d1 <= 8'd0;
        else        r_bcu_cin_idx_full_d1 <= w_bcu_cin_idx_full;
    end

    wire        w_use_l0_packed_ping = (w_layer_id == 5'd0) &&
                                       i_l0_input_preload_en &&
                                       i_l0_input_packed_en &&
                                       !i_preload_target;
    
    // ---- NPU 数据流与握手 ----
    wire        w_npu_in_valid, w_npu_out_valid;
    wire        w_npu_in_ready;
    wire        w_npu_is_first_cin, w_npu_is_last_cin;
    wire [127:0] w_npu_out_bus;
    wire [7:0]  w_npu_out_x, w_npu_out_y;  // [Step 14.1m] conv 实际输出坐标 �?BCU 写地址
    // [Step 14.1k 方案A] conv_engine_top 流水排空标志 -> BCU
    wire        w_pipeline_idle;
    wire [31:0] w_dbg_pe_fold;
    wire [31:0] w_dbg_bias_fold;
    wire [31:0] w_dbg_quant_fold;
    wire [31:0] w_dbg_wt_fold;
    wire [7:0]  w_dbg_valid_flags;
    wire [31:0] w_bcu_dbg0;
    wire [31:0] w_bcu_dbg1;
    wire [31:0] w_bcu_dbg2;
    wire [31:0] w_bcu_dbg3;
    wire [31:0] w_bcu_dbg4;
    wire [31:0] w_bcu_dbg5;
    reg  [31:0] r_dbg_start_cfg;

    assign o_dbg_layer_id       = w_layer_id;
    assign o_dbg_oc_group_idx   = w_oc_group_idx;
    assign o_dbg_cin_group_idx  = w_cin_group_idx;
    assign o_dbg_layer_start    = w_layer_start;
    assign o_dbg_layer_done     = w_layer_done;
    assign o_dbg_pipeline_idle  = w_pipeline_idle;
    assign o_dbg_npu_in_valid   = w_npu_in_valid;
    assign o_dbg_npu_in_ready   = w_npu_in_ready;
    assign o_dbg_npu_out_valid  = w_npu_out_valid;
    assign o_dbg_npu_out_bus    = w_npu_out_bus;
    assign o_dbg_npu_write_addr = w_bcu_wr_addr;
    assign o_dbg_stage_valid_flags = w_dbg_valid_flags;
    assign o_dbg_start_cfg      = r_dbg_start_cfg;
    assign o_dbg_bcu0           = w_bcu_dbg0;
    assign o_dbg_bcu1           = w_bcu_dbg1;
    assign o_dbg_bcu2           = w_bcu_dbg2;
    assign o_dbg_bcu3           = w_bcu_dbg3;
    assign o_dbg_bcu4           = w_bcu_dbg4;
    assign o_dbg_bcu5           = w_bcu_dbg5;

    // ---- 缓存阵列数据总线 ----
    wire [7:0]  w_ping_read_data, w_pong_read_data;

    // ==========================================
    // 1. NPU Sequencer 瀹炰緥鍖?
    // ==========================================
    wire [7:0] w_tile_y_base, w_tile_rows;
    wire w_tile_start, w_tile_acc_done, w_tile_acc_error, w_tile_bcu_error;
    wire w_npu_pad_zero;
    wire w_complete_layer;
    assign w_tile_start = w_layer_start && w_is_first_cin_group;
    assign o_tile_error = w_tile_acc_error || w_tile_bcu_error || o_pool_reorder_error;
    assign o_layer_done = w_complete_layer;

    npu_sequencer #(
        .USE_DESC_RAM   (USE_DESC_RAM),
        .PARAM_ADDR_W   (PARAM_ADDR_W)
    ) u_sequencer (
        .clk                (clk),
        .rst_n              (rst_n),

        .i_frame_valid      (i_frame_valid),
        .i_lbp_valid        (i_lbp_valid),
        .i_lbp_pixel        (i_lbp_pixel),
        .i_skip_lbp_load    (i_skip_lbp_load),

        .o_lbp_wr_en        (w_lbp_wr_en),
        .o_lbp_wr_addr      (w_lbp_wr_addr),
        .o_lbp_wr_data      (w_lbp_wr_data),
        .o_is_init_phase    (w_is_init_phase), // [C缁勫井璋僝 瀵煎嚭 PC==0 鏍囪瘑渚?A 缁勮矾鐢变娇鐢?
        .o_layer_id         (w_layer_id),

        .i_desc_we          (i_desc_we),
        .i_desc_layer       (i_desc_layer),
        .i_desc_word        (i_desc_word),
        .i_desc_wdata       (i_desc_wdata),
        .i_layer_count      (i_layer_count),
        .i_desc_mode        (i_desc_mode),

        .o_dma_req          (o_dma_req),
        .o_dma_base_addr    (o_dma_base_addr),
        .o_bias_base_addr   (o_bias_base_addr),
        .o_dma_length       (o_dma_length),
        .i_dma_ack          (i_dma_ack),
        .i_dma_done         (i_dma_done),

        .o_is_fc_mode       (w_is_fc_mode),
        .o_activation_type  (w_activation_type),
        .o_pool_en          (w_pool_en),
        .o_padding_en       (w_padding_en_uc),
        .o_kernel_size      (w_kernel_size),
        .o_cin_total        (w_cin_total),
        .o_cout_total       (w_cout_total),
        .o_img_width        (w_img_width),
        .o_img_height       (w_img_height),
        .o_shift_bits       (w_shift_bits),
        .o_pingpong_sel     (w_pingpong_sel),
        .o_oc_group_idx     (w_oc_group_idx),
        .o_oc_block_size    (w_oc_block_size),

        // Cin 分组输出 (Step 14.1b)
        .o_cin_group_idx        (w_cin_group_idx),
        .o_cin_block_size       (w_cin_block_size),
        .o_is_first_cin_group   (w_is_first_cin_group),
        .o_is_last_cin_group    (w_is_last_cin_group),

        .o_tile_y_base      (w_tile_y_base),
        .o_tile_rows        (w_tile_rows),
        .i_tile_error       (o_tile_error),
        .o_layer_done       (w_complete_layer),
        .o_layer_start      (w_layer_start),
        .i_layer_done       (w_layer_done),
        .i_npu_out_valid    (w_npu_out_valid),
        .i_npu_out_bus      (w_npu_out_bus),

        .o_result_stream_valid(o_result_stream_valid),
        .o_result_stream_data(o_result_stream_data),
        .o_inference_done   (o_inference_done),
        .o_bbox_valid       (o_bbox_valid),
        .o_bbox_data        (o_bbox_data)
    );

    // ==========================================
    // 2. 跨组协定: FC 地址欺骗适配逻辑 (Address Deception)
    // ==========================================
    // BCU 获得真实的特征图宽高，用于完整遍�?768 个特征�?
    wire[7:0] w_bcu_cfg_width  = w_img_width[7:0];
    wire[7:0] w_bcu_cfg_height = w_img_height[7:0];

    // Sequencer-side snapshot at layer_start.  Comparing this with the BCU
    // ST_CALC snapshot shows whether configuration changes in the intervening
    // cycle.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            r_dbg_start_cfg <= 32'd0;
        else if (w_layer_start)
            r_dbg_start_cfg <= {6'd0, w_layer_id, w_cin_block_size,
                                w_bcu_cfg_height, w_bcu_cfg_width};
    end
    
    // NPU 琚楠椾负 1x1 鍒嗚鲸鐜囷紝杩娇鍏跺皢 48 涓懆鏈熺殑杈撳叆鍏ㄩ儴绱姞鍒?(X=0, Y=0) 浣嶇疆
    wire [7:0] w_npu_cfg_width  = w_is_fc_mode ? 8'd1 : w_img_width[7:0];
    wire [7:0] w_npu_cfg_height = w_is_fc_mode ? 8'd1 : w_img_height[7:0];

    // Padding 配置：统一�?sequencer 译码输出�?
    // - legacy 模式: sequencer 内部处理 (显式 bit[13] OR kernel==3×3 隐式)
    // - descriptor 妯″紡: sequencer 浠?pad_mode 瀛楁璇戠爜 (VALID鈫?, SAME_ZERO鈫?)
    wire w_cfg_padding_en = w_padding_en_uc;

    // ==========================================
    // 3. BCU_v2 缂撳瓨璋冨害涓績瀹炰緥鍖?
    // ==========================================
    bcu u_bcu (
        .clk              (clk), 
        .rst_n            (rst_n),
        .layer_start      (w_layer_start),
        .i_tile_y_base    (w_tile_y_base),
        .i_tile_rows      (w_tile_rows),
        .i_tile_ready     (o_tile_ready),
        .i_tile_done      (w_tile_acc_done),
        .i_tile_error     (w_tile_acc_error || o_pool_reorder_error),
        .o_tile_done      (o_tile_done),
        .o_tile_error     (w_tile_bcu_error),
        .o_npu_pad_zero   (w_npu_pad_zero), 
        .layer_done       (w_layer_done),
        .i_is_fc_mode     (w_is_fc_mode),      // [新增] 接入 FC 模式
        .i_cfg_width      (w_bcu_cfg_width),   // [输入真实维度]
        .i_cfg_height     (w_bcu_cfg_height),
        .i_cfg_kernel     (w_kernel_size), 
        .i_cfg_pool_en    (w_pool_en),
        .i_cfg_padding_en (w_cfg_padding_en), 
        .i_cfg_cin_total  (w_cin_total[7:0]),
        .i_oc_group_idx   (w_oc_group_idx),

        // Cin 分组输入 (Step 14.1b)
        .i_cin_group_idx        (w_cin_group_idx),
        .i_cin_block_size       (w_cin_block_size),
        .i_is_first_cin_group   (w_is_first_cin_group),
        .i_is_last_cin_group    (w_is_last_cin_group),
        .i_is_layer0            (w_layer_id == 5'd0),
        .i_l0_packed_read_en    (w_use_l0_packed_ping),
        
        .o_sram_rd_addr   (w_bcu_rd_addr), 
        .o_sram_rd_en     (w_bcu_rd_en),
        .o_sram_cin_idx   (w_bcu_cin_idx),
        .o_cin_idx_full   (w_bcu_cin_idx_full),
        .o_sram_wr_addr   (w_bcu_wr_addr),
        
        .i_npu_in_ready    (w_npu_in_ready),
        .o_npu_in_valid     (w_npu_in_valid), 
        .o_npu_is_first_cin (w_npu_is_first_cin), 
        .o_npu_is_last_cin  (w_npu_is_last_cin),  
        .i_npu_out_valid    (w_npu_out_valid),
        // [Step 14.1m] conv 实际输出坐标接入 BCU, 用于 SRAM 写地址精确寻址
        .i_conv_out_x       (w_npu_out_x),
        .i_conv_out_y       (w_npu_out_y),

        // [Step 14.1k 方案A] 来自 conv_engine_top, 闸控 layer_done
        .i_pipeline_idle    (w_pipeline_idle),
        .o_dbg0             (w_bcu_dbg0),
        .o_dbg1             (w_bcu_dbg1),
        .o_dbg2             (w_bcu_dbg2),
        .o_dbg3             (w_bcu_dbg3),
        .o_dbg4             (w_bcu_dbg4),
        .o_dbg5             (w_bcu_dbg5)
    );

    // ==========================================
    // 4. Memory Crossbar (PING/PONG; layer-0 uses packed PING preload)
    // ==========================================
    // ---- PING 阵列读写路由 ----
    // layer-0 reads packed LBP data directly from PING.
    wire w_l0_packed_rd_ping = w_use_l0_packed_ping & w_bcu_rd_en;
    wire w_mid_rd_ping = (w_layer_id != 5'd0) & w_bcu_rd_en & (~w_pingpong_sel);
    wire w_ping_rd_en = w_l0_packed_rd_ping | w_mid_rd_ping;
    wire w_ping_compute_wr_en = (!w_is_init_phase) & w_npu_out_valid & w_pingpong_sel;
    wire w_ping_preload_wr_en = i_preload_wr_en & !i_preload_target;
    wire w_ping_wr_en = w_ping_preload_wr_en | w_ping_compute_wr_en;
    wire [12:0] w_ping_wr_addr = w_ping_preload_wr_en ? i_preload_wr_addr : w_bcu_wr_addr;
    wire [127:0] w_ping_wr_data = w_ping_preload_wr_en ? i_preload_wr_data : w_npu_out_bus;
    wire [15:0] w_ping_wr_mask = w_ping_preload_wr_en ? i_preload_wr_mask : 16'hffff;

    // ---- PONG 阵列读写路由 ----
    wire w_pong_rd_en   = (w_layer_id != 5'd0) & w_bcu_rd_en & (w_pingpong_sel);
    wire w_pong_wr_en   = (!w_is_init_phase) & w_npu_out_valid & (~w_pingpong_sel);
    wire [12:0] w_pong_wr_addr = w_bcu_wr_addr;
    wire [127:0] w_pong_wr_data = w_npu_out_bus;
    wire [15:0] w_pong_wr_mask = 16'hffff;

    // ---- 送入 NPU 的统一数据�?----
    // Layer-0 uses packed PING; layer-1+ follows ordinary ping-pong routing.
    wire [7:0] w_npu_pixel_in = w_use_l0_packed_ping ? w_ping_read_data :
                                (w_pingpong_sel ? w_pong_read_data : w_ping_read_data);
    assign o_dbg_npu_pixel_in = w_npu_pad_zero ? 8'd0 : w_npu_pixel_in;

    // PING: RGB CHW preload uses 57600 / 16 = 3600 words per bank.
    // 4096 entries also cover the existing odd-layer feature maps. PONG remains
    // 5120 entries. Port widths and Anlogic memory/FIFO adaptations are retained.
    fm_bank_array #(.BANK_DEPTH(PING_BANK_DEPTH)) u_ping_array (
        .clk            (clk),
        .i_write_bus    (w_ping_wr_data), 
        .i_write_en     (w_ping_wr_en), 
        .i_write_mask   (w_ping_wr_mask),
        .i_write_addr   (w_ping_wr_addr),
        .i_read_cin_idx (w_bcu_cin_idx), 
        .i_read_en      (w_ping_rd_en), 
        .i_read_addr    (w_bcu_rd_addr[12:0]),
        .o_read_data    (w_ping_read_data)
    );

    fm_bank_array #(.BANK_DEPTH(PONG_BANK_DEPTH)) u_pong_array (
        .clk            (clk),
        .i_write_bus    (w_pong_wr_data), 
        .i_write_en     (w_pong_wr_en), 
        .i_write_mask   (w_pong_wr_mask),
        .i_write_addr   (w_pong_wr_addr),
        .i_read_cin_idx (w_bcu_cin_idx), 
        .i_read_en      (w_pong_rd_en), 
        .i_read_addr    (w_bcu_rd_addr[12:0]),
        .o_read_data    (w_pong_read_data)
    );

    // ==========================================
    // 6. Compute Engine (算力引擎)
    // ==========================================
    conv_engine_top #(
        .PIXEL_W      (PIXEL_W),
        .WEIGHT_W     (WEIGHT_W),
        .ACC_WIDTH    (ACC_WIDTH),
        .NUM_CHANNELS (NUM_CHANNELS),
        .DSP_MAC_LANES(DSP_MAC_LANES),
        .USE_POOL_REORDER_AXI(USE_POOL_REORDER_AXI),
        .POOL_AXI_BURST_BEATS(POOL_AXI_BURST_BEATS),
        .POOL_REORDER_IMPL(POOL_REORDER_IMPL)
    ) u_conv_engine (
        .clk                (clk),
        .rst_n              (rst_n),
        .layer_start_clr    (w_layer_start),
        .tile_start         (w_tile_start),
        .cfg_tile_y_base    (w_tile_y_base),
        .cfg_tile_rows      (w_tile_rows),
        .tile_ready         (o_tile_ready),
        .tile_done          (w_tile_acc_done),
        .tile_error         (w_tile_acc_error),

        // 静态配置接�?(接收欺骗后的伪装分辨�?
        .cfg_width          (w_npu_cfg_width),
        .cfg_height         (w_npu_cfg_height),
        .kernel_size        (w_kernel_size),
        .padding_en         (w_cfg_padding_en),
        .shift_bits         (w_shift_bits),
        .cfg_pool_en        (w_pool_en),
        .cfg_activation_type(w_activation_type), // [新增] B 组需要的激活路�?

        // 动态通道控制
        .is_first_cin       (w_npu_is_first_cin),
        .is_last_cin        (w_npu_is_last_cin),

        // DMA 权重更新机制
        .weight_in_data     (weight_in_data),
        .weight_in_valid    (weight_in_valid),
        .weight_in_addr     (weight_in_addr),
        .update_weights_en  (update_weights_en),

        // DMA 偏置更新机制
        .bias_in_data       (bias_in_data),
        .bias_in_valid      (bias_in_valid),
        .bias_in_addr       (bias_in_addr),
        .update_bias_en     (update_bias_en),

        // 褰撳墠 Cout 缁勬湁鏁?lane 鏁?(鏈粍 lane 鎺╃爜)
        .i_oc_block_size    (w_oc_block_size),

        // 褰撳墠 Cin 绱㈠紩锛堜緵 weight_buffer 鎸夐〉娣卞害璇诲嚭瀵瑰簲鏉冮噸锛?
        .i_current_cin      (r_bcu_cin_idx_full_d1),

        // 鏍稿績鍍忕礌鏁版嵁娴?
        .pixel_in_data      (w_npu_pad_zero ? 8'd0 : w_npu_pixel_in),
        .pixel_in_valid     (w_npu_in_valid),
        .pixel_in_ready     (w_npu_in_ready),
        .out_pixel_bus      (w_npu_out_bus),
        .out_valid          (w_npu_out_valid),
        
        .out_x              (w_npu_out_x), 
        .out_y              (w_npu_out_y),

        // [Step 14.1k 方案A] pipeline 排空标志, 直接送给 BCU
        .o_dbg_pe_fold      (w_dbg_pe_fold),
        .o_dbg_bias_fold    (w_dbg_bias_fold),
        .o_dbg_quant_fold   (w_dbg_quant_fold),
        .o_dbg_wt_fold      (w_dbg_wt_fold),
        .o_dbg_valid_flags  (w_dbg_valid_flags),
        .o_pipeline_idle    (w_pipeline_idle),

        .i_pool_scratch_base_addr(i_pool_scratch_base_addr),
        .o_pool_reorder_error(o_pool_reorder_error),
        .o_pool_reorder_dbg0(o_pool_reorder_dbg0),
        .o_pool_reorder_dbg1(o_pool_reorder_dbg1),
        .o_pool_reorder_dbg2(o_pool_reorder_dbg2),
        .o_pool_reorder_dbg3(o_pool_reorder_dbg3),
        .o_pool_reorder_dbg4(o_pool_reorder_dbg4),
        .o_pool_reorder_dbg5(o_pool_reorder_dbg5),
        .o_pool_reorder_dbg6(o_pool_reorder_dbg6),
        .o_pool_reorder_dbg7(o_pool_reorder_dbg7),
        .o_pool_reorder_dbg8(o_pool_reorder_dbg8),
        .o_pool_reorder_dbg9(o_pool_reorder_dbg9),
        .o_pool_reorder_dbg10(o_pool_reorder_dbg10),
        .o_pool_reorder_dbg11(o_pool_reorder_dbg11),
        .o_pool_reorder_dbg12(o_pool_reorder_dbg12),
        .o_pool_reorder_dbg13(o_pool_reorder_dbg13),
        .o_pool_reorder_dbg14(o_pool_reorder_dbg14),
        .o_pool_reorder_dbg15(o_pool_reorder_dbg15),
        .o_pool_reorder_dbg16(o_pool_reorder_dbg16),
        .o_pool_reorder_dbg17(o_pool_reorder_dbg17),
        .o_pool_reorder_dbg18(o_pool_reorder_dbg18),
        .m_axi_arid         (m_axi_arid),
        .m_axi_araddr       (m_axi_araddr),
        .m_axi_arlen        (m_axi_arlen),
        .m_axi_arsize       (m_axi_arsize),
        .m_axi_arburst      (m_axi_arburst),
        .m_axi_arlock       (m_axi_arlock),
        .m_axi_arcache      (m_axi_arcache),
        .m_axi_arprot       (m_axi_arprot),
        .m_axi_arvalid      (m_axi_arvalid),
        .m_axi_arready      (m_axi_arready),
        .m_axi_rid          (m_axi_rid),
        .m_axi_rdata        (m_axi_rdata),
        .m_axi_rresp        (m_axi_rresp),
        .m_axi_rlast        (m_axi_rlast),
        .m_axi_rvalid       (m_axi_rvalid),
        .m_axi_rready       (m_axi_rready),
        .m_axi_awid         (m_axi_awid),
        .m_axi_awaddr       (m_axi_awaddr),
        .m_axi_awlen        (m_axi_awlen),
        .m_axi_awsize       (m_axi_awsize),
        .m_axi_awburst      (m_axi_awburst),
        .m_axi_awlock       (m_axi_awlock),
        .m_axi_awcache      (m_axi_awcache),
        .m_axi_awprot       (m_axi_awprot),
        .m_axi_awvalid      (m_axi_awvalid),
        .m_axi_awready      (m_axi_awready),
        .m_axi_wid          (m_axi_wid),
        .m_axi_wdata        (m_axi_wdata),
        .m_axi_wstrb        (m_axi_wstrb),
        .m_axi_wlast        (m_axi_wlast),
        .m_axi_wvalid       (m_axi_wvalid),
        .m_axi_wready       (m_axi_wready),
        .m_axi_bid          (m_axi_bid),
        .m_axi_bresp        (m_axi_bresp),
        .m_axi_bvalid       (m_axi_bvalid),
        .m_axi_bready       (m_axi_bready)
    );

    // ==========================================
    // 7. Layer-level feature-map debug
    // ==========================================
    npu_layer_debug #(
        .NUM_CHANNELS(NUM_CHANNELS)
    ) u_layer_debug (
        .clk              (clk),
        .rst_n            (rst_n),
        .i_layer_dbg_sel  (i_layer_dbg_sel),
        .i_layer_start    (w_layer_start && w_tile_y_base == 8'd0),
        .i_layer_done     (w_complete_layer),
        .i_layer_id       (w_layer_id),
        .i_is_init_phase  (w_is_init_phase),
        .i_oc_group_idx   (w_oc_group_idx),
        .i_cin_group_idx  (w_cin_group_idx),
        .i_pool_en        (w_pool_en),
        .i_is_fc_mode     (w_is_fc_mode),
        .i_cfg_padding_en (w_cfg_padding_en),
        .i_kernel_size    (w_kernel_size),
        .i_pingpong_sel   (w_pingpong_sel),
        .i_pipeline_idle  (w_pipeline_idle),
        .i_npu_in_valid   (w_npu_in_valid),
        .i_npu_pixel_in   (w_npu_pixel_in),
        .i_npu_out_valid  (w_npu_out_valid),
        .i_npu_out_bus    (w_npu_out_bus),
        .i_npu_out_x      (w_npu_out_x),
        .i_npu_out_y      (w_npu_out_y),
        .i_bcu_wr_addr    (w_bcu_wr_addr),
        .i_bcu_dbg0       (w_bcu_dbg0),
        .i_bcu_dbg2       (w_bcu_dbg2),
        .i_dbg_pe_fold    (w_dbg_pe_fold),
        .i_dbg_bias_fold  (w_dbg_bias_fold),
        .i_dbg_quant_fold (w_dbg_quant_fold),
        .i_dbg_wt_fold    (w_dbg_wt_fold),
        .i_dbg_valid_flags(w_dbg_valid_flags),
        .o_layer_dbg0     (o_layer_dbg0),
        .o_layer_dbg1     (o_layer_dbg1),
        .o_layer_dbg2     (o_layer_dbg2),
        .o_layer_dbg3     (o_layer_dbg3),
        .o_layer_dbg4     (o_layer_dbg4),
        .o_layer_dbg5     (o_layer_dbg5),
        .o_layer_dbg6     (o_layer_dbg6),
        .o_layer_dbg7     (o_layer_dbg7)
    );

`ifndef NO_VCD_DUMP
    initial begin
        $dumpfile("npu_core_top.vcd");
        $dumpvars(0, npu_core_top);
    end
`endif
endmodule

`resetall
