// ----------------------------------------------------------------------------
// 3. Weight Buffer
// [升级]：144-bit 双通道装载 + 单页组缓存
//
// [Step 15.3 重构 2026-05-02]
// 原版使用单一 reg [71:0] weight_page [0:1][0:511] + always@* 组合 16 路读，
// 国产 EDA (Quartus 系) 无法将其推断为 BRAM（原因：异步读 + 16 路并行）,
// 全部展开为寄存器 + 9-bit×16 路 MUX 树 ≈ 10万 LE，使 LE 资源严重溢出。
//
// 重构思路：把原本的 reg [0:1][0:511][72b] (= 2 页×16 cin×16 ch) 拆为
//   16 个独立 bank（按 ch_idx 划分），每 bank = reg [0:63][72b]
//   (=2 页×32 cin)，以 Quartus 友好的同步读模板推断为 M9K BRAM。
//   - 读：16 banks 同拍同步读，每 bank 1× 读口不存在处理冲突。
//   - 写：weight_in_addr[3:0] 选中主 bank，同拍还写入 (主 bank+1) 以
//          接纳 144-bit 双通道 (奇偶 ch 对)。两块不同 bank、不同物理 RAM,
//          同拍写 OK。
//
// 外部接口不变。每个 bank 使用分布式 RAM 的异步读口；BCU 只会在整条
// 计算流水清空后切换 Cin，因此读地址在一个窗口的八轮 MAC 期间保持稳定。
//
// 保留 active_page / dma_page 名字供现有 cocotb 诊断探针使用。
// ----------------------------------------------------------------------------
module weight_buffer #(
    parameter NUM_CHANNELS  = 16,
    parameter MAX_CIN       = 32    // 支持 Conv 层最大 Cin（FC 层需外部分组流式加载）
) (
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [1:0]                   kernel_size,

    // DMA 写入接口（144-bit 双通道，flat 地址）
    input  wire [143:0]                 weight_in_data,
    input  wire                         weight_in_valid,
    input  wire [9:0]                   weight_in_addr,  // flat 写入地址，每拍写 2 条目

    // 组边界翻页：DMA 完成一页写入后拉低 update_weights_en 触发切换
    input  wire                         update_weights_en,

    // 计算侧读接口：按当前 Cin 索引读出 16 路权重
    input  wire [7:0]                   i_current_cin,

    // 输出权重总线
    output wire [NUM_CHANNELS*72-1:0]   weights_bus_out
);
    // The sequencer is strictly LOAD -> wait DMA done -> CALC.  No parameter
    // write is issued while a group is computing, so a second page duplicates
    // storage without providing overlap.  One page releases 576 MSLICE RAMs.
    localparam BANK_AW   = $clog2(MAX_CIN); // 5

    // ------------------------------------------------------------------------
    // 页 / 握手状态 (保留 active_page / dma_page 名供 cocotb 探针)
    // ------------------------------------------------------------------------
    reg        active_page; // 当前计算页
    reg        dma_page;    // DMA 写入页 (= ~active_page after commit)
    reg        update_en_d;

    wire update_fall = update_en_d && !update_weights_en; // 末沿表示一页写满

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_page <= 1'b0;
            dma_page    <= 1'b0;
            update_en_d <= 1'b0;
        end else begin
            update_en_d <= update_weights_en;
            if (update_fall) begin
                active_page <= dma_page;   // 计算页切换
                dma_page    <= ~dma_page;  // 预留下一页供 DMA
            end
        end
    end

    // ------------------------------------------------------------------------
    // 页 / cin / ch 拆分
    //   原本 weight_in_addr = cin_local * 16 + oc_pair  (oc_pair ∈ {0,2,..,14})
    //   本拍写 oc_pair (主 bank) 与 oc_pair+1 (右邻 bank) 两个 72-bit 条目。
    // ------------------------------------------------------------------------
    wire [3:0] wr_bank_lo = weight_in_addr[3:0];                // 主 bank (偶 ch)
    wire [3:0] wr_bank_hi = weight_in_addr[3:0] + 4'd1;          // 邻 bank (奇 ch)
    wire [4:0] wr_cin     = weight_in_addr[8:4];                // cin_local (页内)
    wire [BANK_AW-1:0] wr_addr = wr_cin[BANK_AW-1:0];
    wire [BANK_AW-1:0] rd_addr = i_current_cin[BANK_AW-1:0];

    // Kernel mode is decoded before the parameter DMA request and stays fixed
    // until the group completes.  Map the two incoming channels once at the
    // write port instead of instantiating the same mapper on all sixteen read
    // ports.  The stored representation is exactly the 72-bit PE layout.
    wire [71:0] mapped_weight_lo;
    wire [71:0] mapped_weight_hi;

    weight_kernel_mapper u_write_mapper_lo (
        .i_raw_w      (weight_in_data[71:0]),
        .i_kernel_size(kernel_size),
        .o_mapped_w   (mapped_weight_lo)
    );

    weight_kernel_mapper u_write_mapper_hi (
        .i_raw_w      (weight_in_data[143:72]),
        .i_kernel_size(kernel_size),
        .o_mapped_w   (mapped_weight_hi)
    );

    // ------------------------------------------------------------------------
    // 16 个独立 bank。**关键修复 v2 (2026-05-02)**:
    //   把 mem 声明下沉到 generate 块内, 每个 bank 是独立的 1D reg 数组,
    //   仿照 fm_bank_array.v 已被验证可推 BRAM 的模板。原先用二维数组
    //   reg [71:0] weight_bank [0:15][0:63] 在 Quartus 系下无法推 M9K
    //   (Cannot regroup multidimensional array) → 全部退化为寄存器。
    //   每 bank 容纳 2 页 × MAX_CIN cin = 64 条 72-bit 词 ≈ 4.6 Kbit ≈ 1×M9K。
    // ------------------------------------------------------------------------
    wire [71:0] wb_rd_data_w [0:NUM_CHANNELS-1];

    genvar gw;
    generate
        for (gw = 0; gw < NUM_CHANNELS; gw = gw + 1) begin : G_BANK
            // 单维 1D RAM, 声明于 generate 内, 匹配多 EDA 系 RAM 推断模板。
            // Xilinx build 下每 bank 只有 64x72, 强推 BRAM 会浪费 1 个 RAMB36；
            // 改用 LUTRAM 可释放足够 BRAM 给 channel_accumulator 深 PSUM。
