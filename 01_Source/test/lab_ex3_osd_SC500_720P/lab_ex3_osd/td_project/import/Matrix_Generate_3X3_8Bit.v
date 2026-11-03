// -----------------------------------------------------------------------------
// File   : Matrix_Generate_3X3_8Bit.v
// Author : unknown
// Date   : 2026-10-01
// -----------------------------------------------------------------------------
// Description:
//   Pixel-enabled 3x3 window, with replicated horizontal and startup borders.
//   Output row y uses input rows max(y-2,0), max(y-1,0), y. One line of
//   vertical look-behind is inherent in this streaming interface.
//   Require IMG_HDISP >= 3 and at least one blank clock between complete lines.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-01  unknown  v2.0  Exact line tails, frame isolation, arbitrary enables.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module Matrix_Generate_3X3_8Bit #
(
    // Active pixels per complete input line.
    parameter [10:0] IMG_HDISP = 11'd1280,
    // Retained for existing instantiations; enables now support either cadence.
    parameter SPARSE_INPUT = 1'b0,
    // Also carries packed magnitude/direction for Sobel nonmaximum suppression.
    parameter DATA_WIDTH = 8
)
(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  per_frame_vsync,
    input  wire                  per_frame_href,
    input  wire                  per_frame_clken,
    input  wire [DATA_WIDTH-1:0] per_img_Y,
    output wire                  matrix_frame_vsync,
    output wire                  matrix_frame_href,
    output wire                  matrix_frame_clken,
    output wire [DATA_WIDTH-1:0] matrix_p11,
    output wire [DATA_WIDTH-1:0] matrix_p12,
    output wire [DATA_WIDTH-1:0] matrix_p13,
    output wire [DATA_WIDTH-1:0] matrix_p21,
    output wire [DATA_WIDTH-1:0] matrix_p22,
    output wire [DATA_WIDTH-1:0] matrix_p23,
    output wire [DATA_WIDTH-1:0] matrix_p31,
    output wire [DATA_WIDTH-1:0] matrix_p32,
    output wire [DATA_WIDTH-1:0] matrix_p33
);

wire rst;
wire input_valid;
wire frame_start;
wire [DATA_WIDTH-1:0] top_sample;
wire [DATA_WIDTH-1:0] middle_sample;

