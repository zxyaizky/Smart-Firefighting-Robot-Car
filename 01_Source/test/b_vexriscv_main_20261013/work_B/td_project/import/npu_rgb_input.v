// -----------------------------------------------------------------------------
// File   : npu_rgb_input.v
// Author : Codex
// Date   : 2026-09-08
// Description: Whole-frame RGB nearest-neighbor capture and CHW clock crossing.
// Change Log: 2026-09-08 v1.0 Initial implementation.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

module npu_rgb_input (
    input  wire        clk_video,
    input  wire        clk_npu,
    input  wire        rst_n,
    input  wire        i_sof,
    input  wire        i_valid,
    input  wire [23:0] i_rgb,
    input  wire        i_npu_busy,
    output wire        o_frame_valid,
    output wire        o_byte_valid,
    output wire [7:0]  o_byte,
    output wire        o_capture_busy
);
    // Both domains share asynchronous reset assertion and independently synchronize
    // release. RAM needs no reset: only a complete post-reset capture is published.
    reg [1:0] video_reset_sync, npu_reset_sync;
    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) video_reset_sync <= 2'b00;
        else video_reset_sync <= {video_reset_sync[0], 1'b1};
    end
    always @(posedge clk_npu or negedge rst_n) begin
        if (!rst_n) npu_reset_sync <= 2'b00;
        else npu_reset_sync <= {npu_reset_sync[0], 1'b1};
    end

    // Simple dual-port, dual-clock RAM. The video port owns it until publication;
    // the NPU port owns it from synchronized request through acknowledgement.
    (* ram_style = "block" *) reg [23:0] samples [0:15039];
    reg request_reg, acknowledge_reg;
    (* async_reg = "true" *) reg [1:0] ack_sync, request_sync, busy_sync;
    reg capture_reg;
    reg [9:0] x_reg, y_reg;
    reg [7:0] dx_reg, dy_reg;
    reg [13:0] sample_count_reg;
    wire available = (request_reg == ack_sync[1]) && !busy_sync[1];
    wire capture = i_sof ? available : capture_reg;
    wire [9:0] x = i_sof ? 10'd0 : x_reg;
    wire [9:0] y = i_sof ? 10'd0 : y_reg;
    wire [7:0] dx = i_sof ? 8'd0 : dx_reg;
    wire [7:0] dy = i_sof ? 8'd0 : dy_reg;
    wire [18:0] target_x = ((({11'd0, dx} << 1) + 19'd1) * 19'd1024) / 19'd320;
    wire [18:0] target_y = ((({11'd0, dy} << 1) + 19'd1) * 19'd600) / 19'd188;
    wire sample_write = video_reset_sync[1] && capture && i_valid &&
        dx < 160 && dy < 94 && x == target_x && y == target_y;
    wire [13:0] sample_addr = i_sof ? 14'd0 : sample_count_reg;

    assign o_capture_busy = capture_reg || (request_reg != ack_sync[1]);
    always @(posedge clk_video) begin
        if (sample_write) samples[sample_addr] <= i_rgb;
    end

    // CDC: clk_npu -> clk_video, single-bit control only.
    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            ack_sync <= 2'b00;
            busy_sync <= 2'b11;
        end else if (!video_reset_sync[1]) begin
            ack_sync <= 2'b00;
            busy_sync <= 2'b11;
        end else begin
            ack_sync <= {ack_sync[0], acknowledge_reg};
            busy_sync <= {busy_sync[0], i_npu_busy};
        end
    end

    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            request_reg <= 1'b0;
            capture_reg <= 1'b0;
            x_reg <= 10'd0;
            y_reg <= 10'd0;
            dx_reg <= 8'd0;
            dy_reg <= 8'd0;
            sample_count_reg <= 14'd0;
        end else if (video_reset_sync[1]) begin
            // SOF aborts any incomplete source frame. Becoming free mid-frame
            // never enables capture; the next SOF is required after busy/reset.
            if (i_sof) begin
                capture_reg <= available;
                x_reg <= 10'd0;
                y_reg <= 10'd0;
                dx_reg <= 8'd0;
                dy_reg <= 8'd0;
                sample_count_reg <= 14'd0;
            end
            if (capture && i_valid) begin
                if (sample_write) begin
                    sample_count_reg <= sample_addr + 14'd1;
                    dx_reg <= dx + 8'd1;
                end
                if (x == 1023) begin
                    x_reg <= 10'd0;
                    dx_reg <= 8'd0;
                    y_reg <= y + 10'd1;
                    if (y == target_y && dy < 94) dy_reg <= dy + 8'd1;
                    if (y == 599) begin
                        capture_reg <= 1'b0;
                        // Last selected pixel precedes source EOF. Do not publish
                        // early: even an interruption in the unsampled tail aborts.
                        if (sample_count_reg == 15040)
                            request_reg <= ~request_reg;
                    end
                end else x_reg <= x + 10'd1;
            end
        end
    end

    // CDC: clk_video -> clk_npu. RAM contents are stable for at least two NPU
    // clocks before request_sync is observed, and until ack returns to video.
    always @(posedge clk_npu or negedge rst_n) begin
        if (!rst_n) request_sync <= 2'b00;
        else if (!npu_reset_sync[1]) request_sync <= 2'b00;
        else request_sync <= {request_sync[0], request_reg};
    end

    // Binary local FSM. One read cycle followed by one emit cycle avoids any
    // dependence on video blanking or the ratio/phase of the two clocks.
    localparam [1:0] ST_IDLE = 2'd0, ST_READ = 2'd1, ST_EMIT = 2'd2, ST_END = 2'd3;
    reg [1:0] state_reg;
    reg [7:0] out_x_reg, out_y_reg;
    reg [1:0] channel_reg;
    reg [23:0] ram_data_reg;
    reg frame_reg, valid_reg;
    reg [7:0] byte_reg;
    wire black_row = out_y_reg < 13 || out_y_reg >= 107;
    wire [15:0] read_addr = (out_y_reg - 16'd13) * 16'd160 + out_x_reg;
    assign o_frame_valid = frame_reg;
    assign o_byte_valid = valid_reg;
    assign o_byte = byte_reg;
    always @(posedge clk_npu) begin
        if (npu_reset_sync[1] && state_reg == ST_READ && !black_row)
            ram_data_reg <= samples[read_addr];
    end
    always @(posedge clk_npu or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= ST_IDLE;
            acknowledge_reg <= 1'b0;
            out_x_reg <= 8'd0;
            out_y_reg <= 8'd0;
            channel_reg <= 2'd0;
            frame_reg <= 1'b0;
            valid_reg <= 1'b0;
            byte_reg <= 8'd0;
        end else if (npu_reset_sync[1]) begin
            valid_reg <= 1'b0;
            case (state_reg)
                ST_IDLE: begin
                    if (request_sync[1] != acknowledge_reg && !i_npu_busy) begin
                        out_x_reg <= 8'd0;
                        out_y_reg <= 8'd0;
                        channel_reg <= 2'd0;
                        frame_reg <= 1'b1;
                        state_reg <= ST_READ;
                    end
                end
                ST_READ: state_reg <= ST_EMIT;
                ST_EMIT: begin
                    valid_reg <= 1'b1;
                    byte_reg <= black_row ? 8'd0 :
                        (channel_reg == 0 ? ram_data_reg[23:16] :
                         channel_reg == 1 ? ram_data_reg[15:8] : ram_data_reg[7:0]);
                    state_reg <= ST_READ;
                    if (out_x_reg == 159) begin
                        out_x_reg <= 8'd0;
                        if (out_y_reg == 119) begin
                            out_y_reg <= 8'd0;
                            channel_reg <= channel_reg + 2'd1;
                            if (channel_reg == 2) state_reg <= ST_END;
                        end else out_y_reg <= out_y_reg + 8'd1;
                    end else out_x_reg <= out_x_reg + 8'd1;
                end
                ST_END: begin
                    frame_reg <= 1'b0;
                    acknowledge_reg <= request_sync[1];
                    state_reg <= ST_IDLE;
                end
                default: state_reg <= ST_IDLE;
            endcase
        end
    end
endmodule
`resetall