`ifdef NPU_USE_XPM_BRAM
            (* ram_style = "distributed" *)
`else
            // 72-bit-wide shallow banks waste two ERAM macros per lane.
            // Distributed RAM leaves ERAM for the much larger feature maps.
            // TD/eLinx recognizes the synthesis comment below for MSLICE RAM.
            // The generic attributes alone were ignored and consumed 32 ERAMs.
            (* syn_ramstyle = "distributed", ram_style = "distributed" *)
`endif
            reg [71:0] mem [0:MAX_CIN-1]; // synthesis ram_style=dram

            // ----------------------------------------------------------------
            // **关键修复 v3 (2026-05-02)**: 标准 1R1W 单写口模板
            //   原先用两个独立 if (wr_bank_lo==gw) / if (wr_bank_hi==gw) 都写
            //   mem[wr_addr], 虽然条件互斥 (hi=lo+1), 但 Quartus 静态分析
            //   器识别为 "多驱动" 模式 → 拒绝 BRAM 推断。
            //   改为合并一个 we 信号 + data MUX 的标准写法, 与 fm_bank_array
            //   成功推断的模板一致。
            // ----------------------------------------------------------------
            wire we_lo  = weight_in_valid && (wr_bank_lo == gw[3:0]);
            wire we_hi  = weight_in_valid && (wr_bank_hi == gw[3:0]);
            wire bank_we = we_lo | we_hi;
            // we_lo / we_hi 互斥 (hi = lo + 1), 选择写哪 72-bit 字段
            wire [71:0] bank_wd = we_hi ? mapped_weight_hi : mapped_weight_lo;

            always @(posedge clk) begin
                if (bank_we)
                    mem[wr_addr] <= bank_wd;
            end

            // MSLICE distributed RAM has a native asynchronous read port.
            // Avoiding a 72-bit output register per bank removes 1152 FFs.
            assign wb_rd_data_w[gw] = mem[rd_addr];
        end
    endgenerate

    // RAM contents are already in PE layout, so the sixteen synchronous read
    // ports connect directly to the output bus.
    genvar gm;
    generate
        for (gm = 0; gm < NUM_CHANNELS; gm = gm + 1) begin : G_BANK_MAP
            assign weights_bus_out[gm*72 +: 72] = wb_rd_data_w[gm];
        end
    endgenerate

endmodule
