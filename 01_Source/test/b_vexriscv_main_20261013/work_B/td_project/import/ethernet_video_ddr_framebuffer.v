// -----------------------------------------------------------------------------
// File   : ethernet_video_ddr_framebuffer.v
// Author : Codex
// Date   : 2026-10-22
// Description:
//   Complete-frame RGB565 double buffer in the reserved video DDR window.
//   Native addresses count 16-bit words. Banks start at physical 16/16.5 MiB.
//   Read each source row twice and each pixel twice for a 1280x720 raster.
//   Ordered FIFO frame markers drain old responses across display boundaries.
// Change Log:
//   2026-10-23  Codex  v1.2  Reuse held data and banked metadata; narrow counters.
//   2026-10-22  Codex  v1.0  Ethernet framebuffer sharing the video DDR port.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module ethernet_video_ddr_framebuffer #
(
    // Source dimensions; output raster is twice each dimension.
    parameter integer FRAME_WIDTH = 640,
    parameter integer FRAME_HEIGHT = 360,
    // Two 512 KiB slots, entirely below physical 32 MiB / Linux memory.
    parameter [24:0] NATIVE_BASE = 25'h0800000,
    parameter [24:0] BANK_STRIDE = 25'h0040000,
    // Elastic FIFOs store a few scanlines, not complete frames.
    parameter integer FIFO_ADDR_WIDTH = 8
)
(
    input  wire         clk_pixel,
    input  wire         rst_pixel,
    input  wire         clk_ddr,
    input  wire         rst_ddr,
    // Keep VS/DE aligned for the source switch, but do not use DDR off-screen.
    input  wire         display_enable_i,
    input  wire         frame_start_i,
    input  wire         pixel_valid_i,
    input  wire [23:0]  pixel_rgb_i,
    input  wire         frame_end_i,
    input  wire         frame_abort_i,
    input  wire [127:0] frame_metadata_i,
    input  wire         vsync_i,
    input  wire         de_i,
    output wire         vsync_o,
    output wire         de_o,
    output wire [23:0]  rgb_o,
    output wire         active_o,
    output wire         metadata_update_o,
    output wire [127:0] metadata_o,
    output wire         display_error_o,
    output wire         ddr_valid_o,
    output wire         ddr_write_o,
    output wire [24:0]  ddr_addr_o,
    output wire [127:0] ddr_data_o,
    input  wire         ddr_ready_i,
    input  wire         ddr_rvalid_i,
    input  wire [127:0] ddr_rdata_i
);
    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer FRAME_BEATS = FRAME_PIXELS / 8;
    localparam integer ROW_BEATS = FRAME_WIDTH / 8;
    localparam integer FIFO_DEPTH = 1 << FIFO_ADDR_WIDTH;
    localparam integer WRITE_COUNT_WIDTH = $clog2(FRAME_BEATS + 1);
    localparam integer ROW_COUNT_WIDTH = FRAME_HEIGHT > 1 ? $clog2(FRAME_HEIGHT) : 1;
    localparam integer WORD_COUNT_WIDTH = ROW_BEATS > 1 ? $clog2(ROW_BEATS) : 1;
    localparam [1:0] TOK_START = 2'd0, TOK_DATA = 2'd1,
                     TOK_END = 2'd2, TOK_ABORT = 2'd3;

    wire [15:0] input_rgb565;
    wire pixel_engine_reset = rst_pixel || !display_enable_i;
    (* async_reg = "true" *) reg [1:0] display_enable_ddr_sync_reg = 2'b00;
    wire ddr_engine_reset = rst_ddr || !display_enable_ddr_sync_reg[1];
    always @(posedge clk_ddr) begin
        if (rst_ddr) display_enable_ddr_sync_reg <= 2'b00;
        else display_enable_ddr_sync_reg <=
            {display_enable_ddr_sync_reg[0], display_enable_i};
    end
    reg [1:0] upload_type_reg = TOK_START;
    wire [129:0] upload_write_data;
    reg upload_enable_reg = 1'b0;
    wire upload_full, upload_almost_full, upload_empty, upload_valid;
    wire [129:0] upload_data;
    wire upload_read;
    reg capture_reg = 1'b0;
    reg abort_pending_reg = 1'b0, end_pending_reg = 1'b0;
    reg [17:0] pixel_count_reg = 18'd0;
    reg [2:0] pack_count_reg = 3'd0;
    reg [127:0] pack_reg = 128'd0;

    reg upload_pending_reg = 1'b0;
    reg write_active_reg = 1'b0, write_bank_reg = 1'b1;
    reg [WRITE_COUNT_WIDTH-1:0] write_count_reg = {WRITE_COUNT_WIDTH{1'b0}};
    reg write_valid_reg = 1'b0;
    reg pending_frame_reg = 1'b0, pending_bank_reg = 1'b0;
    reg display_bank_reg = 1'b0, display_valid_reg = 1'b0;
    // A committed bank owns its metadata until that bank is reusable.
    (* ramstyle = "no_rw_check", ram_style = "dram" *)
    reg [127:0] metadata_banks[0:1];
    wire [127:0] bank_metadata;
    wire metadata_bank;

    reg vsync_pixel_reg = 1'b0, frame_toggle_reg = 1'b0;
    (* async_reg = "true" *) reg [1:0] frame_toggle_sync_reg = 2'b00;
    reg frame_toggle_seen_reg = 1'b0;
    reg frame_request_reg = 1'b0;
    wire frame_event;
    reg reader_active_reg = 1'b0;
    reg [ROW_COUNT_WIDTH-1:0] read_row_reg = {ROW_COUNT_WIDTH{1'b0}};
    reg [WORD_COUNT_WIDTH-1:0] read_word_reg = {WORD_COUNT_WIDTH{1'b0}};
    reg read_repeat_reg = 1'b0;
    reg [24:0] row_base_reg = 25'd0;
    reg [FIFO_ADDR_WIDTH:0] outstanding_reg = {(FIFO_ADDR_WIDTH+1){1'b0}};
    wire can_read;
    wire read_accept, write_accept;

    reg command_valid_reg = 1'b0, command_write_reg = 1'b0;
    reg [24:0] command_addr_reg = 25'd0;
    reg prefer_write_reg = 1'b0;
    wire download_enable;
    wire [129:0] download_write_data;
    wire emit_download_start;
    wire download_full, download_empty, download_valid;
    wire [129:0] download_data;
    wire [FIFO_ADDR_WIDTH:0] download_level;
    wire download_read;

    reg seeking_reg = 1'b1, seeking_next;
    reg raster_started_reg = 1'b0, raster_started_next;
    reg display_bad_reg = 1'b1, display_bad_next;
    reg active_reg = 1'b0, active_next;
    reg download_pending_reg = 1'b0, download_pending_next;
    reg current_valid_reg = 1'b0, current_valid_next;
    reg next_valid_reg = 1'b0, next_valid_next;
    reg [127:0] current_word_reg = 128'd0, current_word_next;
    reg [3:0] phase_reg = 4'd0, phase_next;
    reg [127:0] metadata_reg = 128'd0, metadata_next;
    reg metadata_update_reg = 1'b0, metadata_update_next;
    reg display_error_reg = 1'b0, display_error_next;
    reg [23:0] rgb_reg = 24'd0, rgb_next;
    reg de_reg = 1'b0, vsync_reg = 1'b0;
    wire [15:0] display_rgb565;

    assign input_rgb565 = {pixel_rgb_i[23:19], pixel_rgb_i[15:10], pixel_rgb_i[7:3]};
    assign upload_read = !upload_empty && !upload_pending_reg && !write_valid_reg;
    assign frame_event = frame_toggle_sync_reg[1] != frame_toggle_seen_reg;
    assign can_read = reader_active_reg && !frame_request_reg && !frame_event &&
        ({1'b0, download_level} + {1'b0, outstanding_reg} < FIFO_DEPTH - 8);
    assign read_accept = command_valid_reg && ddr_ready_i && !command_write_reg;
    assign write_accept = command_valid_reg && ddr_ready_i && command_write_reg;
    assign ddr_valid_o = command_valid_reg;
    assign ddr_write_o = command_write_reg;
    assign ddr_addr_o = command_addr_reg;
    // upload_read is blocked until this held DATA token has been written.
    assign ddr_data_o = command_write_reg ? upload_data[127:0] : 128'd0;
    assign upload_write_data = {upload_type_reg, pack_reg};
    assign metadata_bank = pending_frame_reg ? pending_bank_reg : display_bank_reg;
    assign bank_metadata = metadata_banks[metadata_bank];
    assign emit_download_start = frame_request_reg && outstanding_reg == 0 &&
        !command_valid_reg && !download_full && download_level < FIFO_DEPTH - 8;
    // The owner-tagged DDR return is already registered in the DDR interface.
    // With no outstanding old reads, START cannot collide with a DATA return.
    assign download_enable = !ddr_engine_reset &&
        (ddr_rvalid_i || emit_download_start);
    assign download_write_data = ddr_rvalid_i ? {TOK_DATA, ddr_rdata_i} :
        ((pending_frame_reg || display_valid_reg) ? {TOK_START, bank_metadata} :
                                                   {TOK_ABORT, 128'd0});
    assign download_read = !download_empty && !download_pending_reg &&
        (seeking_reg || !current_valid_reg || !next_valid_reg);
    assign display_rgb565 = current_word_reg[{phase_reg[3:1], 4'b0000} +: 16];
    assign vsync_o = vsync_reg;
    assign de_o = de_reg;
    assign rgb_o = rgb_reg;
    assign active_o = active_reg;
    assign metadata_o = metadata_reg;
    assign metadata_update_o = metadata_update_reg;
    assign display_error_o = display_error_reg;

    video_udp_async_fifo #(.DATA_WIDTH(130), .ADDR_WIDTH(FIFO_ADDR_WIDTH),
        .ALMOST_FULL_MARGIN(4)) upload_fifo_inst (
        .clk_write(clk_pixel), .rst_write(pixel_engine_reset),
        .clk_read(clk_ddr), .rst_read(ddr_engine_reset),
        .write_data_i(upload_write_data), .write_enable_i(upload_enable_reg),
        .write_full_o(upload_full), .write_almost_full_o(upload_almost_full),
        .write_level_o(), .write_overflow_o(), .read_data_o(upload_data),
        .read_enable_i(upload_read), .read_valid_o(upload_valid),
        .read_empty_o(upload_empty), .read_level_o(), .read_underflow_o()
    );
    video_udp_async_fifo #(.DATA_WIDTH(130), .ADDR_WIDTH(FIFO_ADDR_WIDTH),
        .ALMOST_FULL_MARGIN(4)) download_fifo_inst (
        .clk_write(clk_ddr), .rst_write(ddr_engine_reset),
        .clk_read(clk_pixel), .rst_read(pixel_engine_reset),
        .write_data_i(download_write_data), .write_enable_i(download_enable),
        .write_full_o(download_full), .write_almost_full_o(),
        .write_level_o(download_level), .write_overflow_o(), .read_data_o(download_data),
        .read_enable_i(download_read), .read_valid_o(download_valid),
        .read_empty_o(download_empty), .read_level_o(), .read_underflow_o()
    );

    // Eight RGB565 pixels per DDR beat. Overflow discards the entire incoming frame.
    always @(posedge clk_pixel) begin
        upload_enable_reg <= 1'b0;
        if (abort_pending_reg && !upload_full) begin
            upload_enable_reg <= 1'b1;
            upload_type_reg <= TOK_ABORT;
            abort_pending_reg <= 1'b0;
        end else if (end_pending_reg && !upload_full) begin
            upload_enable_reg <= 1'b1;
            upload_type_reg <= TOK_END;
            end_pending_reg <= 1'b0;
        end else if (frame_start_i) begin
            capture_reg <= !upload_almost_full && !upload_full;
            pixel_count_reg <= 18'd0;
            pack_count_reg <= 3'd0;
            if (!upload_almost_full && !upload_full) begin
                upload_enable_reg <= 1'b1;
                upload_type_reg <= TOK_START;
                pack_reg <= frame_metadata_i;
            end
        end else if (capture_reg && pixel_valid_i) begin
            if (pixel_count_reg < FRAME_PIXELS && !upload_almost_full) begin
                pack_reg <= {input_rgb565, pack_reg[127:16]};
                pack_count_reg <= pack_count_reg + 1'b1;
                pixel_count_reg <= pixel_count_reg + 1'b1;
                if (pack_count_reg == 3'd7) begin
                    upload_enable_reg <= 1'b1;
                    upload_type_reg <= TOK_DATA;
                end
            end else begin
                capture_reg <= 1'b0;
                abort_pending_reg <= 1'b1;
            end
        end
        if (frame_end_i && capture_reg) begin
            capture_reg <= 1'b0;
            if (pixel_count_reg == FRAME_PIXELS && pack_count_reg == 3'd0)
                end_pending_reg <= 1'b1;
            else abort_pending_reg <= 1'b1;
        end
        if (frame_abort_i) begin
            if (capture_reg) abort_pending_reg <= 1'b1;
            capture_reg <= 1'b0;
            end_pending_reg <= 1'b0;
        end
        vsync_pixel_reg <= vsync_i;
        if (vsync_i && !vsync_pixel_reg) frame_toggle_reg <= !frame_toggle_reg;
        if (pixel_engine_reset) begin
            upload_enable_reg <= 1'b0;
            capture_reg <= 1'b0;
            abort_pending_reg <= 1'b0;
            end_pending_reg <= 1'b0;
            pixel_count_reg <= 18'd0;
            pack_count_reg <= 3'd0;
            vsync_pixel_reg <= 1'b0;
            frame_toggle_reg <= 1'b0;
        end
    end

    // A frame becomes pending only after every write was accepted by the arbiter.
    // Bank ownership changes only at a display request after old reads have drained.
    always @(posedge clk_ddr) begin
        frame_toggle_sync_reg <= {frame_toggle_sync_reg[0], frame_toggle_reg};
        if (frame_event) begin
            frame_toggle_seen_reg <= frame_toggle_sync_reg[1];
            frame_request_reg <= 1'b1;
            reader_active_reg <= 1'b0;
        end
        if (upload_read) upload_pending_reg <= 1'b1;
        if (upload_valid) begin
            upload_pending_reg <= 1'b0;
            case (upload_data[129:128])
                TOK_START: begin
                    write_active_reg <= !pending_frame_reg;
                    write_bank_reg <= !display_bank_reg;
                    write_count_reg <= {WRITE_COUNT_WIDTH{1'b0}};
                    if (!pending_frame_reg && !ddr_engine_reset)
                        metadata_banks[!display_bank_reg] <= upload_data[127:0];
                end
                TOK_DATA: begin
                    if (write_active_reg && write_count_reg < FRAME_BEATS) begin
                        write_valid_reg <= 1'b1;
                    end else write_active_reg <= 1'b0;
                end
                TOK_END: begin
                    if (write_active_reg && write_count_reg == FRAME_BEATS) begin
                        pending_frame_reg <= 1'b1;
                        pending_bank_reg <= write_bank_reg;
                    end
                    write_active_reg <= 1'b0;
                end
                default: write_active_reg <= 1'b0;
            endcase
        end
        if (!command_valid_reg) begin
            if (write_valid_reg && (prefer_write_reg || !can_read)) begin
                command_valid_reg <= 1'b1;
                command_write_reg <= 1'b1;
                command_addr_reg <= NATIVE_BASE + (write_bank_reg ? BANK_STRIDE : 25'd0)
                    + {{(22-WRITE_COUNT_WIDTH){1'b0}}, write_count_reg, 3'd0};
            end else if (can_read) begin
                command_valid_reg <= 1'b1;
                command_write_reg <= 1'b0;
                command_addr_reg <= row_base_reg + {{(22-WORD_COUNT_WIDTH){1'b0}}, read_word_reg, 3'd0};
            end
        end
        if (write_accept) begin
            command_valid_reg <= 1'b0;
            write_valid_reg <= 1'b0;
            write_count_reg <= write_count_reg + 1'b1;
            prefer_write_reg <= 1'b0;
        end
        if (read_accept) begin
            command_valid_reg <= 1'b0;
            prefer_write_reg <= 1'b1;
            if (read_word_reg == ROW_BEATS - 1) begin
                read_word_reg <= {WORD_COUNT_WIDTH{1'b0}};
                read_repeat_reg <= !read_repeat_reg;
                if (read_repeat_reg) begin
                    row_base_reg <= row_base_reg + FRAME_WIDTH;
                    read_row_reg <= read_row_reg + 1'b1;
                    if (read_row_reg == FRAME_HEIGHT - 1) reader_active_reg <= 1'b0;
                end
            end else read_word_reg <= read_word_reg + 1'b1;
        end
        case ({read_accept, ddr_rvalid_i})
            2'b10: outstanding_reg <= outstanding_reg + 1'b1;
            2'b01: outstanding_reg <= outstanding_reg - 1'b1;
            default: outstanding_reg <= outstanding_reg;
        endcase
        if (emit_download_start) begin
            frame_request_reg <= 1'b0;
            read_word_reg <= {WORD_COUNT_WIDTH{1'b0}};
            read_row_reg <= {ROW_COUNT_WIDTH{1'b0}};
            read_repeat_reg <= 1'b0;
            reader_active_reg <= pending_frame_reg || display_valid_reg;
            if (pending_frame_reg) begin
                display_valid_reg <= 1'b1;
                display_bank_reg <= pending_bank_reg;
                pending_frame_reg <= 1'b0;
            end
            row_base_reg <= NATIVE_BASE +
                ((pending_frame_reg ? pending_bank_reg : display_bank_reg) ? BANK_STRIDE : 25'd0);
        end
        if (ddr_engine_reset) begin
            frame_toggle_sync_reg <= 2'b00;
            frame_toggle_seen_reg <= 1'b0;
            frame_request_reg <= 1'b0;
            upload_pending_reg <= 1'b0;
            write_active_reg <= 1'b0;
            write_bank_reg <= 1'b1;
            write_count_reg <= {WRITE_COUNT_WIDTH{1'b0}};
            write_valid_reg <= 1'b0;
            pending_frame_reg <= 1'b0;
            display_bank_reg <= 1'b0;
            display_valid_reg <= 1'b0;
            reader_active_reg <= 1'b0;
            outstanding_reg <= {(FIFO_ADDR_WIDTH+1){1'b0}};
            command_valid_reg <= 1'b0;
            prefer_write_reg <= 1'b0;
            end
    end

    // Two-word elastic prefetch hides the asynchronous FIFO's registered read.
    // On underflow, black the rest of this raster; never shift subsequent pixels.
    always @* begin
        seeking_next = seeking_reg;
        raster_started_next = raster_started_reg;
        display_bad_next = display_bad_reg;
        active_next = active_reg;
        download_pending_next = download_pending_reg;
        current_valid_next = current_valid_reg;
        next_valid_next = next_valid_reg;
        current_word_next = current_word_reg;
        phase_next = phase_reg;
        metadata_next = metadata_reg;
        metadata_update_next = 1'b0;
        display_error_next = 1'b0;
        rgb_next = 24'd0;
        if (download_read) download_pending_next = 1'b1;
        if (de_i) begin
            raster_started_next = 1'b1;
            if (active_reg && !display_bad_reg && !seeking_reg && current_valid_reg) begin
                rgb_next = {display_rgb565[15:11], display_rgb565[15:13],
                    display_rgb565[10:5], display_rgb565[10:9],
                    display_rgb565[4:0], display_rgb565[4:2]};
                phase_next = phase_reg + 1'b1;
                if (phase_reg == 4'd15) begin
                    // The FIFO output itself is the prefetched word; do not pop
                    // another token while next_valid_reg owns that output.
                    current_word_next = download_data[127:0];
                    current_valid_next = next_valid_reg;
                    next_valid_next = 1'b0;
                end
            end else if (active_reg && !display_bad_reg) begin
                display_bad_next = 1'b1;
                display_error_next = 1'b1;
            end
        end
        if (vsync_i && !vsync_pixel_reg) begin
            seeking_next = 1'b1;
            raster_started_next = 1'b0;
            display_bad_next = 1'b1;
            current_valid_next = 1'b0;
            next_valid_next = 1'b0;
            phase_next = 4'd0;
        end
        if (download_valid) begin
            download_pending_next = 1'b0;
            if (download_data[129:128] != TOK_DATA) begin
                if (seeking_next && !raster_started_next) begin
                    seeking_next = 1'b0;
                    active_next = download_data[129:128] == TOK_START;
                    display_bad_next = 1'b0;
                    metadata_next = download_data[127:0];
                    metadata_update_next = 1'b1;
                    current_valid_next = 1'b0;
                    next_valid_next = 1'b0;
                    phase_next = 4'd0;
                end
            end else if (!seeking_next && !display_bad_next) begin
                if (!current_valid_next) begin
                    current_word_next = download_data[127:0];
                    current_valid_next = 1'b1;
                end else begin
                    next_valid_next = 1'b1;
                end
            end
        end
    end
    always @(posedge clk_pixel) begin
        seeking_reg <= seeking_next;
        raster_started_reg <= raster_started_next;
        display_bad_reg <= display_bad_next;
        active_reg <= active_next;
        download_pending_reg <= download_pending_next;
        current_valid_reg <= current_valid_next;
        next_valid_reg <= next_valid_next;
        current_word_reg <= current_word_next;
        phase_reg <= phase_next;
        metadata_reg <= metadata_next;
        metadata_update_reg <= metadata_update_next;
        display_error_reg <= display_error_next;
        rgb_reg <= rgb_next;
        de_reg <= de_i;
        vsync_reg <= vsync_i;
        if (pixel_engine_reset) begin
            seeking_reg <= 1'b1;
            raster_started_reg <= 1'b0;
            display_bad_reg <= 1'b1;
            active_reg <= 1'b0;
            download_pending_reg <= 1'b0;
            current_valid_reg <= 1'b0;
            next_valid_reg <= 1'b0;
            phase_reg <= 4'd0;
            metadata_reg <= 128'd0;
            metadata_update_reg <= 1'b0;
            display_error_reg <= 1'b0;
            rgb_reg <= 24'd0;
            // The local-video path still needs the registered timing signals.
            de_reg <= rst_pixel ? 1'b0 : de_i;
            vsync_reg <= rst_pixel ? 1'b0 : vsync_i;
        end
    end
endmodule
`resetall