reg [2*DATA_WIDTH-1:0] line_memory [0:IMG_HDISP-1];
reg [2*DATA_WIDTH-1:0] line_read_pipe_reg;
reg [DATA_WIDTH-1:0] pixel_pipe_reg = {DATA_WIDTH{1'b0}};
reg [10:0] column_reg = 11'd0;
reg [1:0] history_rows_reg = 2'd0;
reg vsync_reg = 1'b0;
reg [1:0] vsync_pipe_reg = 2'd0;
reg valid_pipe_reg = 1'b0;
reg [10:0] column_pipe_reg = 11'd0;
reg [1:0] history_rows_pipe_reg = 2'd0;
reg tail_pending_reg = 1'b0;
reg line_active_reg = 1'b0;
reg window_vsync_reg = 1'b0;
reg window_href_reg = 1'b0;
reg window_clken_reg = 1'b0;
reg [DATA_WIDTH-1:0] top_left_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] top_center_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] middle_left_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] middle_center_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] bottom_left_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] bottom_center_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] window_p11_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] window_p12_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] window_p13_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] window_p21_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] window_p22_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] window_p23_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] window_p31_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] window_p32_reg = {DATA_WIDTH{1'b0}};
reg [DATA_WIDTH-1:0] window_p33_reg = {DATA_WIDTH{1'b0}};

assign rst = !rst_n;
assign input_valid = per_frame_href && per_frame_clken && !per_frame_vsync;
assign frame_start = per_frame_vsync && !vsync_reg;
// RAM is deliberately not reset. Row metadata hides all unwritten/stale words.
assign middle_sample = (history_rows_pipe_reg == 2'd0) ?
                       pixel_pipe_reg : line_read_pipe_reg[DATA_WIDTH-1:0];
assign top_sample = (history_rows_pipe_reg < 2'd2) ?
                    middle_sample : line_read_pipe_reg[2*DATA_WIDTH-1:DATA_WIDTH];
assign matrix_frame_vsync = window_vsync_reg;
assign matrix_frame_href  = window_href_reg;
assign matrix_frame_clken = window_clken_reg;
assign matrix_p11 = window_p11_reg;
assign matrix_p12 = window_p12_reg;
assign matrix_p13 = window_p13_reg;
assign matrix_p21 = window_p21_reg;
assign matrix_p22 = window_p22_reg;
assign matrix_p23 = window_p23_reg;
assign matrix_p31 = window_p31_reg;
assign matrix_p32 = window_p32_reg;
assign matrix_p33 = window_p33_reg;

// Single synchronous read and delayed write; consecutive pixels use different
// addresses. The packed word stores the previous two lines in inferred block RAM.
always @(posedge clk) begin
    if (!rst && input_valid) begin
        line_read_pipe_reg <= line_memory[column_reg];
    end
    if (!rst && valid_pipe_reg) begin
        line_memory[column_pipe_reg] <= {middle_sample, pixel_pipe_reg};
    end
end

always @(posedge clk) begin
    vsync_reg <= per_frame_vsync;
    vsync_pipe_reg <= {vsync_pipe_reg[0], per_frame_vsync};
    valid_pipe_reg <= input_valid;
    if (input_valid) begin
        pixel_pipe_reg <= per_img_Y;
        column_pipe_reg <= column_reg;
        history_rows_pipe_reg <= history_rows_reg;
        if (column_reg == IMG_HDISP - 11'd1) begin
            column_reg <= 11'd0;
            if (history_rows_reg < 2'd2) begin
                history_rows_reg <= history_rows_reg + 2'd1;
            end
        end else begin
            column_reg <= column_reg + 11'd1;
        end
    end
    if (frame_start) begin
        column_reg <= 11'd0;
        history_rows_reg <= 2'd0;
    end
    if (rst) begin
        vsync_reg <= 1'b0;
        vsync_pipe_reg <= 2'd0;
        valid_pipe_reg <= 1'b0;
        pixel_pipe_reg <= {DATA_WIDTH{1'b0}};
        column_pipe_reg <= 11'd0;
        history_rows_pipe_reg <= 2'd0;
        column_reg <= 11'd0;
        history_rows_reg <= 2'd0;
    end
end

// A pixel of lookahead centers the horizontal window. Emit the final column
// explicitly, using the held last pixel rather than speculative blanking reads.
always @(posedge clk) begin
    window_vsync_reg <= vsync_pipe_reg[1];
    window_href_reg <= line_active_reg;
    window_clken_reg <= 1'b0;
    tail_pending_reg <= 1'b0;
    if (tail_pending_reg) begin
        window_href_reg <= 1'b1;
        window_clken_reg <= 1'b1;
        line_active_reg <= 1'b0;
        window_p11_reg <= top_left_reg;
        window_p12_reg <= top_center_reg;
        window_p13_reg <= top_center_reg;
        window_p21_reg <= middle_left_reg;
        window_p22_reg <= middle_center_reg;
        window_p23_reg <= middle_center_reg;
        window_p31_reg <= bottom_left_reg;
        window_p32_reg <= bottom_center_reg;
        window_p33_reg <= bottom_center_reg;
    end else if (valid_pipe_reg) begin
        if (column_pipe_reg == 11'd0) begin
            top_left_reg <= top_sample;
            top_center_reg <= top_sample;
            middle_left_reg <= middle_sample;
            middle_center_reg <= middle_sample;
            bottom_left_reg <= pixel_pipe_reg;
            bottom_center_reg <= pixel_pipe_reg;
        end else begin
            window_href_reg <= 1'b1;
            window_clken_reg <= 1'b1;
            line_active_reg <= 1'b1;
            window_p11_reg <= top_left_reg;
            window_p12_reg <= top_center_reg;
            window_p13_reg <= top_sample;
            top_left_reg <= top_center_reg;
            top_center_reg <= top_sample;
            window_p21_reg <= middle_left_reg;
            window_p22_reg <= middle_center_reg;
            window_p23_reg <= middle_sample;
            middle_left_reg <= middle_center_reg;
            middle_center_reg <= middle_sample;
            window_p31_reg <= bottom_left_reg;
            window_p32_reg <= bottom_center_reg;
            window_p33_reg <= pixel_pipe_reg;
            bottom_left_reg <= bottom_center_reg;
            bottom_center_reg <= pixel_pipe_reg;
            if (column_pipe_reg == IMG_HDISP - 11'd1) begin
                tail_pending_reg <= 1'b1;
            end
        end
    end
    if (rst) begin
        window_vsync_reg <= 1'b0;
        window_href_reg <= 1'b0;
        window_clken_reg <= 1'b0;
        line_active_reg <= 1'b0;
        tail_pending_reg <= 1'b0;
        top_left_reg <= {DATA_WIDTH{1'b0}};
        top_center_reg <= {DATA_WIDTH{1'b0}};
        middle_left_reg <= {DATA_WIDTH{1'b0}};
        middle_center_reg <= {DATA_WIDTH{1'b0}};
        bottom_left_reg <= {DATA_WIDTH{1'b0}};
        bottom_center_reg <= {DATA_WIDTH{1'b0}};
        window_p11_reg <= {DATA_WIDTH{1'b0}};
        window_p12_reg <= {DATA_WIDTH{1'b0}};
        window_p13_reg <= {DATA_WIDTH{1'b0}};
        window_p21_reg <= {DATA_WIDTH{1'b0}};
        window_p22_reg <= {DATA_WIDTH{1'b0}};
        window_p23_reg <= {DATA_WIDTH{1'b0}};
        window_p31_reg <= {DATA_WIDTH{1'b0}};
        window_p32_reg <= {DATA_WIDTH{1'b0}};
        window_p33_reg <= {DATA_WIDTH{1'b0}};
    end
end

endmodule
`resetall
