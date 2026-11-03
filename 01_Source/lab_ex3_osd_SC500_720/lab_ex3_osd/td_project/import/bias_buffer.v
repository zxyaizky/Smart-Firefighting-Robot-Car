// ----------------------------------------------------------------------------
// Bias Buffer
// 分组偏置单页缓存：16 路 INT32。
// 参数 DMA 与计算严格串行，计算期间不会改写偏置，因此双页不会带来
// 吞吐收益，反而额外占用 512 个寄存器。
// ----------------------------------------------------------------------------
module bias_buffer #(
    parameter NUM_CHANNELS = 16
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // DMA 写入接口
    input  wire [31:0]                   bias_in_data,
    input  wire                          bias_in_valid,
    input  wire [4:0]                    bias_in_addr,
    input  wire                          update_bias_en,
    input  wire [2:0]                    bias_pair_addr,

    // Two adjacent channels are consumed by the shared quantizer each cycle.
    output wire [63:0]                   bias_pair_out
`ifdef MODEL_TECH
    , output reg [NUM_CHANNELS*32-1:0]   bias_bus_debug
`endif
);
    // Split even and odd lanes into two single-read distributed RAM banks.
    // This replaces 512 bias FFs and presents exactly the two lanes used by
    // the time-multiplexed activation/quantization datapath.
    (* syn_ramstyle = "distributed", ram_style = "distributed" *)
    reg [31:0] bias_even [0:(NUM_CHANNELS/2)-1]; // synthesis ram_style=dram
    (* syn_ramstyle = "distributed", ram_style = "distributed" *)
    reg [31:0] bias_odd  [0:(NUM_CHANNELS/2)-1]; // synthesis ram_style=dram

    assign bias_pair_out = {bias_odd[bias_pair_addr],
                            bias_even[bias_pair_addr]};

    // Do not reset RAM contents: every group loads all sixteen biases before
    // compute starts. A reset loop would force these arrays back into FFs.
    always @(posedge clk) begin
        if (bias_in_valid && (bias_in_addr < NUM_CHANNELS)) begin
            if (bias_in_addr[0])
                bias_odd[bias_in_addr[3:1]] <= bias_in_data;
            else
                bias_even[bias_in_addr[3:1]] <= bias_in_data;
        end
    end

`ifdef MODEL_TECH
    integer map_i;
    always @(*) begin
        for (map_i = 0; map_i < NUM_CHANNELS/2; map_i = map_i + 1) begin
            bias_bus_debug[(map_i*2)*32 +: 32] = bias_even[map_i];
            bias_bus_debug[(map_i*2+1)*32 +: 32] = bias_odd[map_i];
        end
    end
`endif

    // Kept in the interface for compatibility with the existing DMA wrapper.
    // Loading is complete before compute starts, so no page-commit action is
    // required on update_bias_en.
    wire unused_rst_n = rst_n;
    wire unused_update_bias_en = update_bias_en;
endmodule
