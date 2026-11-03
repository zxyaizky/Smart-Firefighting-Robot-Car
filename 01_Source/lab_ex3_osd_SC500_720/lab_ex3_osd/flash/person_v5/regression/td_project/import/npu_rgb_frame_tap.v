// -----------------------------------------------------------------------------
// File   : npu_rgb_frame_tap.v
// Author : OpenAI Codex
// Date   : 2026-09-20
// -----------------------------------------------------------------------------
// Description:
//   Reconstruct the pre-CHW 160x90 RGB raster from the NPU byte stream and add
//   15 black rows above and below it to form a 160x120 RGB888 frame.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-20  OpenAI Codex  v1.0  Initial implementation
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module npu_rgb_frame_tap
(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_valid_i,
    input  wire        byte_valid_i,
    input  wire [7:0]  byte_i,
    output wire        frame_start_o,
    output wire        pixel_valid_o,
    output wire [23:0] pixel_rgb_o,
    output wire        frame_end_o,
    output wire        frame_abort_o,
    output wire [14:0] pixel_count_o
);

    localparam [4:0]
        STATE_IDLE        = 5'b0_0001,
        STATE_TOP_PAD     = 5'b0_0010,
        STATE_ACTIVE      = 5'b0_0100,
        STATE_WAIT_END    = 5'b0_1000,
        STATE_BOTTOM_PAD  = 5'b1_0000;

    localparam [11:0] PAD_PIXELS = 12'd2400;
    localparam [14:0] ACTIVE_PIXELS = 15'd14400;

    reg [4:0]  state_reg = STATE_IDLE, state_next;
    reg        frame_valid_d_reg = 1'b0, frame_valid_d_next;
    reg [11:0] pad_count_reg = 12'd0, pad_count_next;
    reg [14:0] pixel_count_reg = 15'd0, pixel_count_next;
    reg [1:0]  byte_phase_reg = 2'd0, byte_phase_next;
    reg [7:0]  red_reg = 8'd0, red_next;
    reg [7:0]  green_reg = 8'd0, green_next;
    reg        frame_start_reg = 1'b0, frame_start_next;
    reg        pixel_valid_reg = 1'b0, pixel_valid_next;
    reg [23:0] pixel_rgb_reg = 24'd0, pixel_rgb_next;
    reg        frame_end_reg = 1'b0, frame_end_next;
    reg        frame_abort_reg = 1'b0, frame_abort_next;

    wire frame_rise;

    assign frame_rise    = frame_valid_i && !frame_valid_d_reg;
    assign frame_start_o = frame_start_reg;
    assign pixel_valid_o = pixel_valid_reg;
    assign pixel_rgb_o   = pixel_rgb_reg;
    assign frame_end_o   = frame_end_reg;
    assign frame_abort_o = frame_abort_reg;
    assign pixel_count_o = pixel_count_reg;

    always @* begin
        state_next         = state_reg;
        frame_valid_d_next = frame_valid_i;
        pad_count_next     = pad_count_reg;
        pixel_count_next   = pixel_count_reg;
        byte_phase_next    = byte_phase_reg;
        red_next           = red_reg;
        green_next         = green_reg;
        frame_start_next   = 1'b0;
        pixel_valid_next   = 1'b0;
        pixel_rgb_next     = 24'd0;
        frame_end_next     = 1'b0;
        frame_abort_next   = 1'b0;

        case (state_reg)
            STATE_IDLE: begin
                pad_count_next   = 12'd0;
                pixel_count_next = 15'd0;
                byte_phase_next  = 2'd0;
                if (frame_rise) begin
                    state_next       = STATE_TOP_PAD;
                    frame_start_next = 1'b1;
                end
            end
            STATE_TOP_PAD: begin
                if (!frame_valid_i || byte_valid_i) begin
                    state_next       = STATE_IDLE;
                    frame_abort_next = 1'b1;
                end else begin
                    pixel_valid_next = 1'b1;
                    pixel_rgb_next   = 24'd0;
                    if (pad_count_reg == PAD_PIXELS - 12'd1) begin
                        pad_count_next = 12'd0;
                        state_next     = STATE_ACTIVE;
                    end else begin
                        pad_count_next = pad_count_reg + 12'd1;
                    end
                end
            end
            STATE_ACTIVE: begin
                if (!frame_valid_i) begin
                    state_next       = STATE_IDLE;
                    frame_abort_next = 1'b1;
                end else if (byte_valid_i) begin
                    case (byte_phase_reg)
                        2'd0: begin
                            red_next        = byte_i;
                            byte_phase_next = 2'd1;
                        end
                        2'd1: begin
                            green_next      = byte_i;
                            byte_phase_next = 2'd2;
                        end
                        2'd2: begin
                            pixel_valid_next = 1'b1;
                            pixel_rgb_next   = {red_reg, green_reg, byte_i};
                            byte_phase_next  = 2'd0;
                            if (pixel_count_reg == ACTIVE_PIXELS - 15'd1) begin
                                pixel_count_next = ACTIVE_PIXELS;
                                state_next       = STATE_WAIT_END;
                            end else begin
                                pixel_count_next = pixel_count_reg + 15'd1;
                            end
                        end
                        default: begin
                            byte_phase_next = 2'd0;
                        end
                    endcase
                end
            end
            STATE_WAIT_END: begin
                if (byte_valid_i) begin
                    state_next       = STATE_IDLE;
                    frame_abort_next = 1'b1;
                end else if (!frame_valid_i) begin
                    pad_count_next = 12'd0;
                    state_next     = STATE_BOTTOM_PAD;
                end
            end
            STATE_BOTTOM_PAD: begin
                pixel_valid_next = 1'b1;
                pixel_rgb_next   = 24'd0;
                if (pad_count_reg == PAD_PIXELS - 12'd1) begin
                    pad_count_next = 12'd0;
                    frame_end_next = 1'b1;
                    state_next     = STATE_IDLE;
                end else begin
                    pad_count_next = pad_count_reg + 12'd1;
                end
            end
            default: begin
                state_next       = STATE_IDLE;
                frame_abort_next = 1'b1;
            end
        endcase
    end

    always @(posedge clk) begin
        state_reg         <= state_next;
        frame_valid_d_reg <= frame_valid_d_next;
        pad_count_reg     <= pad_count_next;
        pixel_count_reg   <= pixel_count_next;
        byte_phase_reg    <= byte_phase_next;
        red_reg           <= red_next;
        green_reg         <= green_next;
        frame_start_reg   <= frame_start_next;
        pixel_valid_reg   <= pixel_valid_next;
        pixel_rgb_reg     <= pixel_rgb_next;
        frame_end_reg     <= frame_end_next;
        frame_abort_reg   <= frame_abort_next;

        if (rst) begin
            state_reg         <= STATE_IDLE;
            frame_valid_d_reg <= 1'b0;
            pad_count_reg     <= 12'd0;
            pixel_count_reg   <= 15'd0;
            byte_phase_reg    <= 2'd0;
            red_reg           <= 8'd0;
            green_reg         <= 8'd0;
            frame_start_reg   <= 1'b0;
            pixel_valid_reg   <= 1'b0;
            pixel_rgb_reg     <= 24'd0;
            frame_end_reg     <= 1'b0;
            frame_abort_reg   <= 1'b0;
        end
    end

endmodule

`resetall
