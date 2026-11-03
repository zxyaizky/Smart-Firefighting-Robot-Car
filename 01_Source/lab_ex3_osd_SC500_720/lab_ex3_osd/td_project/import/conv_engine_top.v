// -----------------------------------------------------------------------------
// File   : conv_engine_top.v
// Author : OpenAI Codex (integration changes)
// Date   : 2026-09-07
// -----------------------------------------------------------------------------
// Description:
//   Connect tile configuration, PE handshake, raster reorder and drain status.
// Change Log:
//   2026-09-08  Codex  v3.0  Reserve SRAM/window credit; drain multiplexed PE work.
//   2026-09-07  Codex  v2.0  Integrate and simulate two-row partial-sum tiling.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

`ifndef NPU_MATH_DEFS_VH
`define NPU_MATH_DEFS_VH

`define NPU_CLOG2(x) \
    (((x) <= 2)     ? 1  : \
     ((x) <= 4)     ? 2  : \
     ((x) <= 8)     ? 3  : \
     ((x) <= 16)    ? 4  : \
     ((x) <= 32)    ? 5  : \
     ((x) <= 64)    ? 6  : \
     ((x) <= 128)   ? 7  : \
     ((x) <= 256)   ? 8  : \
     ((x) <= 512)   ? 9  : \
     ((x) <= 1024)  ? 10 : \
     ((x) <= 2048)  ? 11 : \
     ((x) <= 4096)  ? 12 : \
     ((x) <= 8192)  ? 13 : \
     ((x) <= 16384) ? 14 : 15)

`endif
// ============================================================================
// File Name   : conv_engine_top.v
// Description : 适配空间优先数据流，集成 HardSigmoid 与 144b 加载
// ============================================================================


