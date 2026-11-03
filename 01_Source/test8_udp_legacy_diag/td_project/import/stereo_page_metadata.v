// -----------------------------------------------------------------------------
// File   : stereo_page_metadata.v
// Author : Codex
// Date   : 2026-10-02
// Description: Four DDR-page tags, committed only after a complete video write.
// Change Log: 2026-10-02 v1.0 Stage 2 frame identity; no image storage added.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module stereo_page_metadata #
(
    // 1280 * 720 * 3 / 16 packed words in a complete RGB888 source frame.
    parameter FRAME_WORDS = 172800
)
(
    input  wire        clk_camera,
    input  wire        rst_camera,
    input  wire        clk_ddr,
    input  wire        rst_ddr,
    input  wire        camera_frame_start_i,
    input  wire [32:0] camera_metadata_i,
    input  wire        camera_overflow_i,
    input  wire        ddr_frame_invalid_i,
    input  wire        ddr_frame_start_i,
    input  wire [1:0]  write_page_i,
    input  wire [1:0]  read_page_i,
    input  wire        word_accept_i,
    output wire [33:0] read_metadata_o
);
    localparam integer COUNT_WIDTH = $clog2(FRAME_WORDS + 1);
    localparam [COUNT_WIDTH-1:0] LAST_WORD = FRAME_WORDS - 1;
    reg camera_bad_reg = 1'b0;
    (* async_reg = "true" *) reg [1:0] camera_bad_sync_reg = 2'b00;
    reg [32:0] camera_held_reg = 33'd0;
    reg [32:0] page_metadata_reg [3:0];
    reg [3:0] complete_reg = 4'b0000;
    reg [1:0] write_page_reg = 2'd0;
    reg [COUNT_WIDTH-1:0] count_reg = {COUNT_WIDTH{1'b0}};
    reg writing_reg = 1'b0;
    assign read_metadata_o = {complete_reg[read_page_i], page_metadata_reg[read_page_i]};
    // CDC: video_in's existing stretched SOF and 3-stage DDR synchronizer
    // qualify this held bus. It is captured at RAW tuser and held until the
    // next source frame, not sampled with independent per-bit synchronizers.
    always @(posedge clk_camera) begin
        if (camera_overflow_i) camera_bad_reg <= 1'b1;
        if (camera_frame_start_i) begin
            camera_held_reg <= camera_metadata_i;
            camera_bad_reg <= 1'b0;
        end
        if (rst_camera) begin
            camera_held_reg <= 33'd0;
            camera_bad_reg <= 1'b0;
        end
    end
    always @(posedge clk_ddr) begin
        camera_bad_sync_reg <= {camera_bad_sync_reg[0], camera_bad_reg};
        if (ddr_frame_start_i) begin
            page_metadata_reg[write_page_i] <= camera_held_reg;
            complete_reg[write_page_i] <= 1'b0;
            write_page_reg <= write_page_i;
            count_reg <= {COUNT_WIDTH{1'b0}};
            writing_reg <= !ddr_frame_invalid_i;
        end else if (word_accept_i && writing_reg) begin
            count_reg <= count_reg + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
            if (count_reg == LAST_WORD) begin
                complete_reg[write_page_reg] <= 1'b1;
                writing_reg <= 1'b0;
            end
        end
        // An overflowing camera FIFO or a burst crossing source SOF cannot
        // produce a trusted page. This only invalidates metadata, not video.
        if (camera_bad_sync_reg[1] && !ddr_frame_start_i) begin
            complete_reg[write_page_reg] <= 1'b0;
            writing_reg <= 1'b0;
        end
        if (rst_ddr) begin
            camera_bad_sync_reg <= 2'b00;
            complete_reg <= 4'b0000;
            write_page_reg <= 2'd0;
            count_reg <= {COUNT_WIDTH{1'b0}};
            writing_reg <= 1'b0;
        end
    end
endmodule
`resetall
