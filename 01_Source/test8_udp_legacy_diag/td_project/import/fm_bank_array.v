// -----------------------------------------------------------------------------
// 2026-10-16: NPU_FM_PRODUCTION_SIM explicitly tests the same packed RAM
// implementation used for synthesis, even under ModelSim. Packed RAM accepts
// full-word writes only; streamed RGB must assemble complete words upstream.
// Module      : fm_bank_array
// Description : 特征图双端口 PING/PONG BRAM 阵列。
//               支持单周期 16 通道并行写入，1 通道门控挂起读取。
//
// [Step 15.6 · 2026-05-03] BANK_DEPTH 双值（sim/synth 解耦）
//   ─────────────────────────────────────────────────────────────────────────
//   FaceNet 实际单 bank 最大写入 = C1 输出 60×80 = 4800 (BCU 永不生成 > 4799 的
//   addr 给 fm_bank_array, 见 bcu.v:282 w_full_rd_addr 计算).
//
//   双值原因：
//   - 仿真侧: 保 8192 防御性, 兼容未来更大模型 (e.g. 90×90 单平面 cin_groups=1).
//   - 综合侧: 5120 = next 1K-aligned ≥ 4800, 提供 6.6% 安全余量.
//             节省 ~3 M9K/bank × 16 banks × 2 arrays = ~96 块 BRAM (vs 8192).
//
//   LBP 输入图像 (160x120=19200) 使用独立 lbp_input_buffer, 不挤占本阵列.
//
// [Step 15.7 · 2026-05-03] BANK_DEPTH 选择策略 — fail-safe 反转默认
// -----------------------------------------------------------------------------
// 设计原则: 默认就是综合安全的 5120, 仅当识别到主流仿真器自动注入的私有宏时
//           才扩展到 8192 防御性深度。任何 EDA 综合工具均不会注入这些仿真器宏,
//           因此综合时永远是 5120, 即使忘了 +define+SYNTHESIS 也不会浪费 BRAM。
//
// 历史教训: 之前用 `ifdef SYNTHESIS / `else 的方式, 默认是 8192, 万一综合工具
//           没注入 SYNTHESIS 宏就会静默回落到大深度浪费综合时间。尝试用 `error
//           哨兵失败 (eLinx 预处理器不支持 `error 指令, 见 Step 15.7 v1)。
//
// 仿真器宏自动注入的来源 (无需 Makefile 显式 +define):
//   - COCOTB_SIM : cocotb 框架自动注入 (本项目所有 Makefile.* 走此路径)
//   - MODEL_TECH : Mentor Modelsim/QuestaSim 内置
//   - VCS        : Synopsys VCS 内置
//   - IVERILOG   : Icarus Verilog 内置
//   - XCELIUM    : Cadence Xcelium 内置
// -----------------------------------------------------------------------------
`ifdef COCOTB_SIM
  `define FM_BANK_DEPTH_SIM
`endif
`ifdef MODEL_TECH
  `define FM_BANK_DEPTH_SIM
`endif
`ifdef VCS
  `define FM_BANK_DEPTH_SIM
`endif
`ifdef IVERILOG
  `define FM_BANK_DEPTH_SIM
`endif
`ifdef XCELIUM
  `define FM_BANK_DEPTH_SIM
`endif
`ifdef NPU_FM_PRODUCTION_SIM
  `undef FM_BANK_DEPTH_SIM
`endif

module fm_bank_array #(
`ifdef FM_BANK_DEPTH_SIM
    parameter BANK_DEPTH = 8192,
`else
    parameter BANK_DEPTH = 5120,
`endif
    parameter LARGE_BANKS = 16,
    parameter SMALL_BANK_DEPTH = BANK_DEPTH
)(
    input  wire         clk,

    // Write Port (128-bit parallel, broadcast to all active banks)
    input  wire [127:0] i_write_bus,
    input  wire         i_write_en,
    input  wire [15:0]  i_write_mask,
    input  wire [12:0]  i_write_addr,

    // Read Port (8-bit singular hanging read, gated by cin_idx)
    input  wire [3:0]   i_read_cin_idx,
    input  wire         i_read_en,
    input  wire [12:0]  i_read_addr,
    output wire [7:0]   o_read_data
);

    // [Step 15.8] 地址位宽精确匹配 BRAM 深度 (消除越界索引, 保证 eLinx 推 BRAM)
    //   当 BANK_DEPTH=2048 而 i_*_addr 是 13-bit 时, 若直接用 mem[i_read_addr] 访问
    //   [0:2047] 数组, 索引 2048~8191 语义越界, eLinx 会放弃 BRAM 推断, 全展为寄存器
    //   (实测 ping 爆 LE ~44 万)。故此处先截断到实际 BRAM 深度位宽再索引。
    function integer addr_width;
        input integer depth;
        integer value;
        begin
            value = depth - 1;
            addr_width = 0;
            while (value > 0) begin
                addr_width = addr_width + 1;
                value = value >> 1;
            end
            if (addr_width == 0) addr_width = 1;
        end
    endfunction

    // 内部信号声明
    wire [7:0] w_bank_read_data [0:15];
    reg  [3:0] r_read_cin_idx_d1;

    // 为了配合 SRAM 固有的一周期读取延时，将通道选择打一拍用于 MUX 选通
    always @(posedge clk) begin
        r_read_cin_idx_d1 <= i_read_cin_idx;
    end

    genvar i;
    generate
`ifdef FM_BANK_DEPTH_SIM
        for (i = 0; i < 16; i = i + 1) begin : gen_sram_bank
            localparam THIS_DEPTH = (i < LARGE_BANKS) ? BANK_DEPTH : SMALL_BANK_DEPTH;
            localparam THIS_ADDR_W = addr_width(THIS_DEPTH);
            wire [THIS_ADDR_W-1:0] w_write_addr_trim = i_write_addr[THIS_ADDR_W-1:0];
            wire [THIS_ADDR_W-1:0] w_read_addr_trim  = i_read_addr[THIS_ADDR_W-1:0];
