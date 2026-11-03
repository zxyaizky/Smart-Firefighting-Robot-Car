// -----------------------------------------------------------------------------
// File   : npu_top_with_sdram_dma.v
// Author : OpenAI Codex (integration changes)
// Date   : 2026-09-07
// -----------------------------------------------------------------------------
// Description:
//   Expose drained tile/layer completion and sticky NPU errors to the board.
// Change Log:
//   2026-09-07  Codex  v2.0  Integrate and simulate two-row partial-sum tiling.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

// ----------------------------------------------------------------------------
// npu_top_with_sdram_dma
// ----------------------------------------------------------------------------
// Board-facing NPU wrapper for the Step 20.0 SDRAM parameter path.
// The external LBP/result/debug interface is intentionally aligned with
// npu_top_with_dma; only the SDRAM parameter-read master is added.
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

module npu_top_with_sdram_dma #(
    parameter integer INPUT_FRAME_BYTES = 3 * 160 * 120,
    parameter [23:0] PARAM_BASE_16 = 24'hc0_0000,
    // Keep legacy ROM behavior as the default for existing unit tests.  The
    // production C-board enables the descriptor RAM and selects it at runtime
    // only after a validated network configuration has been committed.
    parameter USE_DESC_RAM = 1'b0,
    // C-board FaceNet microcode only pools 3x3+padding layers.  Their right
    // edges are emitted per row, so the bounded tagged-row implementation is
    // safe and avoids the legacy 19200x128 full-frame allocation.
    parameter POOL_REORDER_IMPL = 2,
    // v2 default; legal range 17..21 parameter-word address bits.
    parameter integer PING_BANK_DEPTH = 3600,
    parameter integer PONG_BANK_DEPTH = 5120,
    parameter integer PONG_LARGE_BANKS = 16,
    parameter integer PONG_SMALL_BANK_DEPTH = PONG_BANK_DEPTH,
    parameter integer PARAM_ADDR_W = 17
)(
    input  wire         clk,
    input  wire         rst_n,
    output wire         o_tile_ready,
    output wire         o_tile_done,
    output wire         o_tile_error,
    output wire         o_layer_done,

    // Historical byte interface: RGB CHW, 57600 bytes per frame by default.
    output wire         o_input_busy,
    input  wire         i_frame_valid,
    input  wire         i_lbp_valid,
    input  wire [7:0]   i_lbp_pixel,

    input  wire         i_desc_we,
    input  wire [4:0]   i_desc_layer,
    input  wire [2:0]   i_desc_word,
    input  wire [31:0]  i_desc_wdata,
    input  wire [5:0]   i_layer_count,
    input  wire         i_desc_mode,

    output wire         o_result_stream_valid,
    output wire [127:0] o_result_stream_data,
    output wire         o_inference_done,
    output wire         o_bbox_valid,
    output wire [39:0]  o_bbox_data,

    output wire         o_dma_req_snoop,
    output wire         o_dma_done_snoop,
    output wire [PARAM_ADDR_W-1:0] o_dma_base_addr_snoop,
    output wire [15:0]  o_dma_length_snoop,

    // Step 20.0 §7.1 NPU read-master interface (clk domain).
    output wire         o_sdram_rd_req_valid,
    input  wire         i_sdram_rd_req_ready,
    output wire [23:0]  o_sdram_rd_addr,
    output wire [15:0]  o_sdram_rd_len_halfwords,
    input  wire [15:0]  i_sdram_rd_data,
    input  wire         i_sdram_rd_valid,

    // Compact, clk-domain UART diagnostics for board bring-up.
    output wire [31:0]  o_dbg_ctrl_status,
    output wire [31:0]  o_dbg_event_counts0,
    output wire [31:0]  o_dbg_event_counts1,
    output wire [31:0]  o_dbg_packer_status,
    output wire [31:0]  o_dbg_dma_status,
    output wire [31:0]  o_dbg_stage_input_count,
    output wire [31:0]  o_dbg_stage_lb_count,
    output wire [31:0]  o_dbg_stage_pe_count,
    output wire [31:0]  o_dbg_stage_bias_count,
    output wire [31:0]  o_dbg_stage_quant_count,
    output wire [31:0]  o_dbg_stage_output_count,
    output wire [31:0]  o_dbg_start_cfg,
    output wire [31:0]  o_dbg_bcu0,
    output wire [31:0]  o_dbg_bcu1,
    output wire [31:0]  o_dbg_bcu2,
    output wire [31:0]  o_dbg_bcu3,
    output wire [31:0]  o_dbg_bcu4,
    output wire [31:0]  o_dbg_bcu5,

    // Latency profiling counters, all in NPU clocks.  Left unconnected at
    // npu_network_top level for now; a board build can route them to OSD or a
    // debug register readout without touching the compute paths.
    //   cycles -> ms at current 100 MHz: ms = cycles / 100000
    // Latency profiling readout.  i_dbg_perf_sel walks the statistic table
    // documented in npu_perf_profiler.v; o_dbg_perf_data returns the selected
    // 32-bit value. All values are NPU-clock cycle counts; at 100 MHz,
    // ms = cycles / 100000.
    input  wire [5:0]   i_dbg_perf_sel,
    output wire [31:0]  o_dbg_perf_data,
    output wire [31:0]  o_dbg_perf_total_cycles,
    output wire [31:0]  o_dbg_perf_compute_cycles,
    output wire [31:0]  o_dbg_perf_reducer_cycles,
    output wire [4:0]   o_dbg_perf_layer_count,
    output wire         o_dbg_perf_active,

    // NUM4 low-intrusion numerical checkpoint mux.  Selector layout:
    //   0 marker; 1..5 PING preload; 6..37 layer counts;
    //   38..69 layer XOR folds; 70..101 layer byte sums;
    //   102..110 NUM5 C1-write/C2-input ordered signatures.
    input  wire [6:0]   i_num4_sel,
    output reg  [31:0]  o_num4_data
);

    generate
        if ((PARAM_ADDR_W < 17) || (PARAM_ADDR_W > 21)) begin : g_invalid_param_addr_w
            initial begin
                $error("npu_top_with_sdram_dma PARAM_ADDR_W must be within 17..21");
                $finish;
            end
        end
    endgenerate

    wire         w_dma_req;
    wire [PARAM_ADDR_W-1:0] w_dma_base_addr;
    wire [PARAM_ADDR_W-1:0] w_bias_base_addr;
    wire [15:0]  w_dma_length;
    wire         w_dma_ack;
    wire         w_dma_done;
    wire [1:0]   w_kernel_size;

    wire [143:0] w_weight_in_data;
    wire         w_weight_in_valid;
    wire [9:0]   w_weight_in_addr;
    wire         w_update_weights_en;
    wire [31:0]  w_bias_in_data;
    wire         w_bias_in_valid;
    wire [4:0]   w_bias_in_addr;
    wire         w_update_bias_en;
    wire         w_pool_reorder_error;
    wire         w_preload_wr_en;
    wire [12:0]  w_preload_wr_addr;
    wire [15:0]  w_preload_wr_mask;
    wire [127:0] w_preload_wr_data;
    wire         w_preload_done;
    wire [15:0]  w_packer_pixel_count;
    wire         w_packer_loading;
    wire         w_packer_final_write_pending;
    reg          r_inference_busy;

    wire [4:0]   w_core_layer_id;
    wire [3:0]   w_core_oc_group_idx;
    wire [5:0]   w_core_cin_group_idx;
    wire         w_core_layer_start;
    wire         w_core_layer_done;
    wire         w_core_pipeline_idle;
    wire         w_core_npu_in_valid;
    wire         w_core_npu_in_ready;
    wire [7:0]   w_core_npu_pixel_in;
    wire         w_core_npu_out_valid;
    wire [127:0] w_core_npu_out_bus;
    wire [12:0]  w_core_npu_write_addr;
    wire [7:0]   w_core_stage_valid_flags;
    wire [31:0]  w_core_start_cfg;
    wire [31:0]  w_core_bcu0;
    wire [31:0]  w_core_bcu1;
    wire [31:0]  w_core_bcu2;
    wire [31:0]  w_core_bcu3;
    wire [31:0]  w_core_bcu4;
    wire [31:0]  w_core_bcu5;

    wire [3:0]   w_dma_dbg_state;
    wire [15:0]  w_dma_dbg_words_left;
    wire [4:0]   w_dma_dbg_bias_count;

    // Sticky milestones and saturating counters form a low-intrusion flight
    // recorder.  A completed input preload starts a fresh diagnostic epoch so
    // stale events from an earlier frame cannot hide where the current frame
    // stopped.
    reg          r_preload_done_seen;
    reg          r_dma_req_seen;
    reg          r_dma_ack_seen;
    reg          r_dma_done_seen;
    reg          r_layer_start_seen;
    reg          r_layer_done_seen;
    reg          r_npu_in_seen;
    reg          r_npu_out_seen;
    reg          r_result_seen;
    reg          r_inference_done_seen;
    reg          r_bbox_seen;
    reg          r_dma_req_d;
    reg [7:0]    r_preload_done_count;
    reg [7:0]    r_dma_req_count;
    reg [7:0]    r_dma_ack_count;
    reg [7:0]    r_dma_done_count;
    reg [7:0]    r_layer_start_count;
    reg [7:0]    r_layer_done_count;
    reg [7:0]    r_result_count;
    reg [7:0]    r_inference_done_count;
    reg [15:0]   r_preload_pixel_count;
    reg [31:0]   r_stage_input_count;
    reg [31:0]   r_stage_lb_count;
    reg [31:0]   r_stage_pe_count;
    reg [31:0]   r_stage_bias_count;
    reg [31:0]   r_stage_quant_count;
    reg [31:0]   r_stage_output_count;

    // NUM4 records the two boundaries that NUM1 cannot see: the packed words
    // actually presented to PING, and the 128-bit feature words emitted by
    // each layer.  XOR is intentionally order-independent so the live board
    // can be compared with a Python CHW tensor without reproducing RTL emit
    // ordering; byte sum and count reduce the chance of an accidental alias.
    reg          r_num4_frame_d;
    reg [31:0]   r_num4_preload_count;
    reg [31:0]   r_num4_preload_xor;
    reg [31:0]   r_num4_preload_sum;
    reg [31:0]   r_num4_preload_first;
    reg [31:0]   r_num4_preload_last;
    reg [31:0]   r_num4_layer_count [0:31];
    reg [31:0]   r_num4_layer_xor   [0:31];
    reg [31:0]   r_num4_layer_sum   [0:31];

    // NUM5 is deliberately focused on the first failing boundary.  Its
    // order-sensitive hashes distinguish a bad C1 address sequence from a
    // bad PONG read sequence without placing probes in the compute datapath.
    reg [31:0]   r_num5_c2_input_count;
    reg [31:0]   r_num5_c2_input_hash;
    reg [31:0]   r_num5_c2_input_sum;
    reg [7:0]    r_num5_c2_input_first;
    reg [7:0]    r_num5_c2_input_last;
    reg [31:0]   r_num5_c1_write_count;
    reg [31:0]   r_num5_c1_write_hash;
    reg [12:0]   r_num5_c1_write_first_addr;
    reg [12:0]   r_num5_c1_write_last_addr;
    reg [12:0]   r_num5_c1_write_prev_addr;
    reg [31:0]   r_num5_c1_write_nonseq;
    integer      num4_i;
    // Keep the diagnostic sum as a balanced four-level tree.  A procedural
    // 16-byte accumulator can become a long adder chain and perturb the very
    // datapath this low-intrusion checkpoint is intended to observe.
    function [11:0] num4_byte_sum128;
        input [127:0] data;
        reg [8:0]  s0, s1, s2, s3, s4, s5, s6, s7;
        reg [9:0]  s8, s9, s10, s11;
        reg [10:0] s12, s13;
        begin
            s0  = {1'b0, data[7:0]}     + {1'b0, data[15:8]};
            s1  = {1'b0, data[23:16]}   + {1'b0, data[31:24]};
            s2  = {1'b0, data[39:32]}   + {1'b0, data[47:40]};
            s3  = {1'b0, data[55:48]}   + {1'b0, data[63:56]};
            s4  = {1'b0, data[71:64]}   + {1'b0, data[79:72]};
            s5  = {1'b0, data[87:80]}   + {1'b0, data[95:88]};
            s6  = {1'b0, data[103:96]}  + {1'b0, data[111:104]};
            s7  = {1'b0, data[119:112]} + {1'b0, data[127:120]};
            s8  = {1'b0, s0} + {1'b0, s1};
            s9  = {1'b0, s2} + {1'b0, s3};
            s10 = {1'b0, s4} + {1'b0, s5};
            s11 = {1'b0, s6} + {1'b0, s7};
            s12 = {1'b0, s8} + {1'b0, s9};
            s13 = {1'b0, s10} + {1'b0, s11};
            num4_byte_sum128 = {1'b0, s12} + {1'b0, s13};
        end
    endfunction

    wire [31:0]  w_num4_preload_sum =
        {20'd0, num4_byte_sum128(w_preload_wr_data)};
    wire [31:0]  w_num4_layer_sum =
        {20'd0, num4_byte_sum128(w_core_npu_out_bus)};
    wire [31:0]  w_num4_preload_fold =
        w_preload_wr_data[31:0] ^ w_preload_wr_data[63:32] ^
        w_preload_wr_data[95:64] ^ w_preload_wr_data[127:96];
    wire [31:0]  w_num4_layer_fold =
        w_core_npu_out_bus[31:0] ^ w_core_npu_out_bus[63:32] ^
        w_core_npu_out_bus[95:64] ^ w_core_npu_out_bus[127:96];

    always @(*) begin
        if (i_num4_sel == 6'd0)
            o_num4_data = 32'h4e554d34; // "NUM4"
        else if (i_num4_sel == 6'd1)
            o_num4_data = r_num4_preload_count;
        else if (i_num4_sel == 6'd2)
            o_num4_data = r_num4_preload_xor;
        else if (i_num4_sel == 6'd3)
            o_num4_data = r_num4_preload_sum;
        else if (i_num4_sel == 6'd4)
            o_num4_data = r_num4_preload_first;
        else if (i_num4_sel == 6'd5)
            o_num4_data = r_num4_preload_last;
        else if ((i_num4_sel >= 6'd6) && (i_num4_sel <= 7'd37))
            o_num4_data = r_num4_layer_count[i_num4_sel - 6'd6];
        else if ((i_num4_sel >= 7'd38) && (i_num4_sel <= 7'd69))
            o_num4_data = r_num4_layer_xor[i_num4_sel - 7'd38];
        else if ((i_num4_sel >= 7'd70) && (i_num4_sel <= 7'd101))
            o_num4_data = r_num4_layer_sum[i_num4_sel - 7'd70];
        else if (i_num4_sel == 7'd102)
            o_num4_data = 32'h4e554d35; // "NUM5"
        else if (i_num4_sel == 7'd103)
            o_num4_data = r_num5_c2_input_count;
        else if (i_num4_sel == 7'd104)
            o_num4_data = r_num5_c2_input_hash;
        else if (i_num4_sel == 7'd105)
            o_num4_data = r_num5_c2_input_sum;
        else if (i_num4_sel == 7'd106)
            o_num4_data = {16'd0, r_num5_c2_input_first,
                           r_num5_c2_input_last};
        else if (i_num4_sel == 7'd107)
            o_num4_data = r_num5_c1_write_count;
        else if (i_num4_sel == 7'd108)
            o_num4_data = r_num5_c1_write_hash;
        else if (i_num4_sel == 7'd109)
            o_num4_data = {3'd0, r_num5_c1_write_first_addr,
                           3'd0, r_num5_c1_write_last_addr};
        else if (i_num4_sel == 7'd110)
            o_num4_data = r_num5_c1_write_nonseq;
        else
            o_num4_data = 32'hdead4000 | {25'd0, i_num4_sel};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_num4_frame_d       <= 1'b0;
            r_num4_preload_count <= 32'd0;
            r_num4_preload_xor   <= 32'd0;
            r_num4_preload_sum   <= 32'd0;
            r_num4_preload_first <= 32'd0;
            r_num4_preload_last  <= 32'd0;
            r_num5_c2_input_count <= 32'd0;
            r_num5_c2_input_hash  <= 32'hc2015eed;
            r_num5_c2_input_sum   <= 32'd0;
            r_num5_c2_input_first <= 8'd0;
            r_num5_c2_input_last  <= 8'd0;
            r_num5_c1_write_count <= 32'd0;
            r_num5_c1_write_hash  <= 32'h51a7c3e9;
            r_num5_c1_write_first_addr <= 13'd0;
            r_num5_c1_write_last_addr  <= 13'd0;
            r_num5_c1_write_prev_addr  <= 13'd0;
            r_num5_c1_write_nonseq <= 32'd0;
            for (num4_i = 0; num4_i < 32; num4_i = num4_i + 1) begin
                r_num4_layer_count[num4_i] <= 32'd0;
                r_num4_layer_xor[num4_i]   <= 32'd0;
                r_num4_layer_sum[num4_i]   <= 32'd0;
            end
        end else begin
            r_num4_frame_d <= i_frame_valid;
            if (i_frame_valid && !r_num4_frame_d) begin
                r_num4_preload_count <= 32'd0;
                r_num4_preload_xor   <= 32'd0;
                r_num4_preload_sum   <= 32'd0;
                r_num4_preload_first <= 32'd0;
                r_num4_preload_last  <= 32'd0;
                r_num5_c2_input_count <= 32'd0;
                r_num5_c2_input_hash  <= 32'hc2015eed;
                r_num5_c2_input_sum   <= 32'd0;
                r_num5_c2_input_first <= 8'd0;
                r_num5_c2_input_last  <= 8'd0;
                r_num5_c1_write_count <= 32'd0;
                r_num5_c1_write_hash  <= 32'h51a7c3e9;
                r_num5_c1_write_first_addr <= 13'd0;
                r_num5_c1_write_last_addr  <= 13'd0;
                r_num5_c1_write_prev_addr  <= 13'd0;
                r_num5_c1_write_nonseq <= 32'd0;
                for (num4_i = 0; num4_i < 32; num4_i = num4_i + 1) begin
                    r_num4_layer_count[num4_i] <= 32'd0;
                    r_num4_layer_xor[num4_i]   <= 32'd0;
                    r_num4_layer_sum[num4_i]   <= 32'd0;
                end
            end else begin
                if (w_preload_wr_en) begin
                    r_num4_preload_count <= r_num4_preload_count + 32'd1;
                    r_num4_preload_xor   <= r_num4_preload_xor ^
                                            w_num4_preload_fold;
                    r_num4_preload_sum   <= r_num4_preload_sum +
                                            w_num4_preload_sum;
                    if (r_num4_preload_count == 32'd0)
                        r_num4_preload_first <= w_num4_preload_fold;
                    r_num4_preload_last <= w_num4_preload_fold;
                end
                if (w_core_npu_out_valid) begin
                    r_num4_layer_count[w_core_layer_id] <=
                        r_num4_layer_count[w_core_layer_id] + 32'd1;
                    r_num4_layer_xor[w_core_layer_id] <=
                        r_num4_layer_xor[w_core_layer_id] ^ w_num4_layer_fold;
                    r_num4_layer_sum[w_core_layer_id] <=
                        r_num4_layer_sum[w_core_layer_id] + w_num4_layer_sum;
                end
                if (w_core_npu_in_valid && (w_core_layer_id == 5'd1)) begin
                    r_num5_c2_input_count <= r_num5_c2_input_count + 32'd1;
                    r_num5_c2_input_hash <=
                        {r_num5_c2_input_hash[26:0], r_num5_c2_input_hash[31:27]} ^
                        {24'd0, w_core_npu_pixel_in} ^ r_num5_c2_input_count;
                    r_num5_c2_input_sum <= r_num5_c2_input_sum +
                                          {24'd0, w_core_npu_pixel_in};
                    if (r_num5_c2_input_count == 32'd0)
                        r_num5_c2_input_first <= w_core_npu_pixel_in;
                    r_num5_c2_input_last <= w_core_npu_pixel_in;
                end
                if (w_core_npu_out_valid && (w_core_layer_id == 5'd0)) begin
                    r_num5_c1_write_count <= r_num5_c1_write_count + 32'd1;
                    r_num5_c1_write_hash <=
                        {r_num5_c1_write_hash[26:0], r_num5_c1_write_hash[31:27]} ^
                        w_num4_layer_fold ^ {19'd0, w_core_npu_write_addr} ^
                        r_num5_c1_write_count;
                    if (r_num5_c1_write_count == 32'd0)
                        r_num5_c1_write_first_addr <= w_core_npu_write_addr;
                    else if (w_core_npu_write_addr !=
                             (r_num5_c1_write_prev_addr + 13'd1))
                        r_num5_c1_write_nonseq <= r_num5_c1_write_nonseq + 32'd1;
                    r_num5_c1_write_last_addr <= w_core_npu_write_addr;
                    r_num5_c1_write_prev_addr <= w_core_npu_write_addr;
                end
            end
        end
    end

    // Progress is derived from event-count imbalance, not merely the latest
    // sticky bit.  This remains meaningful when a later layer stalls after
    // one or more earlier layers have already completed.
    wire [2:0] w_dbg_phase = r_inference_done_seen ? 3'd6 :
        ((r_layer_start_count > r_layer_done_count) ? 3'd4 :
         (r_dma_req_count > r_dma_done_count)       ? 3'd2 :
         (r_dma_done_count > r_layer_start_count)   ? 3'd3 :
         r_layer_done_seen                          ? 3'd5 :
         r_dma_req_seen                             ? 3'd2 :
         r_preload_done_seen                        ? 3'd1 : 3'd0);

    assign o_dma_req_snoop       = w_dma_req;
    assign o_dma_done_snoop      = w_dma_done;
    assign o_dma_base_addr_snoop = w_dma_base_addr;
    assign o_dma_length_snoop    = w_dma_length;

    // REG45-style control snapshot.  The group indices and layer ID are live;
    // milestone bits are sticky for the current frame.
    assign o_dbg_ctrl_status = {
        r_bbox_seen, r_result_seen, r_inference_done_seen, r_npu_out_seen,
        r_npu_in_seen, r_layer_done_seen, r_layer_start_seen, r_dma_done_seen,
        r_dma_ack_seen, r_dma_req_seen, r_preload_done_seen,
        o_tile_error, w_core_pipeline_idle, r_inference_busy,
        w_core_cin_group_idx, w_core_oc_group_idx, w_core_layer_id, w_dbg_phase
    };
    assign o_dbg_event_counts0 = {r_preload_done_count, r_dma_req_count,
                                  r_dma_ack_count, r_dma_done_count};
    assign o_dbg_event_counts1 = {r_layer_start_count, r_layer_done_count,
                                  r_result_count, r_inference_done_count};
    assign o_dbg_packer_status = {7'h52, r_preload_done_count,
                                  w_packer_final_write_pending,
                                  r_preload_pixel_count};
    assign o_dbg_dma_status = {
        w_dma_dbg_state, w_dma_dbg_words_left, w_dma_dbg_bias_count,
        w_dma_req, w_dma_ack, w_dma_done, w_core_npu_in_valid,
        w_core_npu_in_ready, o_sdram_rd_req_valid, i_sdram_rd_valid
    };
    assign o_dbg_stage_input_count  = r_stage_input_count;
    assign o_dbg_stage_lb_count     = r_stage_lb_count;
    assign o_dbg_stage_pe_count     = r_stage_pe_count;
    assign o_dbg_stage_bias_count   = r_stage_bias_count;
    assign o_dbg_stage_quant_count  = r_stage_quant_count;
    assign o_dbg_stage_output_count = r_stage_output_count;
    assign o_dbg_start_cfg          = w_core_start_cfg;
    assign o_dbg_bcu0               = w_core_bcu0;
    assign o_dbg_bcu1               = w_core_bcu1;
    assign o_dbg_bcu2               = w_core_bcu2;
    assign o_dbg_bcu3               = w_core_bcu3;
    assign o_dbg_bcu4               = w_core_bcu4;
    assign o_dbg_bcu5               = w_core_bcu5;

    // Busy covers accepted loading, final write commit, and the entire inference.
    // A partial input frame aborts loading on frame-valid low; completed PING is
    // released only by inference_done (errors remain busy until shared reset).
    assign o_input_busy = r_inference_busy || w_packer_loading;

    // -------------------------------------------------------------------------
    // Latency profiling.  Milestones are tapped from existing signals only; no
    // compute path is modified.
    //   input_start = frame admitted here (rising edge of i_frame_valid)
    //   input_done  = PING preload committed
    //   npu_start   = first layer_start of this inference (layer-0 compute)
    //   npu_done    = inference_done (winner valid)
    // -------------------------------------------------------------------------
    reg r_perf_frame_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_perf_frame_d <= 1'b0;
        else        r_perf_frame_d <= i_frame_valid;
    end
    wire w_perf_input_start = i_frame_valid && !r_perf_frame_d;

    npu_perf_profiler u_perf_profiler (
        .clk                 (clk),
        .rst_n               (rst_n),
        .i_input_start       (w_perf_input_start),
        .i_input_done        (w_preload_done),
        .i_layer_start       (w_core_layer_start),
        // o_layer_done is the sequencer's TRUE per-layer completion
        // (w_complete_layer).  w_core_layer_done is the BCU per-iteration
        // handshake and fires hundreds of times per frame, so it must NOT be
        // used as a layer boundary.
        .i_layer_done        (o_layer_done),
        .i_npu_done          (o_inference_done),
        // Weight DMA FSM is idle only in ST_IDLE (4'd0).
        .i_dma_active        (w_dma_dbg_state != 4'd0),
        .i_param_req         (w_dma_req),
        .i_param_rd_valid    (i_sdram_rd_valid),
        .i_busy              (o_input_busy),
        .i_stat_sel          (i_dbg_perf_sel),
        .o_stat_data         (o_dbg_perf_data),
        .o_input_cycles      (),
        .o_wait_cycles       (),
        .o_compute_cycles    (o_dbg_perf_compute_cycles),
        .o_reducer_cycles    (o_dbg_perf_reducer_cycles),
        .o_total_cycles      (o_dbg_perf_total_cycles),
        .o_layer_count       (o_dbg_perf_layer_count),
        .o_param_request_count (),
        .o_param_wait_cycles   (),
        .o_param_valid_cycles  (),
        .o_dma_active_cycles   (),
        .o_busy_cycles         (),
        .o_inference_active  (o_dbg_perf_active)
    );

`ifdef MODEL_TECH
`ifdef NPU_STREAM_INPUT_SIM
    localparam STREAMED_RGB_INPUT = 1;
`else
    localparam STREAMED_RGB_INPUT = 0;
`endif
`else
    localparam STREAMED_RGB_INPUT = 1;
`endif
    lbp_to_ping_packer #(
        .FRAME_PIXELS(INPUT_FRAME_BYTES),
        .STREAMED_RGB(STREAMED_RGB_INPUT)
    ) u_lbp_to_ping_packer (
        .clk                (clk),
        .rst_n              (rst_n),
        .i_enable           (!(r_inference_busy || w_preload_done ||
                               w_packer_final_write_pending)),
        .i_frame_valid      (i_frame_valid),
        .i_lbp_valid        (i_lbp_valid),
        .i_lbp_pixel        (i_lbp_pixel),
        .o_preload_wr_en    (w_preload_wr_en),
        .o_preload_wr_addr  (w_preload_wr_addr),
        .o_preload_wr_mask  (w_preload_wr_mask),
        .o_preload_wr_data  (w_preload_wr_data),
        .o_preload_done     (w_preload_done),
        .o_dbg_pixel_count  (w_packer_pixel_count),
        .o_loading          (w_packer_loading),
        .o_dbg_final_write_pending(w_packer_final_write_pending)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            r_inference_busy <= 1'b0;
        else begin
            if (w_preload_done)
                r_inference_busy <= 1'b1;
            else if (o_inference_done)
                r_inference_busy <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_preload_done_seen    <= 1'b0;
            r_dma_req_seen         <= 1'b0;
            r_dma_ack_seen         <= 1'b0;
            r_dma_done_seen        <= 1'b0;
            r_layer_start_seen     <= 1'b0;
            r_layer_done_seen      <= 1'b0;
            r_npu_in_seen          <= 1'b0;
            r_npu_out_seen         <= 1'b0;
            r_result_seen          <= 1'b0;
            r_inference_done_seen  <= 1'b0;
            r_bbox_seen            <= 1'b0;
            r_dma_req_d            <= 1'b0;
            r_preload_done_count   <= 8'd0;
            r_dma_req_count        <= 8'd0;
            r_dma_ack_count        <= 8'd0;
            r_dma_done_count       <= 8'd0;
            r_layer_start_count    <= 8'd0;
            r_layer_done_count     <= 8'd0;
            r_result_count         <= 8'd0;
            r_inference_done_count <= 8'd0;
            r_preload_pixel_count  <= 16'd0;
            r_stage_input_count    <= 32'd0;
            r_stage_lb_count       <= 32'd0;
            r_stage_pe_count       <= 32'd0;
            r_stage_bias_count     <= 32'd0;
            r_stage_quant_count    <= 32'd0;
            r_stage_output_count   <= 32'd0;
        end else begin
            r_dma_req_d <= w_dma_req;

            if (w_preload_done) begin
                r_preload_done_seen    <= 1'b1;
                r_dma_req_seen         <= 1'b0;
                r_dma_ack_seen         <= 1'b0;
                r_dma_done_seen        <= 1'b0;
                r_layer_start_seen     <= 1'b0;
                r_layer_done_seen      <= 1'b0;
                r_npu_in_seen          <= 1'b0;
                r_npu_out_seen         <= 1'b0;
                r_result_seen          <= 1'b0;
                r_inference_done_seen  <= 1'b0;
                r_bbox_seen            <= 1'b0;
                r_preload_done_count   <= 8'd1;
                r_dma_req_count        <= 8'd0;
                r_dma_ack_count        <= 8'd0;
                r_dma_done_count       <= 8'd0;
                r_layer_start_count    <= 8'd0;
                r_layer_done_count     <= 8'd0;
                r_result_count         <= 8'd0;
                r_inference_done_count <= 8'd0;
                r_preload_pixel_count  <= w_packer_pixel_count;
                r_stage_input_count    <= 32'd0;
                r_stage_lb_count       <= 32'd0;
                r_stage_pe_count       <= 32'd0;
                r_stage_bias_count     <= 32'd0;
                r_stage_quant_count    <= 32'd0;
                r_stage_output_count   <= 32'd0;
            end else begin
                if (w_dma_req && !r_dma_req_d) begin
                    r_dma_req_seen <= 1'b1;
                    if (r_dma_req_count != 8'hff)
                        r_dma_req_count <= r_dma_req_count + 1'b1;
                end
                if (w_dma_ack) begin
                    r_dma_ack_seen <= 1'b1;
                    if (r_dma_ack_count != 8'hff)
                        r_dma_ack_count <= r_dma_ack_count + 1'b1;
                end
                if (w_dma_done) begin
                    r_dma_done_seen <= 1'b1;
                    if (r_dma_done_count != 8'hff)
                        r_dma_done_count <= r_dma_done_count + 1'b1;
                end
                if (w_core_layer_start) begin
                    r_layer_start_seen <= 1'b1;
                    if (r_layer_start_count != 8'hff)
                        r_layer_start_count <= r_layer_start_count + 1'b1;
                end
                if (w_core_layer_done) begin
                    r_layer_done_seen <= 1'b1;
                    if (r_layer_done_count != 8'hff)
                        r_layer_done_count <= r_layer_done_count + 1'b1;
                end
                if (w_core_npu_in_valid)
                    r_npu_in_seen <= 1'b1;
                if (w_core_npu_out_valid)
                    r_npu_out_seen <= 1'b1;
                if (o_result_stream_valid) begin
                    r_result_seen <= 1'b1;
                    if (r_result_count != 8'hff)
                        r_result_count <= r_result_count + 1'b1;
                end
                if (o_inference_done) begin
                    r_inference_done_seen <= 1'b1;
                    if (r_inference_done_count != 8'hff)
                        r_inference_done_count <= r_inference_done_count + 1'b1;
                end
                if (o_bbox_valid)
                    r_bbox_seen <= 1'b1;

                if (w_core_npu_in_valid && r_stage_input_count != 32'hffffffff)
                    r_stage_input_count <= r_stage_input_count + 1'b1;
                if (w_core_stage_valid_flags[2] && r_stage_lb_count != 32'hffffffff)
                    r_stage_lb_count <= r_stage_lb_count + 1'b1;
                if (w_core_stage_valid_flags[3] && r_stage_pe_count != 32'hffffffff)
                    r_stage_pe_count <= r_stage_pe_count + 1'b1;
                if (w_core_stage_valid_flags[4] && r_stage_bias_count != 32'hffffffff)
                    r_stage_bias_count <= r_stage_bias_count + 1'b1;
                if (w_core_stage_valid_flags[5] && r_stage_quant_count != 32'hffffffff)
                    r_stage_quant_count <= r_stage_quant_count + 1'b1;
                if (w_core_npu_out_valid && r_stage_output_count != 32'hffffffff)
                    r_stage_output_count <= r_stage_output_count + 1'b1;
            end
        end
    end

    npu_core_top #(
        .POOL_REORDER_IMPL(POOL_REORDER_IMPL),
        .USE_DESC_RAM    (USE_DESC_RAM),
        .PING_BANK_DEPTH(PING_BANK_DEPTH),
        .PONG_BANK_DEPTH(PONG_BANK_DEPTH),
        .PONG_LARGE_BANKS(PONG_LARGE_BANKS),
        .PONG_SMALL_BANK_DEPTH(PONG_SMALL_BANK_DEPTH),
        .PARAM_ADDR_W    (PARAM_ADDR_W)
    ) u_core (
        .clk               (clk),
        .o_tile_ready(o_tile_ready),
        .o_tile_done(o_tile_done),
        .o_tile_error(o_tile_error),
        .o_layer_done(o_layer_done),
        .rst_n             (rst_n),
        .i_frame_valid     (w_preload_done),
        .i_lbp_valid       (1'b0),
        .i_lbp_pixel       (8'd0),
        .i_l0_input_preload_en(1'b1),
        .i_l0_input_packed_en (1'b1),
        .i_preload_wr_en      (w_preload_wr_en),
        .i_preload_target     (1'b0),
        .i_preload_wr_addr    (w_preload_wr_addr),
        .i_preload_wr_mask    (w_preload_wr_mask),
        .i_preload_wr_data    (w_preload_wr_data),
        .i_skip_lbp_load      (1'b1),

        .i_desc_we         (i_desc_we),
        .i_desc_layer      (i_desc_layer),
        .i_desc_word       (i_desc_word),
        .i_desc_wdata      (i_desc_wdata),
        .i_layer_count     (i_layer_count),
        .i_desc_mode       (i_desc_mode),

        .o_dma_req         (w_dma_req),
        .o_dma_base_addr   (w_dma_base_addr),
        .o_bias_base_addr  (w_bias_base_addr),
        .o_dma_length      (w_dma_length),
        .i_dma_ack         (w_dma_ack),
        .i_dma_done        (w_dma_done),

        .weight_in_data    (w_weight_in_data),
        .weight_in_valid   (w_weight_in_valid),
        .weight_in_addr    (w_weight_in_addr),
        .update_weights_en (w_update_weights_en),
        .bias_in_data      (w_bias_in_data),
        .bias_in_valid     (w_bias_in_valid),
        .bias_in_addr      (w_bias_in_addr),
        .update_bias_en    (w_update_bias_en),

        .i_pool_scratch_base_addr(32'd0),
        .o_pool_reorder_error(w_pool_reorder_error),
        .o_pool_reorder_dbg0(), .o_pool_reorder_dbg1(),
        .o_pool_reorder_dbg2(), .o_pool_reorder_dbg3(),
        .o_pool_reorder_dbg4(), .o_pool_reorder_dbg5(),
        .o_pool_reorder_dbg6(), .o_pool_reorder_dbg7(),
        .o_pool_reorder_dbg8(), .o_pool_reorder_dbg9(),
        .o_pool_reorder_dbg10(), .o_pool_reorder_dbg11(),
        .o_pool_reorder_dbg12(), .o_pool_reorder_dbg13(),
        .o_pool_reorder_dbg14(), .o_pool_reorder_dbg15(),
        .o_pool_reorder_dbg16(), .o_pool_reorder_dbg17(),
        .o_pool_reorder_dbg18(),
        .i_layer_dbg_sel(7'd0),
        .o_layer_dbg0(), .o_layer_dbg1(), .o_layer_dbg2(), .o_layer_dbg3(),
        .o_layer_dbg4(), .o_layer_dbg5(), .o_layer_dbg6(), .o_layer_dbg7(),
        .o_dbg_layer_id      (w_core_layer_id),
        .o_dbg_oc_group_idx  (w_core_oc_group_idx),
        .o_dbg_cin_group_idx (w_core_cin_group_idx),
        .o_dbg_layer_start   (w_core_layer_start),
        .o_dbg_layer_done    (w_core_layer_done),
        .o_dbg_pipeline_idle (w_core_pipeline_idle),
        .o_dbg_npu_in_valid  (w_core_npu_in_valid),
        .o_dbg_npu_in_ready  (w_core_npu_in_ready),
        .o_dbg_npu_pixel_in  (w_core_npu_pixel_in),
        .o_dbg_npu_out_valid (w_core_npu_out_valid),
        .o_dbg_npu_out_bus   (w_core_npu_out_bus),
        .o_dbg_npu_write_addr(w_core_npu_write_addr),
        .o_dbg_stage_valid_flags(w_core_stage_valid_flags),
        .o_dbg_start_cfg     (w_core_start_cfg),
        .o_dbg_bcu0          (w_core_bcu0),
        .o_dbg_bcu1          (w_core_bcu1),
        .o_dbg_bcu2          (w_core_bcu2),
        .o_dbg_bcu3          (w_core_bcu3),
        .o_dbg_bcu4          (w_core_bcu4),
        .o_dbg_bcu5          (w_core_bcu5),

        // Pool reorder AXI is disabled in this board wrapper, as in the ROM baseline.
        .m_axi_arid(), .m_axi_araddr(), .m_axi_arlen(), .m_axi_arsize(),
        .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(),
        .m_axi_arvalid(), .m_axi_arready(1'b0),
        .m_axi_rid(4'd0), .m_axi_rdata(32'd0), .m_axi_rresp(2'b00),
        .m_axi_rlast(1'b0), .m_axi_rvalid(1'b0), .m_axi_rready(),
        .m_axi_awid(), .m_axi_awaddr(), .m_axi_awlen(), .m_axi_awsize(),
        .m_axi_awburst(), .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(),
        .m_axi_awvalid(), .m_axi_awready(1'b0),
        .m_axi_wid(), .m_axi_wdata(), .m_axi_wstrb(), .m_axi_wlast(),
        .m_axi_wvalid(), .m_axi_wready(1'b0),
        .m_axi_bid(4'd0), .m_axi_bresp(2'b00), .m_axi_bvalid(1'b0),
        .m_axi_bready(),

        .o_kernel_size     (w_kernel_size),
        .o_result_stream_valid(o_result_stream_valid),
        .o_result_stream_data(o_result_stream_data),
        .o_inference_done  (o_inference_done),
        .o_bbox_valid      (o_bbox_valid),
        .o_bbox_data       (o_bbox_data)
    );

    weight_sdram_dma #(
        .PARAM_ADDR_W  (PARAM_ADDR_W),
        .PARAM_BASE_16 (PARAM_BASE_16)
    ) u_dma (
        .clk                  (clk),
        .rst_n                (rst_n),
        .i_dma_req            (w_dma_req),
        .i_dma_base_addr      (w_dma_base_addr),
        .i_bias_base_addr     (w_bias_base_addr),
        .i_dma_length         (w_dma_length),
        .i_kernel_size        (w_kernel_size),
        .o_dma_ack            (w_dma_ack),
        .o_dma_done           (w_dma_done),
        .o_weight_data        (w_weight_in_data),
        .o_weight_valid       (w_weight_in_valid),
        .o_weight_addr        (w_weight_in_addr),
        .o_update_weights_en  (w_update_weights_en),
        .o_bias_data          (w_bias_in_data),
        .o_bias_valid         (w_bias_in_valid),
        .o_bias_addr          (w_bias_in_addr),
        .o_update_bias_en     (w_update_bias_en),
        .o_sdram_rd_req_valid (o_sdram_rd_req_valid),
        .i_sdram_rd_req_ready (i_sdram_rd_req_ready),
        .o_sdram_rd_addr      (o_sdram_rd_addr),
        .o_sdram_rd_len_halfwords(o_sdram_rd_len_halfwords),
        .i_sdram_rd_data      (i_sdram_rd_data),
        .i_sdram_rd_valid     (i_sdram_rd_valid),
        .o_dbg_state          (w_dma_dbg_state),
        .o_dbg_words_left     (w_dma_dbg_words_left),
        .o_dbg_bias_count     (w_dma_dbg_bias_count)
    );

endmodule

`resetall
