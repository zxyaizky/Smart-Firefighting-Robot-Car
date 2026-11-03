// Change Log: 2026-10-22 Codex v3.0 640x360 RGB565, 360 row packets.
// Change Log: 2026-10-02 Codex v2.0 Stereo stage 2 sync/source/bbox metadata.
// -----------------------------------------------------------------------------
// File   : video_udp_tx.v
// Author : OpenAI Codex
// Date   : 2026-09-20
// -----------------------------------------------------------------------------
// Description:
//   Cross a framed 640x360 RGB565 stream into the Ethernet clock domain, split
//   each frame into 360 UDP payloads, and drive the uiudp_stack user interface.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-20  OpenAI Codex  v1.0  Initial implementation
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module video_udp_tx #
(
    // Async FIFO depth is 2**FIFO_ADDR_WIDTH RGB tokens
    parameter FIFO_ADDR_WIDTH = 12
)
(
    input  wire        clk_pixel,
    input  wire        rst_pixel,
    input  wire        clk_udp,
    input  wire        rst_udp,
    input  wire        frame_start_i,
    input  wire        pixel_valid_i,
    input  wire [23:0] pixel_rgb_i,
    input  wire        frame_end_i,
    input  wire        frame_abort_i,
    input  wire [127:0] frame_metadata_i,
    output wire        udp_tx_req_o,
    output wire        udp_tx_valid_o,
    output wire [7:0]  udp_tx_data_o,
    output wire [15:0] udp_tx_length_o,
    input  wire        udp_tx_busy_i,
    output wire        fifo_overflow_o,
    output wire        fifo_underflow_o,
    output wire        frame_drop_o,
    output wire [15:0] completed_frame_id_o,
    output wire [15:0] completed_frame_count_o
);

    localparam [1:0]
        TOKEN_START = 2'b00,
        TOKEN_PIXEL = 2'b01,
        TOKEN_END   = 2'b10,
        TOKEN_ABORT = 2'b11;

    localparam [8:0]
        TX_STATE_WAIT_START = 9'b0_0000_0001,
        TX_STATE_FILL       = 9'b0_0000_0010,
        TX_STATE_REQUEST    = 9'b0_0000_0100,
        TX_STATE_WAIT_BUSY  = 9'b0_0000_1000,
        TX_STATE_SEND       = 9'b0_0001_0000,
        TX_STATE_WAIT_DONE  = 9'b0_0010_0000,
        TX_STATE_DROP       = 9'b0_0100_0000,
        TX_STATE_RECOVER    = 9'b0_1000_0000,
        TX_STATE_WAIT_METADATA = 9'b1_0000_0000;

    localparam [17:0] FRAME_PIXELS = 18'd230400;
    localparam [9:0]  PACKET_PIXELS = 10'd640;
    localparam [9:0]  LAST_PACKET_PIXELS = 10'd640;
    localparam [15:0] PACKET_IMAGE_BYTES = 16'd1280;
    localparam [15:0] LAST_PACKET_IMAGE_BYTES = 16'd1280;
    localparam [15:0] PACKET_TOTAL_BYTES = 16'd1304;
    localparam [15:0] LAST_PACKET_TOTAL_BYTES = 16'd1304;
    localparam [15:0] LAST_PACKET_ID = 16'd359;

    reg [17:0] fifo_write_data_reg = 18'd0;
    reg        fifo_write_enable_reg = 1'b0;
    reg        source_active_reg = 1'b0;
    reg        pending_abort_reg = 1'b0;
    reg        pending_end_reg = 1'b0;
    reg [17:0] source_pixel_count_reg = 18'd0;
    reg        frame_drop_reg = 1'b0;

    wire       fifo_write_full;
    wire       fifo_write_almost_full;
    wire       fifo_write_overflow;
    wire [17:0] fifo_read_data;
    wire       fifo_read_valid;
    wire       fifo_read_empty;
    wire       fifo_read_underflow;
    reg        fifo_read_enable_reg = 1'b0;

    reg [15:0] packet_memory[0:639];
    reg [8:0]  tx_state_reg = TX_STATE_WAIT_START;
    reg        fifo_read_pending_reg = 1'b0;
    reg [17:0] frame_pixel_count_reg = 18'd0;
    reg [9:0]  packet_pixel_count_reg = 10'd0;
    reg [15:0] frame_id_reg = 16'd0;
    reg [15:0] packet_id_reg = 16'd0;
    reg [15:0] packet_image_bytes_reg = 16'd0;
    reg [15:0] udp_length_reg = 16'd0;
    reg        packet_last_reg = 1'b0;
    reg        udp_request_reg = 1'b0;
    reg [15:0] send_byte_count_reg = 16'd0;
    reg [9:0]  send_pixel_index_reg = 10'd0;
    reg [1:0]  send_color_phase_reg = 2'd0;
    reg [15:0] completed_frame_id_reg = 16'd0;
    reg [15:0] completed_frame_count_reg = 16'd0;
    reg [7:0]  udp_data_reg = 8'd0;

    reg [127:0] metadata_write_reg = 128'd0;
    reg metadata_write_enable_reg = 1'b0;
    reg metadata_read_enable_reg = 1'b0;
    reg [127:0] frame_metadata_reg = 128'd0;
    wire metadata_full;
    wire metadata_read_valid;
    wire [127:0] metadata_read_data;
    stereo_metadata_fifo metadata_fifo_inst (
        .clk_write (clk_pixel), .rst_write (rst_pixel),
        .clk_read (clk_udp), .rst_read (rst_udp),
        .write_data_i (metadata_write_reg),
        .write_enable_i (metadata_write_enable_reg),
        .write_full_o (metadata_full), .write_almost_full_o (),
        .write_level_o (), .write_overflow_o (),
        .read_data_o (metadata_read_data),
        .read_enable_i (metadata_read_enable_reg),
        .read_valid_o (metadata_read_valid), .read_empty_o (),
        .read_level_o (), .read_underflow_o ()
    );
    wire [1:0]  fifo_token_type;
    wire [15:0] fifo_token_pixel;
    wire [15:0] send_pixel;
    wire        packet_first;

    assign fifo_token_type  = fifo_read_data[17:16];
    assign fifo_token_pixel = fifo_read_data[15:0];
    assign send_pixel       = packet_memory[send_pixel_index_reg];
    assign packet_first     = packet_id_reg == 16'd0;

    assign udp_tx_req_o             = udp_request_reg;
    assign udp_tx_valid_o           = tx_state_reg == TX_STATE_SEND;
    assign udp_tx_data_o            = udp_data_reg;
    assign udp_tx_length_o          = udp_length_reg;
    assign fifo_overflow_o          = fifo_write_overflow;
    assign fifo_underflow_o         = fifo_read_underflow;
    assign frame_drop_o             = frame_drop_reg;
    assign completed_frame_id_o     = completed_frame_id_reg;
    assign completed_frame_count_o  = completed_frame_count_reg;

    video_udp_async_fifo #(
        .DATA_WIDTH          (18),
        .ADDR_WIDTH          (FIFO_ADDR_WIDTH),
        .ALMOST_FULL_MARGIN  (8)
    )
    video_udp_async_fifo_inst (
        .clk_write           (clk_pixel),
        .rst_write           (rst_pixel),
        .clk_read            (clk_udp),
        .rst_read            (rst_udp),
        .write_data_i        (fifo_write_data_reg),
        .write_enable_i      (fifo_write_enable_reg),
        .write_full_o        (fifo_write_full),
        .write_almost_full_o (fifo_write_almost_full),
        .write_level_o       (),
        .write_overflow_o    (fifo_write_overflow),
        .read_data_o         (fifo_read_data),
        .read_enable_i       (fifo_read_enable_reg),
        .read_valid_o        (fifo_read_valid),
        .read_empty_o        (fifo_read_empty),
        .read_level_o        (),
        .read_underflow_o    (fifo_read_underflow)
    );

    // Pixel-domain frame writer. Almost-full causes a whole-frame abort token;
    // no truncated frame is ever followed by a normal end marker.
    always @(posedge clk_pixel) begin
        fifo_write_enable_reg <= 1'b0;
        metadata_write_enable_reg <= 1'b0;
        frame_drop_reg        <= 1'b0;

        if (frame_abort_i) begin
            pending_end_reg <= 1'b0;
            if (source_active_reg) begin
                source_active_reg <= 1'b0;
                frame_drop_reg    <= 1'b1;
                if (!fifo_write_full) begin
                    fifo_write_enable_reg <= 1'b1;
                    fifo_write_data_reg   <= {TOKEN_ABORT, 16'd0};
                    pending_abort_reg     <= 1'b0;
                end else begin
                    pending_abort_reg <= 1'b1;
                end
            end
        end else if (pending_abort_reg) begin
            if (!fifo_write_full) begin
                fifo_write_enable_reg <= 1'b1;
                fifo_write_data_reg   <= {TOKEN_ABORT, 16'd0};
                pending_abort_reg     <= 1'b0;
            end
        end else if (pending_end_reg) begin
            if (!fifo_write_full) begin
                fifo_write_enable_reg <= 1'b1;
                fifo_write_data_reg   <= {TOKEN_END, 16'd0};
                pending_end_reg       <= 1'b0;
                source_active_reg     <= 1'b0;
            end
        end else if (frame_start_i) begin
            source_pixel_count_reg <= 18'd0;
            if (!source_active_reg && !fifo_write_almost_full
                && !fifo_write_full && !metadata_full) begin
                metadata_write_reg <= frame_metadata_i;
                metadata_write_enable_reg <= 1'b1;
                fifo_write_enable_reg <= 1'b1;
                fifo_write_data_reg   <= {TOKEN_START, 16'd0};
                source_active_reg     <= 1'b1;
            end else begin
                source_active_reg <= 1'b0;
                frame_drop_reg    <= 1'b1;
                if (source_active_reg) begin
                    pending_abort_reg <= 1'b1;
                end
            end
        end else if (pixel_valid_i && source_active_reg) begin
            if ((source_pixel_count_reg < FRAME_PIXELS)
                && !fifo_write_almost_full && !fifo_write_full) begin
                fifo_write_enable_reg   <= 1'b1;
                fifo_write_data_reg     <= {TOKEN_PIXEL, pixel_rgb_i[23:19], pixel_rgb_i[15:10], pixel_rgb_i[7:3]};
                source_pixel_count_reg  <= source_pixel_count_reg + 18'd1;
                if ((source_pixel_count_reg == FRAME_PIXELS - 18'd1)
                    && frame_end_i) begin
                    pending_end_reg <= 1'b1;
                end
            end else begin
                source_active_reg <= 1'b0;
                pending_abort_reg <= 1'b1;
                pending_end_reg   <= 1'b0;
                frame_drop_reg    <= 1'b1;
            end
        end else if (frame_end_i && source_active_reg) begin
            if (source_pixel_count_reg == FRAME_PIXELS) begin
                pending_end_reg <= 1'b1;
            end else begin
                source_active_reg <= 1'b0;
                pending_abort_reg <= 1'b1;
                frame_drop_reg    <= 1'b1;
            end
        end

        if (rst_pixel) begin
            metadata_write_reg <= 128'd0;
            metadata_write_enable_reg <= 1'b0;
            fifo_write_data_reg      <= 18'd0;
            fifo_write_enable_reg    <= 1'b0;
            source_active_reg        <= 1'b0;
            pending_abort_reg        <= 1'b0;
            pending_end_reg          <= 1'b0;
            source_pixel_count_reg   <= 18'd0;
            frame_drop_reg           <= 1'b0;
        end
    end

    // UDP data is combinational from registered packet state and remains stable
    // for the full cycle in which udp_tx_valid_o is asserted.
    always @* begin
        udp_data_reg = 8'd0;
        if (tx_state_reg == TX_STATE_SEND) begin
            case (send_byte_count_reg)
                16'd0: udp_data_reg = frame_id_reg[15:8];
                16'd1: udp_data_reg = frame_id_reg[7:0];
                16'd2: udp_data_reg = packet_id_reg[15:8];
                16'd3: udp_data_reg = packet_id_reg[7:0];
                16'd4: udp_data_reg = packet_image_bytes_reg[15:8];
                16'd5: udp_data_reg = packet_image_bytes_reg[7:0];
                16'd6: udp_data_reg = {6'd0, packet_last_reg, packet_first};
                16'd7: udp_data_reg = 8'h03;
                default: begin
                    if (send_byte_count_reg < 16'd24) begin
                        udp_data_reg = frame_metadata_reg[
                            127 - ((send_byte_count_reg - 16'd8) << 3) -: 8];
                    end else case (send_color_phase_reg)
                        2'd0: udp_data_reg = send_pixel[15:8];
                        2'd1: udp_data_reg = send_pixel[7:0];
                        default: udp_data_reg = 8'd0;
                    endcase
                end
            endcase
        end
    end

    // Ethernet-domain token parser, packet buffer, and uiudp_stack handshake.
    always @(posedge clk_udp) begin
        fifo_read_enable_reg <= 1'b0;
        udp_request_reg      <= 1'b0;
        metadata_read_enable_reg <= 1'b0;
        if (metadata_read_valid && tx_state_reg == TX_STATE_WAIT_METADATA) begin
            frame_metadata_reg <= metadata_read_data;
            tx_state_reg <= TX_STATE_FILL;
        end

        if ((tx_state_reg == TX_STATE_WAIT_START
             || tx_state_reg == TX_STATE_FILL
             || tx_state_reg == TX_STATE_DROP)
            && !fifo_read_pending_reg && !fifo_read_empty) begin
            fifo_read_enable_reg  <= 1'b1;
            fifo_read_pending_reg <= 1'b1;
        end

        if (fifo_read_valid) begin
            fifo_read_pending_reg <= 1'b0;
            case (tx_state_reg)
                TX_STATE_WAIT_START: begin
                    if (fifo_token_type == TOKEN_START) begin
                        frame_pixel_count_reg  <= 18'd0;
                        packet_pixel_count_reg <= 10'd0;
                        packet_id_reg          <= 16'd0;
                        packet_last_reg        <= 1'b0;
                        metadata_read_enable_reg <= 1'b1;
                        tx_state_reg           <= TX_STATE_WAIT_METADATA;
                    end
                end
                TX_STATE_FILL: begin
                    case (fifo_token_type)
                        TOKEN_PIXEL: begin
                            if ((frame_pixel_count_reg < FRAME_PIXELS)
                                && (packet_pixel_count_reg < PACKET_PIXELS)) begin
                                packet_memory[packet_pixel_count_reg]
                                    <= fifo_token_pixel;
                                frame_pixel_count_reg
                                    <= frame_pixel_count_reg + 18'd1;
                                packet_pixel_count_reg
                                    <= packet_pixel_count_reg + 10'd1;
                                if (packet_pixel_count_reg
                                    == PACKET_PIXELS - 10'd1
                                    && frame_pixel_count_reg != FRAME_PIXELS - 18'd1) begin
                                    packet_image_bytes_reg
                                        <= PACKET_IMAGE_BYTES;
                                    udp_length_reg  <= PACKET_TOTAL_BYTES;
                                    packet_last_reg <= 1'b0;
                                    tx_state_reg    <= TX_STATE_REQUEST;
                                end
                            end else begin
                                tx_state_reg <= TX_STATE_DROP;
                            end
                        end
                        TOKEN_END: begin
                            if ((frame_pixel_count_reg == FRAME_PIXELS)
                                && (packet_pixel_count_reg
                                    == LAST_PACKET_PIXELS)
                                && (packet_id_reg == LAST_PACKET_ID)) begin
                                packet_image_bytes_reg
                                    <= LAST_PACKET_IMAGE_BYTES;
                                udp_length_reg  <= LAST_PACKET_TOTAL_BYTES;
                                packet_last_reg <= 1'b1;
                                tx_state_reg    <= TX_STATE_REQUEST;
                            end else begin
                                tx_state_reg <= TX_STATE_DROP;
                            end
                        end
                        TOKEN_ABORT: begin
                            tx_state_reg <= TX_STATE_WAIT_START;
                        end
                        TOKEN_START: begin
                            metadata_read_enable_reg <= 1'b1;
                            tx_state_reg <= TX_STATE_WAIT_METADATA;
                            packet_last_reg <= 1'b0;
                            frame_pixel_count_reg  <= 18'd0;
                            packet_pixel_count_reg <= 10'd0;
                            packet_id_reg          <= 16'd0;
                        end
                        default: begin
                            tx_state_reg <= TX_STATE_DROP;
                        end
                    endcase
                end
                TX_STATE_DROP: begin
                    if (fifo_token_type == TOKEN_START) begin
                        frame_pixel_count_reg  <= 18'd0;
                        packet_pixel_count_reg <= 10'd0;
                        packet_id_reg          <= 16'd0;
                        packet_last_reg        <= 1'b0;
                        metadata_read_enable_reg <= 1'b1;
                        tx_state_reg           <= TX_STATE_WAIT_METADATA;
                    end else if (fifo_token_type == TOKEN_ABORT
                                 || fifo_token_type == TOKEN_END) begin
                        tx_state_reg <= TX_STATE_WAIT_START;
                    end
                end
                default: begin
                    tx_state_reg <= TX_STATE_RECOVER;
                end
            endcase
        end

        case (tx_state_reg)
            TX_STATE_REQUEST: begin
                if (!udp_tx_busy_i) begin
                    udp_request_reg <= 1'b1;
                    tx_state_reg    <= TX_STATE_WAIT_BUSY;
                end
            end
            TX_STATE_WAIT_BUSY: begin
                if (udp_tx_busy_i) begin
                    send_byte_count_reg  <= 16'd0;
                    send_pixel_index_reg <= 10'd0;
                    send_color_phase_reg <= 2'd0;
                    tx_state_reg         <= TX_STATE_SEND;
                end
            end
            TX_STATE_SEND: begin
                if (send_byte_count_reg == udp_length_reg - 16'd1) begin
                    tx_state_reg <= TX_STATE_WAIT_DONE;
                end else begin
                    send_byte_count_reg <= send_byte_count_reg + 16'd1;
                    if (send_byte_count_reg >= 16'd24) begin
                        if (send_color_phase_reg == 2'd1) begin
                            send_color_phase_reg <= 2'd0;
                            send_pixel_index_reg
                                <= send_pixel_index_reg + 10'd1;
                        end else begin
                            send_color_phase_reg
                                <= send_color_phase_reg + 2'd1;
                        end
                    end
                end
            end
            TX_STATE_WAIT_DONE: begin
                if (!udp_tx_busy_i) begin
                    if (packet_last_reg) begin
                        completed_frame_id_reg
                            <= frame_id_reg;
                        completed_frame_count_reg
                            <= completed_frame_count_reg + 16'd1;
                        frame_id_reg <= frame_id_reg + 16'd1;
                        tx_state_reg <= TX_STATE_WAIT_START;
                    end else begin
                        packet_id_reg
                            <= packet_id_reg + 16'd1;
                        packet_pixel_count_reg <= 10'd0;
                        tx_state_reg <= TX_STATE_FILL;
                    end
                end
            end
            TX_STATE_RECOVER: begin
                tx_state_reg <= TX_STATE_WAIT_START;
            end
            default: begin
            end
        endcase

        if (rst_udp) begin
            metadata_read_enable_reg <= 1'b0;
            frame_metadata_reg <= 128'd0;
            tx_state_reg                  <= TX_STATE_WAIT_START;
            fifo_read_enable_reg          <= 1'b0;
            fifo_read_pending_reg         <= 1'b0;
            frame_pixel_count_reg         <= 18'd0;
            packet_pixel_count_reg        <= 10'd0;
            frame_id_reg                  <= 16'd0;
            packet_id_reg                 <= 16'd0;
            packet_image_bytes_reg        <= 16'd0;
            udp_length_reg                <= 16'd0;
            packet_last_reg               <= 1'b0;
            udp_request_reg               <= 1'b0;
            send_byte_count_reg           <= 16'd0;
            send_pixel_index_reg          <= 10'd0;
            send_color_phase_reg          <= 2'd0;
            completed_frame_id_reg        <= 16'd0;
            completed_frame_count_reg     <= 16'd0;
        end
    end

endmodule

`resetall
