// Change Log: 2026-10-02 Codex v2.0 Stereo stage 2 sync/source/bbox metadata.
// -----------------------------------------------------------------------------
// File   : npu_video_input.v
// Author : Codex
// Date   : 2026-09-11
// Description: Passive tap of the official video_out RGB port, before OSD.
// Change Log: 2026-09-11 v1.0 Align read enable with the two-cycle RGB pipeline.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

// 2026-10-03 v2.1 Optional synchronized-frame admission, without changing the sampler.
// 2026-10-03 v2.2 Standalone inference fallback when display sync tags disappear.
module npu_video_input #(
    parameter REQUIRE_METADATA = 0,
    parameter SYNC_ONLY = 0,
    // Zero preserves strict SYNC_ONLY. A enables 30 display-frame fallback.
    parameter SYNC_FALLBACK_FRAMES = 0
) (
    input  wire        clk_video,
    input  wire        clk_npu,
    input  wire        rst_n,
    input  wire        i_vsync,
    input  wire        i_video_rd_en,
    input  wire [23:0] i_video_rgb,
    input  wire        i_npu_busy,
    input  wire [32:0] i_frame_metadata,
    input  wire        i_frame_metadata_valid,
    output wire [32:0] o_frame_metadata,
    output wire        o_frame_valid,
    output wire        o_byte_valid,
    output wire [7:0]  o_byte,
    output wire        o_capture_busy
);
    // Preserve the existing shared active-low reset contract. Deassertion is
    // synchronized inside npu_rgb_input independently in both clock domains.
    reg [1:0] video_valid_reg;
    reg vsync_reg;
    wire frame_start;
    wire capture_start;
    reg armed_reg = 1'b0;
    localparam integer SYNC_GAP_WIDTH = SYNC_FALLBACK_FRAMES > 1 ?
        $clog2(SYNC_FALLBACK_FRAMES) : 1;
    localparam [SYNC_GAP_WIDTH-1:0] SYNC_GAP_LAST = SYNC_FALLBACK_FRAMES > 0 ?
        SYNC_FALLBACK_FRAMES - 1 : 0;
    reg sync_recent_reg = 1'b0, sync_recent_next;
    reg [SYNC_GAP_WIDTH-1:0] sync_gap_reg = {SYNC_GAP_WIDTH{1'b0}}, sync_gap_next;
    wire sync_gate;
    assign sync_gate = !SYNC_ONLY || i_frame_metadata[32] ||
        (SYNC_FALLBACK_FRAMES > 0 && !sync_recent_reg);
    // Observe actual displayed frame tags, not just incoming wire pulses. This
    // also recovers when tagged CSI pages never reach the display sampler.
    always @* begin
        sync_recent_next = sync_recent_reg;
        sync_gap_next = sync_gap_reg;
        if (SYNC_ONLY && SYNC_FALLBACK_FRAMES > 0) begin
            if (frame_start && sync_recent_reg) begin
                if (sync_gap_reg == SYNC_GAP_LAST) sync_recent_next = 1'b0;
                else sync_gap_next = sync_gap_reg + {{(SYNC_GAP_WIDTH-1){1'b0}}, 1'b1};
            end
            if (armed_reg && video_valid_reg[1] && i_frame_metadata_valid &&
                i_frame_metadata[32]) begin
                sync_recent_next = 1'b1;
                sync_gap_next = {SYNC_GAP_WIDTH{1'b0}};
            end
        end
    end
    always @(posedge clk_video) begin
        sync_recent_reg <= sync_recent_next;
        sync_gap_reg <= sync_gap_next;
        if (!rst_n) begin
            sync_recent_reg <= 1'b0;
            sync_gap_reg <= {SYNC_GAP_WIDTH{1'b0}};
        end
    end
    // SOF arms the raster. In tagged mode the first valid RGB starts capture,
    // after video_out has selected its DDR page and published stable metadata.
    assign capture_start = REQUIRE_METADATA ?
        (armed_reg && video_valid_reg[1] && i_frame_metadata_valid &&
         sync_gate) : frame_start;
    always @(posedge clk_video) begin
        if (frame_start) armed_reg <= 1'b1;
        else if (armed_reg && video_valid_reg[1]) armed_reg <= 1'b0;
        if (!rst_n) armed_reg <= 1'b0;
    end
    assign frame_start = i_vsync && !vsync_reg;

    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            video_valid_reg <= 2'b00;
            vsync_reg <= 1'b1;
        end else begin
            video_valid_reg <= {video_valid_reg[0], i_video_rd_en};
            vsync_reg <= i_vsync;
        end
    end

    // video_out registers the request, then registers O_vdieo_data. The delay
    // includes both stages; i_video_rgb is already delayed and is not delayed here.
    // Positive VS is in vertical blanking and arms the following active frame.
    npu_rgb_input npu_rgb_input_inst (
        .clk_video     (clk_video),
        .clk_npu       (clk_npu),
        .rst_n         (rst_n),
        .i_sof         (capture_start),
        .i_frame_metadata(i_frame_metadata),
        .o_frame_metadata(o_frame_metadata),
        .i_valid       (video_valid_reg[1]),
        .i_rgb         (i_video_rgb),
        .i_npu_busy    (i_npu_busy),
        .o_frame_valid (o_frame_valid),
        .o_byte_valid  (o_byte_valid),
        .o_byte        (o_byte),
        .o_capture_busy(o_capture_busy)
    );
endmodule
`resetall