module conv_engine_top #(
    parameter PIXEL_W   = 8,
    parameter WEIGHT_W  = 8,
    parameter ACC_WIDTH = 32,
    parameter NUM_CHANNELS = 16,
    parameter DSP_MAC_LANES = 9,
    parameter USE_POOL_REORDER_AXI = 1'b0,
    parameter POOL_AXI_BURST_BEATS = 4,
    parameter POOL_REORDER_IMPL = 2,
    // Current FaceNet max reorder surface is layer-0 160x120 = 19200 pixels.
    // Increase this parameter if a future microcode topology needs a larger
    // padded-conv + pool reorder surface.
    parameter POOL_REORDER_DEPTH = 19200
)(
    // 【硬性参数约束】ACC_WIDTH >= 32
    // 偏置加法级 bias_i = bias_bus[ch*32 +: ACC_WIDTH]，ACC_WIDTH < 32 时偏置高位被静默截断。
    // npu_core_top 实例化时已设 ACC_WIDTH=32；任何独立使用必须保证 ACC_WIDTH >= 32。
/*     initial if (ACC_WIDTH < 32)
        $warning("[conv_engine_top] ACC_WIDTH=%0d < 32: bias high bits will be silently truncated!", ACC_WIDTH); */

    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   layer_start_clr,
    input  wire                   tile_start,
    input  wire [7:0]             cfg_tile_y_base,
    input  wire [7:0]             cfg_tile_rows,
    output wire                   tile_ready,
    output wire                   tile_done,
    output wire                   tile_error,

    // 配置接口
    input  wire [7:0]             cfg_width,
    input  wire [7:0]             cfg_height,
    input  wire [1:0]             kernel_size,   
    input  wire                   padding_en,
    input  wire [3:0]             shift_bits,
    input  wire [1:0]             cfg_activation_type, // [新增] 0:ReLU, 1:HardSig
    input  wire                   cfg_pool_en,   
 
    // 数据流控制 (来自 BCU)
    input  wire                   is_first_cin,
    input  wire                   is_last_cin,
    
    // 权重加载接口 (升级为 144-bit 双通道加载 + 全页深度)
    input  wire [143:0]           weight_in_data,
    input  wire                   weight_in_valid,
    input  wire [9:0]             weight_in_addr,   // flat 写入地址，每拍 2 条目
    input  wire                   update_weights_en,

    // 当前 Cin 索引（供 weight_buffer 按页深度读出对应权重）
    input  wire [7:0]             i_current_cin,

    // 偏置加载接口（分组页：每页 16 路 INT32）
    input  wire [31:0]            bias_in_data,
    input  wire                   bias_in_valid,
    input  wire [4:0]             bias_in_addr,
    input  wire                   update_bias_en,
    
    input  wire [7:0]             pixel_in_data,
    input  wire                   pixel_in_valid,
    output wire                   pixel_in_ready,

    // 当前 Cout 组有效 lane 数 (1..NUM_CHANNELS); 末组若 < NUM_CHANNELS，
    // 高位 lane 在 out_pixel_bus 上强制为 0 (硬件契约: 不依赖外部 DMA 灌零)。
    input  wire [4:0]             i_oc_block_size,

    output wire [NUM_CHANNELS*8-1:0] out_pixel_bus,
    output wire                   out_valid,
    output wire [7:0]             out_x,
    output wire [7:0]             out_y,

    // [Step 14.1k 方案A] 流水排空标志: 高表示 conv_engine_top 内部全部子模块
    // 都不再有「飞行中」的 valid 像素, 也没有未来会自发产生 valid 的内部状态
    // (line_buffer_conv flush / PE pipeline / channel_accumulator commit / pool flush 等)
    // BCU/sequencer 应等到此信号高时才能切换 cin_group 或翻转 is_first_cin/is_last_cin
    output wire                   o_pipeline_idle,

    // Intermediate pipeline debug: XOR-folded checksums (per-cycle, accumulated externally)
    output wire [31:0]            o_dbg_pe_fold,       // pe_sum_bus on pe_valid
    output wire [31:0]            o_dbg_bias_fold,      // reserved lightweight debug
    output wire [31:0]            o_dbg_quant_fold,     // quant_out_bus on quant_valid
    output wire [31:0]            o_dbg_wt_fold,        // weight bus XOR
    output wire [7:0]             o_dbg_valid_flags,    // pipeline valid snapshot

    input  wire [31:0]            i_pool_scratch_base_addr,
    output wire                   o_pool_reorder_error,
    output wire [31:0]            o_pool_reorder_dbg0,
    output wire [31:0]            o_pool_reorder_dbg1,
    output wire [31:0]            o_pool_reorder_dbg2,
    output wire [31:0]            o_pool_reorder_dbg3,
    output wire [31:0]            o_pool_reorder_dbg4,
    output wire [31:0]            o_pool_reorder_dbg5,
    output wire [31:0]            o_pool_reorder_dbg6,
    output wire [31:0]            o_pool_reorder_dbg7,
    output wire [31:0]            o_pool_reorder_dbg8,
    output wire [31:0]            o_pool_reorder_dbg9,
    output wire [31:0]            o_pool_reorder_dbg10,
    output wire [31:0]            o_pool_reorder_dbg11,
    output wire [31:0]            o_pool_reorder_dbg12,
    output wire [31:0]            o_pool_reorder_dbg13,
    output wire [31:0]            o_pool_reorder_dbg14,
    output wire [31:0]            o_pool_reorder_dbg15,
    output wire [31:0]            o_pool_reorder_dbg16,
    output wire [31:0]            o_pool_reorder_dbg17,
    output wire [31:0]            o_pool_reorder_dbg18,

    output wire [3:0]             m_axi_arid,
    output wire [31:0]            m_axi_araddr,
    output wire [7:0]             m_axi_arlen,
    output wire [2:0]             m_axi_arsize,
    output wire [1:0]             m_axi_arburst,
    output wire                   m_axi_arlock,
    output wire [3:0]             m_axi_arcache,
    output wire [2:0]             m_axi_arprot,
    output wire                   m_axi_arvalid,
    input  wire                   m_axi_arready,
    input  wire [3:0]             m_axi_rid,
    input  wire [31:0]            m_axi_rdata,
    input  wire [1:0]             m_axi_rresp,
    input  wire                   m_axi_rlast,
    input  wire                   m_axi_rvalid,
    output wire                   m_axi_rready,

    output wire [3:0]             m_axi_awid,
    output wire [31:0]            m_axi_awaddr,
    output wire [7:0]             m_axi_awlen,
    output wire [2:0]             m_axi_awsize,
    output wire [1:0]             m_axi_awburst,
    output wire                   m_axi_awlock,
    output wire [3:0]             m_axi_awcache,
    output wire [2:0]             m_axi_awprot,
    output wire                   m_axi_awvalid,
    input  wire                   m_axi_awready,
    output wire [3:0]             m_axi_wid,
    output wire [31:0]            m_axi_wdata,
    output wire [3:0]             m_axi_wstrb,
    output wire                   m_axi_wlast,
    output wire                   m_axi_wvalid,
    input  wire                   m_axi_wready,
    input  wire [3:0]             m_axi_bid,
    input  wire [1:0]             m_axi_bresp,
    input  wire                   m_axi_bvalid,
    output wire                   m_axi_bready
);

    // 内部总线
    localparam BUS_WIDTH = NUM_CHANNELS * 8;
    localparam SUM_WIDTH = ACC_WIDTH * NUM_CHANNELS;
    localparam MODE_1X1 = 2'b00;
    localparam MODE_2X2 = 2'b01;
    localparam MODE_3X3 = 2'b10;

    localparam POOL_REORDER_AW = `NPU_CLOG2(POOL_REORDER_DEPTH);

    wire [PIXEL_W*9-1:0]   lb_win_flat;
    wire                   lb_win_valid;
    wire [7:0]             lb_x, lb_y;
    wire [NUM_CHANNELS*72-1:0]  wb_weights_bus;
    
    wire [SUM_WIDTH-1:0]   pe_sum_bus;
    wire [NUM_CHANNELS-1:0] pe_valid_bus;
    wire [NUM_CHANNELS*8-1:0] pe_x_bus, pe_y_bus;
    wire [63:0]            bias_pair_bus;
    wire [2:0]             bias_pair_addr;
`ifdef MODEL_TECH
    wire [NUM_CHANNELS*32-1:0] bias_bus;
    wire [SUM_WIDTH-1:0]       bias_sum_bus;
