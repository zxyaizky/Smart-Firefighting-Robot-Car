// -----------------------------------------------------------------------------
// File   : lidar_map_overlay.v
// Author : Codex
// Date   : 2026-10-25
// -----------------------------------------------------------------------------
// Description:
//   CPU Wishbone back-buffer bitmap with frame-boundary HDMI page flips.
//   201x201 visible bits, 256-bit row stride, two 2048x32 independent-clock RAMs.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-25  Codex  v1.0  Separate B-board lidar display candidate.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module lidar_map_overlay #(
    parameter integer MAP_X = 1063,
    parameter integer MAP_Y = 240,
    parameter integer STALE_FRAMES = 120,
    parameter integer LABEL_HOLD_FRAMES = 120,
    parameter SEMANTIC_ENABLE = 1'b1
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        clk_pixel,
    input  wire        rst_pixel,
    input  wire        cyc_i,
    input  wire        stb_i,
    input  wire        we_i,
    input  wire [13:0] address_i,
    input  wire [31:0] data_i,
    input  wire [3:0]  select_i,
    input  wire [2:0]  cti_i,
    input  wire [1:0]  bte_i,
    output wire        ack_o,
    output wire        error_o,
    output wire [31:0] data_o,
    // Pixel-domain, frame-committed detections: person, red, green, reserved.
    input  wire [3:0] detect_update_i,
    input  wire [3:0] detect_valid_i,
    input  wire [167:0] detect_bounds_i,
    input  wire [23:0] video_rgb_i,
    input  wire        video_de_i,
    input  wire        video_vsync_i,
    output reg  [23:0] video_rgb_o,
    output wire        video_de_o,
    output wire        video_vsync_o
);
    localparam [10:0] MAP_X_POS = MAP_X;
    localparam [9:0] MAP_Y_POS = MAP_Y;
    localparam [10:0] MAP_X_END = MAP_X + 201;
    localparam [9:0] MAP_Y_END = MAP_Y + 201;

    (* ram_style = "block" *) reg [31:0] bitmap_a [0:2047];
    (* ram_style = "block" *) reg [31:0] bitmap_b [0:2047];
    reg [31:0] bitmap_a_read_reg, bitmap_b_read_reg;
    reg write_bank_reg;
    reg [11:0] write_count_reg;
    reg [15:0] robot_reg, heading_reg;
    reg [31:0] frame_id_reg, displayed_id_reg;
    reg enable_hold_reg;
    reg request_reg, ack_seen_reg;
    (* async_reg = "true" *) reg [1:0] ack_sync;
    (* async_reg = "true" *) reg [1:0] valid_sync;
    reg response_reg, response_error_reg;
    reg [31:0] response_data_reg;
    reg [31:0] read_data;
    wire ready, accept, protocol_valid, bitmap_address, register_address;
    wire write_valid, access_valid, bitmap_write, commit;

    (* async_reg = "true" *) reg [1:0] request_sync;
    (* async_reg = "true" *) reg [1:0] reset_pixel_sync;
    reg acknowledge_reg, front_bank_reg, display_valid_reg, display_enable_reg;
    reg [15:0] robot_display_reg, heading_display_reg;
    reg [7:0] age_reg;
    reg [10:0] pixel_x_reg;
    reg [9:0] pixel_y_reg;
    reg de_previous_reg, vsync_previous_reg;
    wire pixel_reset, frame_start;
    wire [10:0] local_x;
    wire [9:0] local_y;
    wire [7:0] grid_y;
    wire [10:0] read_address;
    wire in_map;
    reg [23:0] rgb_pipe_reg;
    reg de_pipe_reg, vsync_pipe_reg, map_pipe_reg, bank_pipe_reg;
    reg [7:0] map_x_pipe_reg, map_y_pipe_reg;
    reg [4:0] bit_pipe_reg;
    wire [7:0] robot_dx, robot_dy, heading_dx, heading_dy;
    wire point_hit, robot_hit, heading_hit, border_hit, axis_hit;
    reg [63:0] label_position_reg, label_display_reg;
    reg [3:0] label_refresh_reg;
    reg [31:0] label_refresh_age_reg;
    reg [31:0] label_ttl_reg;
    reg [167:0] detect_bounds_reg;
    reg [3:0] detect_valid_reg;
    reg [63:0] detect_sequence_reg;
    reg [31:0] detect_age_reg;
    reg snapshot_request_reg, snapshot_acknowledge_reg, snapshot_seen_reg;
    (* async_reg = "true" *) reg [1:0] snapshot_request_sync;
    (* async_reg = "true" *) reg [1:0] snapshot_ack_sync;
    // The pixel mailbox stays frozen until the next CPU request. Read it only
    // after its synchronized acknowledgement; a second 384-bit copy is unused.
    reg [383:0] detection_hold_reg;
    wire snapshot_ready;
    wire snapshot_access;
    reg [23:0] semantic_rgb;
    integer write_label, pixel_label, paint_label;
    reg [7:0] label_dx, label_dy;
    wire approximate_text;

    function font_hit;
        input [2:0] letter, row, column;
        reg [34:0] glyph;
        reg [5:0] index;
        begin
            case(letter)
                0: glyph=35'b01110_10001_10001_11111_10001_10001_10001; // A
                1,2: glyph=35'b11110_10001_10001_11110_10000_10000_10000; // P
                3: glyph=35'b11110_10001_10001_11110_10100_10010_10001; // R
                4: glyph=35'b01110_10001_10001_10001_10001_10001_01110; // O
                5: glyph=35'b10001_10001_01010_00100_01010_10001_10001; // X
                default: glyph=35'd0;
            endcase
            index=(3'd6-row)*6'd5+(3'd4-column);
            font_hit=column<5 && row<7 && glyph[index];
        end
    endfunction

    assign ready = request_reg == ack_seen_reg;
    assign accept = cyc_i && stb_i && !response_reg && !rst;
    assign protocol_valid = select_i == 4'b1111 && bte_i == 2'b00 &&
        (cti_i == 3'b000 || cti_i == 3'b010 || cti_i == 3'b111);
    assign bitmap_address = address_i[13:11] == 3'b001;
    assign snapshot_ready = snapshot_request_reg == snapshot_seen_reg;
    assign snapshot_access = SEMANTIC_ENABLE && address_i >= 14'd16 && address_i < 14'd28;
    assign register_address = address_i < 14'd8 ||
        (SEMANTIC_ENABLE && (address_i < 14'd13 || snapshot_access));
    assign write_valid = (SEMANTIC_ENABLE && address_i == 14'd12 &&
        data_i == 32'd1 && snapshot_ready) || (ready &&
        ((bitmap_address && write_count_reg < 12'd2048 &&
          {1'b0, address_i[10:0]} == write_count_reg) ||
         address_i == 14'd3 || address_i == 14'd4 || address_i == 14'd5 ||
         (SEMANTIC_ENABLE && address_i >= 14'd8 && address_i < 14'd12 &&
          (!data_i[31] || (data_i[7:0] <= 200 && data_i[15:8] <= 200 &&
                          data_i[23:16] < LABEL_HOLD_FRAMES))) ||
         (address_i == 14'd2 && data_i[0] && write_count_reg == 12'd2048 &&
          robot_reg[7:0] <= 8'd200 && robot_reg[15:8] <= 8'd200 &&
          heading_reg[7:0] <= 8'd200 && heading_reg[15:8] <= 8'd200)));
    assign access_valid = protocol_valid && (we_i ? write_valid :
        (register_address && (!snapshot_access || snapshot_ready)));
    assign bitmap_write = accept && access_valid && we_i && bitmap_address;
    assign commit = accept && access_valid && we_i && address_i == 14'd2;
    assign ack_o = response_reg && !response_error_reg && cyc_i && stb_i && !rst;
    assign error_o = response_reg && response_error_reg && cyc_i && stb_i && !rst;
    assign data_o = response_data_reg;

    always @* begin
        read_data = 32'd0;
        case (address_i)
            14'd0: read_data = 32'h4c4d4150;
            14'd1: read_data = {4'd0, write_count_reg, 13'd0, !ready, valid_sync[1], ready};
            14'd2: read_data = {30'd0, enable_hold_reg, 1'b0};
            14'd3: read_data = {16'd0, robot_reg};
            14'd4: read_data = {16'd0, heading_reg};
            14'd5: read_data = frame_id_reg;
            14'd6: read_data = displayed_id_reg;
            14'd7: read_data = SEMANTIC_ENABLE ? 32'h000200c9 : 32'h000100c9;
            14'd12: read_data = {30'd0, snapshot_seen_reg, snapshot_ready};
            14'd8: if(SEMANTIC_ENABLE) read_data={label_refresh_reg[0],7'd0,label_refresh_age_reg[0 +: 8],label_position_reg[0 +: 16]};
            14'd9: if(SEMANTIC_ENABLE) read_data={label_refresh_reg[1],7'd0,label_refresh_age_reg[8 +: 8],label_position_reg[16 +: 16]};
            14'd10: if(SEMANTIC_ENABLE) read_data={label_refresh_reg[2],7'd0,label_refresh_age_reg[16 +: 8],label_position_reg[32 +: 16]};
            14'd11: if(SEMANTIC_ENABLE) read_data={label_refresh_reg[3],7'd0,label_refresh_age_reg[24 +: 8],label_position_reg[48 +: 16]};
            14'd16: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[0 +: 32];
            14'd17: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[32 +: 32];
            14'd18: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[64 +: 32];
            14'd19: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[96 +: 32];
            14'd20: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[128 +: 32];
            14'd21: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[160 +: 32];
            14'd22: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[192 +: 32];
            14'd23: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[224 +: 32];
            14'd24: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[256 +: 32];
            14'd25: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[288 +: 32];
            14'd26: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[320 +: 32];
            14'd27: if(SEMANTIC_ENABLE) read_data=detection_hold_reg[352 +: 32];
            default: ;
        endcase
    end

    // No RAM reset: a commit requires all 2048 sequential words to be written.
    always @(posedge clk) begin
        if (bitmap_write && !write_bank_reg) bitmap_a[address_i[10:0]] <= data_i;
        if (bitmap_write && write_bank_reg) bitmap_b[address_i[10:0]] <= data_i;
    end

    always @(posedge clk) begin
        ack_sync <= {ack_sync[0], acknowledge_reg};
        valid_sync <= {valid_sync[0], display_valid_reg};
        snapshot_ack_sync <= {snapshot_ack_sync[0], snapshot_acknowledge_reg};
        if(snapshot_ack_sync[1] != snapshot_seen_reg) begin
            snapshot_seen_reg <= snapshot_ack_sync[1];
        end
        response_reg <= accept;
        if (accept) begin
            response_error_reg <= !access_valid;
            response_data_reg <= read_data;
        end
        if (bitmap_write) write_count_reg <= write_count_reg + 12'd1;
        if (accept && access_valid && we_i) begin
            case (address_i)
                14'd3: robot_reg <= data_i[15:0];
                14'd4: heading_reg <= data_i[15:0];
                14'd5: frame_id_reg <= data_i;
                14'd12: snapshot_request_reg <= !snapshot_request_reg;
                default: ;
            endcase
            for(write_label=0;write_label<4;write_label=write_label+1)
                if(SEMANTIC_ENABLE && address_i==8+write_label) begin
                    label_position_reg[write_label*16 +: 16] <= data_i[15:0];
                    label_refresh_reg[write_label] <= data_i[31];
                    label_refresh_age_reg[write_label*8 +: 8] <= data_i[23:16];
                end
        end
        if (commit) begin
            request_reg <= !request_reg;
            enable_hold_reg <= data_i[1];
        end
        if (ack_sync[1] != ack_seen_reg) begin
            ack_seen_reg <= ack_sync[1];
            write_bank_reg <= !write_bank_reg;
            write_count_reg <= 12'd0;
            displayed_id_reg <= frame_id_reg;
            label_refresh_reg <= 4'd0;
            label_refresh_age_reg <= 32'd0;
        end
        if (rst) begin
            ack_sync <= 2'b00;
            valid_sync <= 2'b00;
            response_reg <= 1'b0;
            response_error_reg <= 1'b0;
            response_data_reg <= 32'd0;
            write_bank_reg <= 1'b1;
            write_count_reg <= 12'd0;
            robot_reg <= 16'd0;
            heading_reg <= 16'd0;
            frame_id_reg <= 32'd0;
            displayed_id_reg <= 32'd0;
            enable_hold_reg <= 1'b0;
            request_reg <= 1'b0;
            ack_seen_reg <= 1'b0;
            label_position_reg <= 64'd0;
            label_refresh_reg <= 4'd0;
            label_refresh_age_reg <= 32'd0;
            snapshot_request_reg <= 1'b0;
            snapshot_ack_sync <= 2'd0;
            snapshot_seen_reg <= 1'b0;
        end
    end

    assign pixel_reset = rst_pixel || reset_pixel_sync[1];
    assign frame_start = video_vsync_i && !vsync_previous_reg;
    assign local_x = pixel_x_reg - MAP_X_POS;
    assign local_y = pixel_y_reg - MAP_Y_POS;
    assign grid_y = 8'd200 - local_y[7:0];
    assign read_address = {grid_y, local_x[7:5]};
    assign in_map = video_de_i && pixel_x_reg >= MAP_X_POS && pixel_x_reg < MAP_X_END &&
        pixel_y_reg >= MAP_Y_POS && pixel_y_reg < MAP_Y_END;

    // A bank being written by the CPU is never read by the pixel port.
    always @(posedge clk_pixel) begin
        if (!front_bank_reg) bitmap_a_read_reg <= bitmap_a[read_address];
        if (front_bank_reg) bitmap_b_read_reg <= bitmap_b[read_address];
    end

    always @(posedge clk_pixel) begin
        reset_pixel_sync <= {reset_pixel_sync[0], rst};
        if (rst_pixel) reset_pixel_sync <= 2'b11;
        request_sync <= {request_sync[0], request_reg};
        snapshot_request_sync <= {snapshot_request_sync[0], snapshot_request_reg};
        for(pixel_label=0;pixel_label<4;pixel_label=pixel_label+1) begin
            if(frame_start) begin
                if(label_ttl_reg[8*pixel_label +: 8] != 0)
                    label_ttl_reg[8*pixel_label +: 8] <= label_ttl_reg[8*pixel_label +: 8]-1'b1;
                if(detect_age_reg[8*pixel_label +: 8] != 255)
                    detect_age_reg[8*pixel_label +: 8] <= detect_age_reg[8*pixel_label +: 8]+1'b1;
            end
            if(SEMANTIC_ENABLE && detect_update_i[pixel_label]) begin
                detect_bounds_reg[42*pixel_label +: 42] <= detect_bounds_i[42*pixel_label +: 42];
                detect_valid_reg[pixel_label] <= detect_valid_i[pixel_label];
                detect_sequence_reg[16*pixel_label +: 16] <= detect_sequence_reg[16*pixel_label +: 16]+1'b1;
                detect_age_reg[8*pixel_label +: 8] <= 8'd0;
            end
            if(snapshot_request_sync[1] != snapshot_acknowledge_reg) begin
                detection_hold_reg[96*pixel_label +: 32] <=
                    {detect_sequence_reg[16*pixel_label +: 16],detect_age_reg[8*pixel_label +: 8],7'd0,
                     detect_valid_reg[pixel_label] && detect_age_reg[8*pixel_label +: 8] < LABEL_HOLD_FRAMES};
                detection_hold_reg[96*pixel_label+32 +: 32] <=
                    {6'd0,detect_bounds_reg[42*pixel_label+11 +: 10],5'd0,detect_bounds_reg[42*pixel_label +: 11]};
                detection_hold_reg[96*pixel_label+64 +: 32] <=
                    {6'd0,detect_bounds_reg[42*pixel_label+32 +: 10],5'd0,detect_bounds_reg[42*pixel_label+21 +: 11]};
            end
        end
        if(snapshot_request_sync[1] != snapshot_acknowledge_reg)
            snapshot_acknowledge_reg <= snapshot_request_sync[1];
        vsync_previous_reg <= video_vsync_i;
        de_previous_reg <= video_de_i;
        if (video_vsync_i) begin
            pixel_x_reg <= 11'd0;
            pixel_y_reg <= 10'd0;
        end else if (video_de_i) begin
            pixel_x_reg <= pixel_x_reg + 11'd1;
        end else begin
            pixel_x_reg <= 11'd0;
            if (de_previous_reg) pixel_y_reg <= pixel_y_reg + 10'd1;
        end
        if (frame_start && display_valid_reg && age_reg != 8'hff)
            age_reg <= age_reg + 8'd1;
        if (frame_start && request_sync[1] != acknowledge_reg) begin
            front_bank_reg <= !front_bank_reg;
            robot_display_reg <= robot_reg;
            heading_display_reg <= heading_reg;
            display_enable_reg <= enable_hold_reg;
            display_valid_reg <= 1'b1;
            acknowledge_reg <= request_sync[1];
            age_reg <= 8'd0;
            if(SEMANTIC_ENABLE) begin
                for(pixel_label=0;pixel_label<4;pixel_label=pixel_label+1)
                    if(label_refresh_reg[pixel_label]) begin
                        label_display_reg[16*pixel_label +: 16] <= label_position_reg[16*pixel_label +: 16];
                        label_ttl_reg[8*pixel_label +: 8] <= LABEL_HOLD_FRAMES-label_refresh_age_reg[8*pixel_label +: 8];
                    end
            end
        end
        rgb_pipe_reg <= video_rgb_i;
        de_pipe_reg <= video_de_i;
        vsync_pipe_reg <= video_vsync_i;
        map_pipe_reg <= in_map && display_valid_reg && display_enable_reg;
        bank_pipe_reg <= front_bank_reg;
        map_x_pipe_reg <= local_x[7:0];
        map_y_pipe_reg <= grid_y;
        bit_pipe_reg <= local_x[4:0];
        if (pixel_reset) begin
            request_sync <= 2'b00;
            acknowledge_reg <= 1'b0;
            front_bank_reg <= 1'b0;
            display_valid_reg <= 1'b0;
            display_enable_reg <= 1'b0;
            robot_display_reg <= 16'd0;
            heading_display_reg <= 16'd0;
            age_reg <= 8'd0;
            pixel_x_reg <= 11'd0;
            pixel_y_reg <= 10'd0;
            de_previous_reg <= 1'b0;
            vsync_previous_reg <= 1'b0;
            rgb_pipe_reg <= 24'd0;
            de_pipe_reg <= 1'b0;
            vsync_pipe_reg <= 1'b0;
            map_pipe_reg <= 1'b0;
            bank_pipe_reg <= 1'b0;
            map_x_pipe_reg <= 8'd0;
            map_y_pipe_reg <= 8'd0;
            bit_pipe_reg <= 5'd0;
            label_display_reg <= 64'd0;
            label_ttl_reg <= 32'd0;
            detect_bounds_reg <= 168'd0;
            detect_valid_reg <= 4'd0;
            detect_sequence_reg <= 64'd0;
            detect_age_reg <= 32'hffffffff;
            snapshot_request_sync <= 2'd0;
            snapshot_acknowledge_reg <= 1'b0;
            detection_hold_reg <= 384'd0;
        end
    end

    // Valid grid coordinates are 0..200, so 8-bit modular windows do not alias.
    assign robot_dx = map_x_pipe_reg + 8'd2 - robot_display_reg[7:0];
    assign robot_dy = map_y_pipe_reg + 8'd2 - robot_display_reg[15:8];
    assign heading_dx = map_x_pipe_reg + 8'd1 - heading_display_reg[7:0];
    assign heading_dy = map_y_pipe_reg + 8'd1 - heading_display_reg[15:8];
    assign point_hit = bank_pipe_reg ? bitmap_b_read_reg[bit_pipe_reg] :
        bitmap_a_read_reg[bit_pipe_reg];
    assign robot_hit = (robot_dx <= 8'd4 && robot_dy == 8'd2) ||
        (robot_dx == 8'd2 && robot_dy <= 8'd4);
    assign heading_hit = heading_dx <= 8'd2 && heading_dy <= 8'd2;
    assign border_hit = map_x_pipe_reg == 8'd0 || map_x_pipe_reg == 8'd200 ||
        map_y_pipe_reg == 8'd0 || map_y_pipe_reg == 8'd200;
    assign axis_hit = map_x_pipe_reg == 8'd100 || map_y_pipe_reg == 8'd100;
    assign video_de_o = de_pipe_reg;
    assign video_vsync_o = vsync_pipe_reg;

    assign approximate_text = SEMANTIC_ENABLE && map_x_pipe_reg>=4 && map_x_pipe_reg<52 &&
        map_y_pipe_reg>=190 && map_y_pipe_reg<=196 &&
        font_hit((map_x_pipe_reg-4)>>3,196-map_y_pipe_reg,(map_x_pipe_reg-4)&7);
    always @* begin
        semantic_rgb=24'hffffff;
        label_dx=0;label_dy=0;
        for(paint_label=3;paint_label>=0;paint_label=paint_label-1) begin
            // The 0..200 grid leaves enough margin to use an 8-bit modular window.
            label_dx=map_x_pipe_reg+8'd3-label_display_reg[16*paint_label +: 8];
            label_dy=map_y_pipe_reg+8'd3-label_display_reg[16*paint_label+8 +: 8];
            if(SEMANTIC_ENABLE && label_ttl_reg[8*paint_label +: 8]!=0 && label_dx<=6 && label_dy<=6)
                case(paint_label)
                    0: semantic_rgb=24'hff40ff;
                    1: semantic_rgb=24'hff3030;
                    2: semantic_rgb=24'h00c878;
                    3: semantic_rgb=24'hffe040;
                endcase
        end
    end

    always @* begin
        video_rgb_o = rgb_pipe_reg;
        if (map_pipe_reg && de_pipe_reg) begin
            if (robot_hit) video_rgb_o = 24'h00ff40;
            else if (heading_hit) video_rgb_o = 24'hffff00;
            else if (border_hit) video_rgb_o = age_reg >= STALE_FRAMES ? 24'hff3030 : 24'h708090;
            else if (approximate_text) video_rgb_o = 24'hffb040;
            else if (point_hit) video_rgb_o = semantic_rgb;
            else if (axis_hit) video_rgb_o = 24'h203840;
            else video_rgb_o = 24'h081018;
        end
    end
endmodule
`resetall
