// -----------------------------------------------------------------------------
// File   : pe_array.v
// Author : OpenAI Codex (integration changes)
// Date   : 2026-09-07
// -----------------------------------------------------------------------------
// Description:
//   Two physical MAC trees, eight issue rounds, sixteen logical PSUM lanes.
// Change Log:
//   2026-09-08  Codex  v3.0  Window handshake, tagged collection, atomic PSUM commit.
//   2026-09-07  Codex  v2.0  Integrate and simulate two-row partial-sum tiling.
//   2026-09-19  Codex  v3.1  Add one-entry elastic window input buffer.
//   2026-09-22  Codex  v3.2  Skip issue rounds for padded output lanes.
//   2026-09-25  Codex  v3.3  Launch queued window during accumulator drain.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// File Name   : pe_array.v
// Description : 16 logical output channels, 2 physical MACs, 8 issue rounds.
// ============================================================================
module pe_array #(
    parameter PIXEL_W = 8,
    parameter WEIGHT_W = 8,
    parameter ACC_WIDTH = 32,
    parameter NUM_CHANNELS = 16,
    parameter DSP_MAC_LANES = 9
)(
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire                   tile_start,
    input  wire [7:0]             cfg_tile_y_base,
    input  wire [7:0]             cfg_tile_rows,
    output wire                   tile_ready,
    output wire                   mac_ready,
    output wire                   tile_done,
    output wire                   protocol_error,

    // 1. 广播级像素总线 (来自 Line Buffer, 72-bit)
    input  wire [PIXEL_W*9-1:0]   win_data_flat, 
    input  wire                   win_valid,
    output wire                   win_ready,
    output wire                   o_busy,
    output wire                   input_pending,
    input  wire [7:0]             win_x,
    input  wire [7:0]             win_y,

    // 2. 独立权重总线 (1152-bit = 16通道 * 9个权重 * 8-bit)
    // 权重排列：通道0权重在低 72 位，通道15权重在高 72 位
    input  wire [NUM_CHANNELS*72-1:0]   weights_bus,
    
    // 3. 状态机控制信号
    input  wire [7:0]             cfg_width,
    input  wire [4:0]             cfg_active_channels,
    input  wire                   is_first_cin,
    input  wire                   is_last_cin,

    // 4. 并行累加结果总线 (打包为一维总线)
    // 输出总和为 512-bit (16 * 32-bit)，其他均为 8 位信号阵列
    output wire [ACC_WIDTH*NUM_CHANNELS-1:0] out_sum_bus,
    output wire [NUM_CHANNELS-1:0]       out_valid_bus,
    output wire [NUM_CHANNELS*8-1:0]     out_x_bus, out_y_bus
);

    localparam PHYSICAL_LANES = 2;
    wire [NUM_CHANNELS-1:0] ready_bus, mac_ready_bus, done_bus, error_bus;
    wire [39:0] pair_sum;
    wire [1:0] pair_valid;
    reg [PIXEL_W*9-1:0] window_reg;
    reg [7:0] x_reg, y_reg;
    reg first_reg, last_reg;
    reg [PIXEL_W*9-1:0] pending_window_reg;
    reg [7:0] pending_x_reg, pending_y_reg;
    reg pending_first_reg, pending_last_reg, pending_valid_reg;
    reg [2:0] pending_round_limit_reg;
    reg active_reg, issue_reg;
    reg [2:0] round_reg;
    reg [2:0] round_limit_reg;
    reg [2:0] round_pipe_reg [0:3];
    reg [3:0] valid_pipe_reg;
    reg [7:0] collected_reg;
    reg [NUM_CHANNELS*20-1:0] results_reg;
    reg commit_reg;
    reg [7:0] commit_x_reg, commit_y_reg;
    reg commit_first_reg, commit_last_reg;
    reg [1:0] commit_pipe_reg;
    reg error_reg;
    integer stage;
    genvar p, lane;

    wire processing_busy = active_reg || issue_reg || (|valid_pipe_reg) || commit_reg ||
                           (|commit_pipe_reg) || (|out_valid_bus);
    // Once the last MAC result has been collected, the result register is
    // stable for the accumulator's commit edge.  With at least ten active
    // output lanes, the queued window can launch as the final pair returns;
    // the commit metadata below preserves the old window for the next edge.
    // Eight lanes must keep the commit-edge spacing or the shared quantizer
    // drops results; still shorter groups retain the full drain spacing.
    wire final_pair_now = valid_pipe_reg[3] && (&pair_valid) &&
                          round_pipe_reg[3] == round_limit_reg;
    wire issue_slot_busy = (active_reg || issue_reg || (|valid_pipe_reg)) &&
                           !(final_pair_now && round_limit_reg >= 3'd4);
    wire accept_window = win_valid && win_ready;
    wire accept_direct = accept_window && !processing_busy;
    wire capture_pending = accept_window && processing_busy;
    // The shared quantizer consumes one complete 16-lane result over eight
    // cycles.  Short output groups can produce results faster than it can
    // accept them, so retain the original drain spacing for those groups.
    wire launch_pending = pending_valid_reg && mac_ready &&
        (round_limit_reg >= 3'd3 ? !issue_slot_busy : !processing_busy);
    wire [2:0] cfg_last_round =
        (cfg_active_channels == 0 || cfg_active_channels > 16) ? 3'd7 :
        (cfg_active_channels <= 2)  ? 3'd0 :
        (cfg_active_channels <= 4)  ? 3'd1 :
        (cfg_active_channels <= 6)  ? 3'd2 :
        (cfg_active_channels <= 8)  ? 3'd3 :
        (cfg_active_channels <= 10) ? 3'd4 :
        (cfg_active_channels <= 12) ? 3'd5 :
        (cfg_active_channels <= 14) ? 3'd6 : 3'd7;
    wire [7:0] expected_collected_before_last =
        (8'h01 << round_limit_reg) - 8'h01;

    assign o_busy = processing_busy;
    assign input_pending = pending_valid_reg;
    assign mac_ready = &mac_ready_bus;
    assign protocol_error = error_reg || (|error_bus) || (NUM_CHANNELS != 16);
    // The input can advance once while the PE processes the prior window.
    // pe_busy/o_busy remains a drain indicator but is not an input-ready term.
    assign win_ready = rst_n && mac_ready && !pending_valid_reg &&
                       !tile_start && !protocol_error;
    assign tile_ready = (&ready_bus) && !processing_busy &&
                        !pending_valid_reg && !protocol_error;
    assign tile_done = &done_bus;

    // The MAC has four registered stages. The tag traverses the same four stages.
    // Metadata remains held until atomic commit drains.  The weight buffer is
    // only rewritten between channel groups, so its synchronous output remains
    // stable throughout all eight issue rounds; duplicating the complete
    // 1152-bit bus here only consumes registers and does not add isolation.
    always @(posedge clk) begin
        valid_pipe_reg <= {valid_pipe_reg[2:0], issue_reg};
        round_pipe_reg[0] <= round_reg;
        for (stage = 1; stage < 4; stage = stage + 1)
            round_pipe_reg[stage] <= round_pipe_reg[stage-1];
        commit_reg <= 1'b0;
        commit_pipe_reg <= {commit_pipe_reg[0], commit_reg};
        if (capture_pending) begin
            pending_window_reg <= win_data_flat;
            pending_x_reg <= win_x;
            pending_y_reg <= win_y;
            pending_first_reg <= is_first_cin;
            pending_last_reg <= is_last_cin;
            pending_round_limit_reg <= cfg_last_round;
            pending_valid_reg <= 1'b1;
        end else if (launch_pending) begin
            pending_valid_reg <= 1'b0;
        end
        if (launch_pending) begin
            window_reg <= pending_window_reg;
            x_reg <= pending_x_reg;
            y_reg <= pending_y_reg;
            first_reg <= pending_first_reg;
            last_reg <= pending_last_reg;
            round_limit_reg <= pending_round_limit_reg;
            active_reg <= 1'b1;
            issue_reg <= 1'b1;
            round_reg <= 3'd0;
            collected_reg <= 8'd0;
        end else if (accept_direct) begin
            window_reg <= win_data_flat;
            x_reg <= win_x;
            y_reg <= win_y;
            first_reg <= is_first_cin;
            last_reg <= is_last_cin;
            round_limit_reg <= cfg_last_round;
            active_reg <= 1'b1;
            issue_reg <= 1'b1;
            round_reg <= 3'd0;
            collected_reg <= 8'd0;
        end else if (issue_reg) begin
            if (round_reg == round_limit_reg) issue_reg <= 1'b0;
            else round_reg <= round_reg + 3'd1;
        end
        if (pair_valid != {2{valid_pipe_reg[3]}}) error_reg <= 1'b1;
        if (valid_pipe_reg[3] && (&pair_valid)) begin
            results_reg[(round_pipe_reg[3]*2)*20 +: 40] <= pair_sum;
            if (!launch_pending)
                collected_reg[round_pipe_reg[3]] <= 1'b1;
            if (!active_reg || collected_reg[round_pipe_reg[3]]) error_reg <= 1'b1;
            if (round_pipe_reg[3] == round_limit_reg) begin
                if (collected_reg != expected_collected_before_last)
                    error_reg <= 1'b1;
                if (!launch_pending) active_reg <= 1'b0;
                commit_x_reg <= x_reg;
                commit_y_reg <= y_reg;
                commit_first_reg <= first_reg;
                commit_last_reg <= last_reg;
                commit_reg <= 1'b1;
            end
        end
        // Preserve the existing active-low interface; reset aborts in-flight work.
        if (!rst_n) begin
            window_reg <= {PIXEL_W*9{1'b0}};
            x_reg <= 8'd0;
            y_reg <= 8'd0;
            first_reg <= 1'b0;
            last_reg <= 1'b0;
            pending_window_reg <= {PIXEL_W*9{1'b0}};
            pending_x_reg <= 8'd0;
            pending_y_reg <= 8'd0;
            pending_first_reg <= 1'b0;
            pending_last_reg <= 1'b0;
            pending_round_limit_reg <= 3'd7;
            pending_valid_reg <= 1'b0;
            active_reg <= 1'b0;
            issue_reg <= 1'b0;
            round_reg <= 3'd0;
            round_limit_reg <= 3'd7;
            valid_pipe_reg <= 4'd0;
            for (stage = 0; stage < 4; stage = stage + 1)
                round_pipe_reg[stage] <= 3'd0;
            collected_reg <= 8'd0;
            results_reg <= {NUM_CHANNELS*20{1'b0}};
            commit_reg <= 1'b0;
            commit_x_reg <= 8'd0;
            commit_y_reg <= 8'd0;
            commit_first_reg <= 1'b0;
            commit_last_reg <= 1'b0;
            commit_pipe_reg <= 2'd0;
            error_reg <= 1'b0;
        end
    end

    generate
        for (p = 0; p < PHYSICAL_LANES; p = p + 1) begin : PHYSICAL_MAC
            wire [71:0] selected_weight;
            assign selected_weight = weights_bus[(round_reg*2+p)*72 +: 72];
            // DSP_MAC_LANES remains a mapping hint; only TWO MAC trees exist.
            mac_tree_3x3 #(
                .PIXEL_W(PIXEL_W), .WEIGHT_W(WEIGHT_W), .OUT_W(20),
                .USE_DSP((p < DSP_MAC_LANES) ? 1 : 0)
            ) u_mac (
                .clk(clk), .rst_n(rst_n),
                .pixels_flat(window_reg), .weights_flat(selected_weight),
                .valid_in(issue_reg), .x_in(x_reg), .y_in(y_reg),
                .is_first_cin(first_reg), .is_last_cin(last_reg),
                .mac_out(pair_sum[p*20 +: 20]), .valid_out(pair_valid[p]),
                .x_out(), .y_out(), .first_cin_out(), .last_cin_out()
            );
        end
        // The final pair is stored before commit_reg is sampled on the next edge.
        // All sixteen logical accumulators still update simultaneously.
        for (lane = 0; lane < NUM_CHANNELS; lane = lane + 1) begin : PE_CORE
            channel_accumulator #(.MAX_WIDTH(160), .TILE_ROWS(2)) u_acc (
                .clk(clk), .rst_n(rst_n), .tile_start(tile_start),
                .tile_ready(ready_bus[lane]), .cfg_tile_y_base(cfg_tile_y_base),
                .cfg_tile_rows(cfg_tile_rows), .mac_ready(mac_ready_bus[lane]),
                .tile_done(done_bus[lane]), .protocol_error(error_bus[lane]),
                .cfg_width(cfg_width), .is_first_cin(commit_first_reg), .is_last_cin(commit_last_reg),
                .mac_data(results_reg[lane*20 +: 20]), .mac_valid(commit_reg),
                .mac_x(commit_x_reg), .mac_y(commit_y_reg),
                .final_sum(out_sum_bus[lane*ACC_WIDTH +: ACC_WIDTH]),
                .final_valid(out_valid_bus[lane]),
                .final_x(out_x_bus[lane*8 +: 8]), .final_y(out_y_bus[lane*8 +: 8])
            );
        end
    endgenerate
endmodule
`resetall