`endif
    wire                   bias_valid;
    wire [7:0]             bias_x, bias_y;

    wire                   act_valid;
    wire [SUM_WIDTH-1:0]   act_out_bus;
    wire [7:0]             act_x, act_y;

    wire [BUS_WIDTH-1:0]   quant_out_bus;
    wire                   quant_valid;
    wire                   quant_busy;
    wire [7:0]             quant_x, quant_y;

    wire [BUS_WIDTH-1:0]        pool_out_bus;
    wire                        pool_out_valid;
    wire [7:0]                  pool_out_x, pool_out_y;
    wire [BUS_WIDTH-1:0]        lb_pool_data_in;
    wire                        lb_pool_data_valid;
    wire [BUS_WIDTH-1:0]        pool_reorder_rdata;
    wire                        pool_reorder_rvalid;
    wire                        pool_reorder_input_ready;
    wire                        pool_reorder_busy;

    reg [7:0] conv_out_w, conv_out_h;
    always @(*) begin
        case (kernel_size)
            MODE_1X1: begin
                conv_out_w = cfg_width;
                conv_out_h = cfg_height;
            end
            MODE_2X2: begin
                conv_out_w = padding_en ? (cfg_width + 8'd1) : (cfg_width - 8'd1);
                conv_out_h = padding_en ? (cfg_height + 8'd1) : (cfg_height - 8'd1);
            end
            default: begin
                conv_out_w = padding_en ? cfg_width : (cfg_width - 8'd2);
                conv_out_h = padding_en ? cfg_height : (cfg_height - 8'd2);
            end
        endcase
    end

    // --- 1. 权重 Buffer (144b适配 + 全页深度 SRAM) ---
    // [Step 14.1l] i_current_cin 1 拍延迟用于对齐 line_buffer 数据路径
    //   conv_engine_top 内部数据路径: pixel_in_data -> line_buffer p11 (1 拍) -> mac_tree
    //   故权重路径也需延迟 1 拍, 使 mac_tree 看到的 (data, weight) 对齐到同一 cin。
    //
    //   集成路径 (npu_core_top): BCU r_cin_idx -> SRAM (1 拍) -> conv_engine_top.pixel_in_data
    //   故 npu_core_top 还需在 BCU 输出 o_cin_idx_full 与 conv_engine_top.i_current_cin 之间
    //   再加 1 拍寄存器, 使总延迟达到 2 拍 (匹配 SRAM + line_buffer 的总数据延迟)。
    //
    // [Step 15.3] weight_buffer 已重构为内部同步读, 自带 1 拍延迟。原本此处的
    //   r_current_cin_d1 寄存器现已凗余, 直接将 i_current_cin 直连给 weight_buffer。
    //   所有 npu_core_top / 平台测试的外部约定不变 (1 拍延迟由 weight_buffer 内部承担)。
    weight_buffer #(
        .NUM_CHANNELS(NUM_CHANNELS), .MAX_CIN(32)
    ) u_weight_buf (
        .clk(clk), .rst_n(rst_n),
        .kernel_size(kernel_size),
        .weight_in_data(weight_in_data), .weight_in_valid(weight_in_valid),
        .weight_in_addr(weight_in_addr), .update_weights_en(update_weights_en),
        .i_current_cin(i_current_cin), .weights_bus_out(wb_weights_bus)
    );

    // --- 2. Padded tile raster supplied by BCU; full input dimensions retained.
    wire lbc_busy;
    wire pe_mac_ready;
    wire pe_win_ready;
    wire pe_busy;
    wire pe_input_pending;
    wire pe_tile_ready;
    wire pe_tile_error;
    // The tiled engine uses the bounded global-coordinate raster reorder.
    // Unsupported legacy frame/AXI selections fail closed, rather than deadlock.
    assign tile_error = pe_tile_error || (POOL_REORDER_IMPL != 2);
    assign tile_ready = pe_tile_ready && o_pipeline_idle &&
                        !tile_error && !o_pool_reorder_error;
    line_buffer_conv #(
        .DATA_WIDTH(PIXEL_W)
    ) u_lb_conv (
        .clk(clk), .rst_n(rst_n),
        .i_clr(layer_start_clr),
        .cfg_tile_y_base(cfg_tile_y_base), .cfg_tile_rows(cfg_tile_rows),
        .is_last_cin(is_last_cin), // 传递给 line_buffer_conv 用于 EOF 判断
        .cfg_width(cfg_width), .cfg_height(cfg_height),
        .kernel_size(kernel_size), .padding_en(padding_en),
        .data_in(pixel_in_data), .data_in_valid(pixel_in_valid),
        .win_out_flat(lb_win_flat), .win_valid(lb_win_valid),
        .out_x(lb_x), .out_y(lb_y),
        .o_busy(lbc_busy)
    );

    // --- 2.5 Bias Buffer (DMA/计算串行，单页缓存) ---
    bias_buffer #(
        .NUM_CHANNELS(NUM_CHANNELS)
    ) u_bias_buf (
        .clk(clk), .rst_n(rst_n),
        .bias_in_data(bias_in_data), .bias_in_valid(bias_in_valid),
        .bias_in_addr(bias_in_addr), .update_bias_en(update_bias_en),
        .bias_pair_addr(bias_pair_addr), .bias_pair_out(bias_pair_bus)
`ifdef MODEL_TECH
        , .bias_bus_debug(bias_bus)