`ifdef NPU_USE_XPM_BRAM
            wire [7:0] r_data_out;
            wire w_bank_rd_en = i_read_en & (i_read_cin_idx == i);
            wire w_bank_we = i_write_en & i_write_mask[i];

            npu_xilinx_sdpram #(
                .DATA_WIDTH  (8),
                .ADDR_WIDTH  (THIS_ADDR_W),
                .MEMORY_DEPTH(THIS_DEPTH)
            ) u_bank_bram (
                .clk     (clk),
                .wr_en   (w_bank_we),
                .wr_strb (1'b1),
                .wr_addr (w_write_addr_trim),
                .wr_data (i_write_bus[(i*8)+7 : i*8]),
                .rd_en   (w_bank_rd_en),
                .rd_addr (w_read_addr_trim),
                .rd_data (r_data_out)
            );
`else
            // 强制推断为 Block RAM (Synplify-style 属性，匹配 eLinx 内核)
            (* syn_ramstyle = "block_ram", ram_style = "block" *)
            reg [7:0] mem [0:THIS_DEPTH-1];
            reg [7:0] r_data_out;
            
            // 当前 bank 独立唤醒使能，省电设计核心
            wire w_bank_rd_en = i_read_en & (i_read_cin_idx == i);
            wire w_bank_we = i_write_en & i_write_mask[i];
            
            // 写入逻辑 (按 8-bit 片选切分总线)
            always @(posedge clk) begin
                if (w_bank_we) begin
                    mem[w_write_addr_trim] <= i_write_bus[(i*8)+7 : i*8];
                end
            end
            
            // 读取逻辑
            always @(posedge clk) begin
                if (w_bank_rd_en) begin
                    r_data_out <= mem[w_read_addr_trim];
                end
            end
`endif
            
            assign w_bank_read_data[i] = r_data_out;
        end
`else
        // Production mapping packs byte lanes into wide words.  The deployed
        // path always writes a complete 128-bit word (including zeroed invalid
        // Cout lanes), so independent 8-bit banks only waste ERAM depth.  This
        // representation stores the same address/lane layout while allowing TD
        // to cascade the minimum number of 20-Kbit macros.
        if (LARGE_BANKS == 16) begin : gen_packed_all
            reg [127:0] mem [0:BANK_DEPTH-1]; /* fehdl force_ram=1, ram_style="bram_fast" */
            reg [127:0] read_word;
            always @(posedge clk) begin
                if (i_write_en)
                    mem[i_write_addr[addr_width(BANK_DEPTH)-1:0]] <= i_write_bus;
                if (i_read_en)
                    read_word <= mem[i_read_addr[addr_width(BANK_DEPTH)-1:0]];
            end
            assign o_read_data = read_word[r_read_cin_idx_d1*8 +: 8];
        end else begin : gen_packed_split
            localparam LOW_W  = LARGE_BANKS * 8;
            localparam HIGH_W = (16 - LARGE_BANKS) * 8;
            reg [LOW_W-1:0] low_mem [0:BANK_DEPTH-1]; /* fehdl force_ram=1, ram_style="bram_fast" */
            reg [HIGH_W-1:0] high_mem [0:SMALL_BANK_DEPTH-1]; /* fehdl force_ram=1, ram_style="bram_fast" */
            reg [LOW_W-1:0] low_read_word;
            reg [HIGH_W-1:0] high_read_word;
            always @(posedge clk) begin
                if (i_write_en) begin
                    low_mem[i_write_addr[addr_width(BANK_DEPTH)-1:0]] <= i_write_bus[LOW_W-1:0];
                    if (i_write_addr < SMALL_BANK_DEPTH)
                        high_mem[i_write_addr[addr_width(SMALL_BANK_DEPTH)-1:0]] <= i_write_bus[127:LOW_W];
                end
                if (i_read_en) begin
                    if (i_read_cin_idx < LARGE_BANKS)
                        low_read_word <= low_mem[i_read_addr[addr_width(BANK_DEPTH)-1:0]];
                    else if (i_read_addr < SMALL_BANK_DEPTH)
                        high_read_word <= high_mem[i_read_addr[addr_width(SMALL_BANK_DEPTH)-1:0]];
                end
            end
            assign o_read_data = (r_read_cin_idx_d1 < LARGE_BANKS)
                               ? low_read_word[r_read_cin_idx_d1*8 +: 8]
                               : high_read_word[(r_read_cin_idx_d1-LARGE_BANKS)*8 +: 8];
        end
`endif
    endgenerate

    // 延时 MUX 选通目标数据
`ifdef FM_BANK_DEPTH_SIM
    assign o_read_data = w_bank_read_data[r_read_cin_idx_d1];
`endif

endmodule