`endif
    );

    // 【核心修复】：控制信号相位对齐
    // 理由：line_buffer_conv 对数据流产生了一拍延迟，控制流必须同步对齐
    // ========================================================================
    reg is_first_cin_reg, is_last_cin_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_first_cin_reg <= 1'b0;
            is_last_cin_reg  <= 1'b0;
        end else if (layer_start_clr) begin
            is_first_cin_reg <= 1'b0;
            is_last_cin_reg  <= 1'b0;
        end else begin
            is_first_cin_reg <= is_first_cin;
            is_last_cin_reg  <= is_last_cin;
        end
    end

    // --- 3. PE Array (计算底座) ---
    pe_array #(
        .ACC_WIDTH(ACC_WIDTH), .NUM_CHANNELS(NUM_CHANNELS),
        .DSP_MAC_LANES(DSP_MAC_LANES)
    ) u_pe_array (
        .clk(clk), .rst_n(rst_n),
        .win_data_flat(lb_win_flat), .win_valid(lb_win_valid),
        .win_ready(pe_win_ready), .o_busy(pe_busy),
        .input_pending(pe_input_pending),
        .win_x(lb_x), .win_y(lb_y),
        .weights_bus(wb_weights_bus), .cfg_width(conv_out_w),
        .cfg_active_channels(i_oc_block_size),
        .tile_start(tile_start), .cfg_tile_y_base(cfg_tile_y_base),
        .cfg_tile_rows(cfg_tile_rows), .tile_ready(pe_tile_ready),
        .mac_ready(pe_mac_ready), .tile_done(tile_done), .protocol_error(pe_tile_error),
        .is_first_cin(is_first_cin_reg), .is_last_cin(is_last_cin_reg),
        .out_sum_bus(pe_sum_bus), .out_valid_bus(pe_valid_bus),
        .out_x_bus(pe_x_bus), .out_y_bus(pe_y_bus)
    );

    // Simulation-only full-width reference for the legacy activation probe.
    // Hardware performs the same additions two lanes at a time below.
`ifdef MODEL_TECH
    genvar i_bias;
    generate
        for (i_bias = 0; i_bias < NUM_CHANNELS; i_bias = i_bias + 1) begin : GEN_BIAS_ADD
            wire signed [ACC_WIDTH-1:0] pe_sum_i;
            wire signed [ACC_WIDTH-1:0] bias_i;
            wire signed [ACC_WIDTH-1:0] sum_i;
            assign pe_sum_i = pe_sum_bus[i_bias*ACC_WIDTH +: ACC_WIDTH];
            assign bias_i   = bias_bus[i_bias*32 +: ACC_WIDTH];
            assign sum_i    = pe_sum_i + bias_i;
            assign bias_sum_bus[i_bias*ACC_WIDTH +: ACC_WIDTH] = sum_i;
        end
    endgenerate
`endif

    assign bias_valid   = pe_valid_bus[0];
    assign bias_x       = pe_x_bus[7:0];
    assign bias_y       = pe_y_bus[7:0];

    // Exact activation and quantization are fused so only uint8 values cross
    // the pipeline boundary. Latency and arithmetic match the original pair.
    activation_quant_fused #(
        .ACC_WIDTH(ACC_WIDTH), .NUM_CHANNELS(NUM_CHANNELS)
    ) u_activation_quant (
        .clk(clk), .rst_n(rst_n),
        .cfg_activation_type(cfg_activation_type), .shift_bits(shift_bits),
        .in_sum_bus(pe_sum_bus), .in_bias_pair(bias_pair_bus),
        .in_valid(bias_valid), .bias_pair_addr(bias_pair_addr),
        .in_x(bias_x), .in_y(bias_y),
        .out_pixel_bus(quant_out_bus), .out_valid(quant_valid),
        .stage_valid(act_valid), .busy(quant_busy),
        .out_x(quant_x), .out_y(quant_y)
    );

    // Existing RTL regressions observe the former activation boundary. Keep a
    // simulation-only reference instance; it is absent from the FPGA netlist.
`ifdef MODEL_TECH
    activation_core #(
        .ACC_WIDTH(ACC_WIDTH), .NUM_CHANNELS(NUM_CHANNELS)
    ) u_activation_sim_reference (
        .clk(clk), .rst_n(rst_n),
        .cfg_activation_type(cfg_activation_type),
        .in_sum_bus(bias_sum_bus), .in_valid(bias_valid),
        .in_x(bias_x), .in_y(bias_y),
        .act_out_bus(act_out_bus), .act_valid(),
        .act_x(act_x), .act_y(act_y)
    );
`else
    assign act_out_bus = {SUM_WIDTH{1'b0}};
    assign act_x = 8'd0;
    assign act_y = 8'd0;
`endif

`ifdef NPU_COORD_TRACE
    // Simulation-only coordinate trace used to size the reorder window.
    // Keep this out of board debug paths so it cannot perturb GMII timing.
    integer coord_trace_cycle;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coord_trace_cycle <= 0;
        end else begin
            coord_trace_cycle <= coord_trace_cycle + 1;
            if (quant_valid) begin
                $display("NPU_COORD,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                         coord_trace_cycle, i_current_cin,
                         kernel_size, padding_en,
                         conv_out_w, conv_out_h, quant_x, quant_y);
            end
        end
    end
`endif

    // Tile outputs are already raster ordered. Keep the selected bounded reorder
    // active for all pooled kernels so its output carries global coordinates.
    wire pool_reorder_en = cfg_pool_en;
    wire [7:0] reorder_x, reorder_y;
    generate
    if (POOL_REORDER_IMPL == 2) begin : GEN_POOL_REORDER_DIRECT
        // The two-row scheduler already emits each completed tile in global
        // row-major order.  Forwarding the tagged quantized stream preserves
        // pool coordinates and removes a redundant three-row 128-bit buffer.
        assign pool_reorder_input_ready = 1'b1;
        assign pool_reorder_rdata = quant_out_bus;
        assign pool_reorder_rvalid = quant_valid;
        assign pool_reorder_busy = 1'b0;
        assign o_pool_reorder_error = 1'b0;
        assign reorder_x = quant_x;
        assign reorder_y = quant_y;
        assign o_pool_reorder_dbg0 = {8'h02, 8'd0, quant_y, quant_x};
        assign o_pool_reorder_dbg1 = {16'd0, quant_y, quant_x};
        assign o_pool_reorder_dbg2 = 32'd0;
        assign o_pool_reorder_dbg3 = 32'd0;
        assign o_pool_reorder_dbg4 = 32'd0;
        assign o_pool_reorder_dbg5 = 32'd0;
        assign o_pool_reorder_dbg6 = 32'd0;
        assign o_pool_reorder_dbg7 = 32'd0;
        assign o_pool_reorder_dbg8 = 32'd0;
        assign o_pool_reorder_dbg9 = 32'd0;
        assign o_pool_reorder_dbg10 = 32'd0;
        assign o_pool_reorder_dbg11 = 32'd0;
        assign o_pool_reorder_dbg12 = 32'd0;
        assign o_pool_reorder_dbg13 = 32'd0;
        assign o_pool_reorder_dbg14 = 32'd0;
        assign o_pool_reorder_dbg15 = 32'd0;
        assign o_pool_reorder_dbg16 = 32'd0;
        assign o_pool_reorder_dbg17 = 32'd0;
        assign o_pool_reorder_dbg18 = 32'd0;

        assign m_axi_arid = 4'd0;
        assign m_axi_araddr = 32'd0;
        assign m_axi_arlen = 8'd0;
        assign m_axi_arsize = 3'd0;
        assign m_axi_arburst = 2'd0;
        assign m_axi_arlock = 1'b0;
        assign m_axi_arcache = 4'd0;
        assign m_axi_arprot = 3'd0;
        assign m_axi_arvalid = 1'b0;
        assign m_axi_rready = 1'b1;
        assign m_axi_awid = 4'd0;
        assign m_axi_awaddr = 32'd0;
        assign m_axi_awlen = 8'd0;
        assign m_axi_awsize = 3'd0;
        assign m_axi_awburst = 2'd0;
        assign m_axi_awlock = 1'b0;
        assign m_axi_awcache = 4'd0;
        assign m_axi_awprot = 3'd0;
        assign m_axi_awvalid = 1'b0;
        assign m_axi_wid = 4'd0;
        assign m_axi_wdata = 32'd0;
        assign m_axi_wstrb = 4'd0;
        assign m_axi_wlast = 1'b0;
        assign m_axi_wvalid = 1'b0;
        assign m_axi_bready = 1'b1;
    end else begin : GEN_POOL_REORDER_LEGACY
    assign reorder_x = 8'd0;
    assign reorder_y = 8'd0;
    pool_reorder_buffer #(
        .BUS_WIDTH    (BUS_WIDTH),
        .ADDR_WIDTH   (POOL_REORDER_AW),
        .MEMORY_DEPTH (POOL_REORDER_DEPTH),
        .USE_AXI      (USE_POOL_REORDER_AXI),
        .AXI_BURST_BEATS(POOL_AXI_BURST_BEATS)
    ) u_pool_reorder (
        .clk                 (clk),
        .rst_n               (rst_n),
        .i_clear             (layer_start_clr || !cfg_pool_en),
        .i_enable            (pool_reorder_en),
        .i_width             (conv_out_w),
        .i_height            (conv_out_h),
        .i_scratch_base_addr (i_pool_scratch_base_addr),
        .i_in_valid          (quant_valid),
        .i_in_data           (quant_out_bus),
        .i_in_x              (quant_x),
        .i_in_y              (quant_y),
        .o_input_ready       (pool_reorder_input_ready),
        .o_out_data          (pool_reorder_rdata),
        .o_out_valid         (pool_reorder_rvalid),
        .o_busy              (pool_reorder_busy),
        .o_error             (o_pool_reorder_error),
        .o_dbg0              (o_pool_reorder_dbg0),
        .o_dbg1              (o_pool_reorder_dbg1),
        .o_dbg2              (o_pool_reorder_dbg2),
        .o_dbg3              (o_pool_reorder_dbg3),
        .o_dbg4              (o_pool_reorder_dbg4),
        .o_dbg5              (o_pool_reorder_dbg5),
        .o_dbg6              (o_pool_reorder_dbg6),
        .o_dbg7              (o_pool_reorder_dbg7),
        .o_dbg8              (o_pool_reorder_dbg8),
        .o_dbg9              (o_pool_reorder_dbg9),
        .o_dbg10             (o_pool_reorder_dbg10),
        .o_dbg11             (o_pool_reorder_dbg11),
        .o_dbg12             (o_pool_reorder_dbg12),
        .o_dbg13             (o_pool_reorder_dbg13),
        .o_dbg14             (o_pool_reorder_dbg14),
        .o_dbg15             (o_pool_reorder_dbg15),
        .o_dbg16             (o_pool_reorder_dbg16),
        .o_dbg17             (o_pool_reorder_dbg17),
        .o_dbg18             (o_pool_reorder_dbg18),
        .m_axi_arid          (m_axi_arid),
        .m_axi_araddr        (m_axi_araddr),
        .m_axi_arlen         (m_axi_arlen),
        .m_axi_arsize        (m_axi_arsize),
        .m_axi_arburst       (m_axi_arburst),
        .m_axi_arlock        (m_axi_arlock),
        .m_axi_arcache       (m_axi_arcache),
        .m_axi_arprot        (m_axi_arprot),
        .m_axi_arvalid       (m_axi_arvalid),
        .m_axi_arready       (m_axi_arready),
        .m_axi_rid           (m_axi_rid),
        .m_axi_rdata         (m_axi_rdata),
        .m_axi_rresp         (m_axi_rresp),
        .m_axi_rlast         (m_axi_rlast),
        .m_axi_rvalid        (m_axi_rvalid),
        .m_axi_rready        (m_axi_rready),
        .m_axi_awid          (m_axi_awid),
        .m_axi_awaddr        (m_axi_awaddr),
        .m_axi_awlen         (m_axi_awlen),
        .m_axi_awsize        (m_axi_awsize),
        .m_axi_awburst       (m_axi_awburst),
        .m_axi_awlock        (m_axi_awlock),
        .m_axi_awcache       (m_axi_awcache),
        .m_axi_awprot        (m_axi_awprot),
        .m_axi_awvalid       (m_axi_awvalid),
        .m_axi_awready       (m_axi_awready),
        .m_axi_wid           (m_axi_wid),
        .m_axi_wdata         (m_axi_wdata),
        .m_axi_wstrb         (m_axi_wstrb),
        .m_axi_wlast         (m_axi_wlast),
        .m_axi_wvalid        (m_axi_wvalid),
        .m_axi_wready        (m_axi_wready),
        .m_axi_bid           (m_axi_bid),
        .m_axi_bresp         (m_axi_bresp),
        .m_axi_bvalid        (m_axi_bvalid),
        .m_axi_bready        (m_axi_bready)
    );
    end
    endgenerate

    // One reserved synchronous SRAM response and its window cannot be stalled.
    // Close the read credit during those stages and all eight PE issue rounds.
    assign pixel_in_ready = pe_mac_ready && pe_win_ready && !pixel_in_valid &&
                            !lb_win_valid && !lbc_busy && !quant_busy &&
                            ((!pool_reorder_en) || pool_reorder_input_ready);
    assign lb_pool_data_in = pool_reorder_en ? pool_reorder_rdata : quant_out_bus;
    // Pool state advances only on real quantized tile outputs.
    assign lb_pool_data_valid = cfg_pool_en
                              ? (pool_reorder_en ? pool_reorder_rvalid : quant_valid)
                              : 1'b0;

    // Clear pool only at tile start; never discard it at a Cin-group boundary.
    reg cfg_pool_en_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cfg_pool_en_d1 <= 1'b0;
        else        cfg_pool_en_d1 <= cfg_pool_en;
    end
    wire lbp_clr = tile_start || (cfg_pool_en && !cfg_pool_en_d1);

    // --- 7. 可选池化尾部 (Quant -> Pool) ---
    line_buffer_pool #(
        .NUM_CHANNELS(NUM_CHANNELS)
    ) u_lb_pool (
        .clk(clk), .rst_n(rst_n),
        .i_clr(lbp_clr),
        .cfg_width(conv_out_w), .cfg_height(conv_out_h),
        .data_in(lb_pool_data_in), .data_in_valid(lb_pool_data_valid),
        .in_x(reorder_x), .in_y(reorder_y),
        .pool_data_out(pool_out_bus), .pool_valid(pool_out_valid),
        .out_x(pool_out_x), .out_y(pool_out_y)
    );

    // --- 8. 末组 lane 掩码 (Cout 分组末组有效 lane 不足 NUM_CHANNELS 时, 高位 lane 强制 0) ---
    wire [BUS_WIDTH-1:0] w_out_pre_mask;
    assign w_out_pre_mask = cfg_pool_en ? pool_out_bus : quant_out_bus;

    genvar i_mask;
    generate
        for (i_mask = 0; i_mask < NUM_CHANNELS; i_mask = i_mask + 1) begin : GEN_LANE_MASK
            assign out_pixel_bus[i_mask*8 +: 8] =
                ({1'b0, i_mask[3:0]} < i_oc_block_size)
                    ? w_out_pre_mask[i_mask*8 +: 8]
                    : 8'd0;
        end
    endgenerate

    assign out_valid     = cfg_pool_en ? pool_out_valid : quant_valid;
    assign out_x         = cfg_pool_en ? pool_out_x : quant_x;
    assign out_y         = cfg_pool_en ? pool_out_y : quant_y;

    // MAC (4), accumulator (2), activation/quantization and pool have bounded
    // valid latency. Every visible valid and reorder pending operation reloads
    // a conservative 16-cycle guard, also covering non-final-Cin RAM commits.
    // PSUM active is deliberately not busy: it persists between Cin groups.
    reg [4:0] r_post_drain_cnt;  // 5-bit, max 31
    wire any_downstream_valid = lb_win_valid          // PE 输入端
                              || (|pe_valid_bus)       // PE 输出 / accumulator final
                              || pe_input_pending      // one-entry PE input skid
                              || act_valid             // activation 输出
                              || quant_busy            // shared quantizer in flight
                              || quant_valid           // quant 输出
                              || pool_reorder_busy
                              || pool_reorder_rvalid
                              || pool_out_valid;       // pool 输出
    wire pipeline_active = lbc_busy || pixel_in_valid || pe_busy || any_downstream_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  r_post_drain_cnt <= 5'd0;
        else if (layer_start_clr)    r_post_drain_cnt <= 5'd0;
        else if (pipeline_active)    r_post_drain_cnt <= 5'd16;
        else if (r_post_drain_cnt > 0) r_post_drain_cnt <= r_post_drain_cnt - 1'b1;
    end
    assign o_pipeline_idle = (r_post_drain_cnt == 5'd0) && !pipeline_active;

    // Wide XOR telemetry duplicated the highest-fanout NPU buses and created
    // hundreds of routes without affecting inference. Keep the ports for board
    // compatibility while disabling only these diagnostic checksums.
    assign o_dbg_pe_fold    = 32'd0;
    assign o_dbg_bias_fold  = 32'd0;
    assign o_dbg_quant_fold = 32'd0;
    reg pixel_in_valid_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pixel_in_valid_d1 <= 1'b0;
        else        pixel_in_valid_d1 <= pixel_in_valid;
    end
    assign o_dbg_wt_fold     = 32'd0;
    assign o_dbg_valid_flags = {o_pipeline_idle,
                                out_valid,
                                quant_valid,
                                bias_valid,
                                (|pe_valid_bus),
                                lb_win_valid,
                                pixel_in_valid_d1,
                                pixel_in_valid};

endmodule

`resetall
