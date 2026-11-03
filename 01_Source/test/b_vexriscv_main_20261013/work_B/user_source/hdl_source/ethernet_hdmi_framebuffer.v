`timescale 1ns / 1ps

// Buffers complete 160x120 RGB888 frames received over UDP and renders them
// on the existing 1280x720 HDMI raster.  The 8x6 integer scale keeps the
// network input independent from the complete MIPI camera pipeline.
module ethernet_hdmi_framebuffer (
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_net_frame_start,
    input  wire        I_net_pixel_valid,
    input  wire [23:0] I_net_pixel_rgb,
    input  wire        I_net_frame_end,
    input  wire        I_net_frame_abort,

    input  wire        I_hdmi_vsync,
    input  wire        I_hdmi_de,

    output wire        O_hdmi_vsync,
    output wire        O_hdmi_de,
    output wire [23:0] O_hdmi_rgb,
    output reg         O_network_active
);

    localparam [14:0] FRAME_PIXELS = 15'd19200;
    localparam [14:0] LAST_ROW_BASE = 15'd19040;

    reg        write_bank;
    reg        read_bank;
    reg        pending_bank;
    reg        pending_frame;
    reg        capture_active;
    reg        capture_overflow;
    reg [14:0] write_count;

    reg        hdmi_vsync_d;
    reg        hdmi_de_d;
    reg [2:0]  horizontal_repeat;
    reg [2:0]  vertical_repeat;
    reg [7:0]  source_x;
    reg [14:0] source_row_base;
    reg        read_bank_d;

    wire [15:0] input_rgb565;
    wire [15:0] frame0_read_rgb565;
    wire [15:0] frame1_read_rgb565;
    wire [15:0] read_rgb565;
    wire        frame_write_enable;
    wire        hdmi_vsync_rise;
    wire [14:0] read_address;

    assign input_rgb565 = {
        I_net_pixel_rgb[23:19],
        I_net_pixel_rgb[15:10],
        I_net_pixel_rgb[7:3]
    };
    assign hdmi_vsync_rise = I_hdmi_vsync && !hdmi_vsync_d;
    assign read_address = source_row_base + source_x;
    assign frame_write_enable = I_net_pixel_valid && capture_active
                                && (write_count < FRAME_PIXELS);
    assign read_rgb565 = read_bank_d ? frame1_read_rgb565
                                     : frame0_read_rgb565;

    // Each bank is 160x120 RGB565.  The helper below explicitly divides it
    // over nineteen 20-Kbit ERAM primitives so this device's synthesis tool
    // cannot accidentally implement the frame stores in LUT RAM.
    ethernet_hdmi_frame_bank u_frame_bank0 (
        .I_clk     (I_clk),
        .I_rd_addr (read_address),
        .O_rd_data (frame0_read_rgb565),
        .I_wr_en   (frame_write_enable && !write_bank),
        .I_wr_addr (write_count),
        .I_wr_data (input_rgb565)
    );

    ethernet_hdmi_frame_bank u_frame_bank1 (
        .I_clk     (I_clk),
        .I_rd_addr (read_address),
        .O_rd_data (frame1_read_rgb565),
        .I_wr_en   (frame_write_enable && write_bank),
        .I_wr_addr (write_count),
        .I_wr_data (input_rgb565)
    );

    // Both the UDP pixel stream and HDMI timing are in I_clk.  A complete
    // network frame is committed only at an HDMI frame boundary.  A new frame
    // is discarded while an earlier completed frame is waiting to be shown,
    // preventing either display bank from being overwritten.
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            write_bank        <= 1'b1;
            read_bank         <= 1'b0;
            pending_bank      <= 1'b0;
            pending_frame     <= 1'b0;
            capture_active    <= 1'b0;
            capture_overflow  <= 1'b0;
            write_count       <= 15'd0;
            hdmi_vsync_d      <= 1'b0;
            hdmi_de_d         <= 1'b0;
            horizontal_repeat <= 3'd0;
            vertical_repeat   <= 3'd0;
            source_x          <= 8'd0;
            source_row_base   <= 15'd0;
            read_bank_d       <= 1'b0;
            O_network_active  <= 1'b0;
        end else begin
            hdmi_vsync_d <= I_hdmi_vsync;
            hdmi_de_d    <= I_hdmi_de;
            read_bank_d  <= read_bank;

            if (hdmi_vsync_rise) begin
                horizontal_repeat <= 3'd0;
                vertical_repeat   <= 3'd0;
                source_x          <= 8'd0;
                source_row_base   <= 15'd0;

                if (pending_frame) begin
                    read_bank        <= pending_bank;
                    pending_frame    <= 1'b0;
                    O_network_active <= 1'b1;
                end
            end else begin
                // Generate 160x120 source coordinates without multipliers or
                // dividers: repeat pixels eight times and lines six times.
                if (I_hdmi_de) begin
                    if (horizontal_repeat == 3'd7) begin
                        horizontal_repeat <= 3'd0;
                        if (source_x == 8'd159)
                            source_x <= 8'd0;
                        else
                            source_x <= source_x + 8'd1;
                    end else begin
                        horizontal_repeat <= horizontal_repeat + 3'd1;
                    end
                end

                // First blanking clock after an active line.
                if (hdmi_de_d && !I_hdmi_de) begin
                    horizontal_repeat <= 3'd0;
                    source_x          <= 8'd0;

                    if (vertical_repeat == 3'd5) begin
                        vertical_repeat <= 3'd0;
                        if (source_row_base < LAST_ROW_BASE)
                            source_row_base <= source_row_base + 15'd160;
                    end else begin
                        vertical_repeat <= vertical_repeat + 3'd1;
                    end
                end
            end

            if (I_net_frame_start) begin
                write_count      <= 15'd0;
                capture_overflow <= 1'b0;
                capture_active   <= !pending_frame
                                    && (write_bank != read_bank);
            end

            if (I_net_pixel_valid && capture_active) begin
                if (write_count < FRAME_PIXELS) begin
                    write_count <= write_count + 15'd1;
                end else begin
                    capture_overflow <= 1'b1;
                end
            end

            if (I_net_frame_abort) begin
                capture_active <= 1'b0;
                write_count    <= 15'd0;
            end else if (I_net_frame_end) begin
                if (capture_active && !capture_overflow
                    && (write_count == FRAME_PIXELS)) begin
                    pending_bank  <= write_bank;
                    pending_frame <= 1'b1;
                    write_bank    <= ~write_bank;
                end
                capture_active <= 1'b0;
            end
        end
    end

    assign O_hdmi_vsync = hdmi_vsync_d;
    assign O_hdmi_de    = hdmi_de_d;
    assign O_hdmi_rgb   = {
        read_rgb565[15:11], read_rgb565[15:13],
        read_rgb565[10:5],  read_rgb565[10:9],
        read_rgb565[4:0],   read_rgb565[4:2]
    };

endmodule

// One 19200x16 frame bank.  Nineteen 1024x16 ERAMs cover 19456 addresses;
// addresses 19200..19455 are intentionally unused.
module ethernet_hdmi_frame_bank (
    input  wire        I_clk,
    input  wire [14:0] I_rd_addr,
    output reg  [15:0] O_rd_data,
    input  wire        I_wr_en,
    input  wire [14:0] I_wr_addr,
    input  wire [15:0] I_wr_data
);

    wire [303:0] bank_rd_data;
    reg  [4:0]   rd_bank;

    always @(posedge I_clk)
        rd_bank <= I_rd_addr[14:10];

    always @(*) begin
        case (rd_bank)
            5'd0:  O_rd_data = bank_rd_data[15:0];
            5'd1:  O_rd_data = bank_rd_data[31:16];
            5'd2:  O_rd_data = bank_rd_data[47:32];
            5'd3:  O_rd_data = bank_rd_data[63:48];
            5'd4:  O_rd_data = bank_rd_data[79:64];
            5'd5:  O_rd_data = bank_rd_data[95:80];
            5'd6:  O_rd_data = bank_rd_data[111:96];
            5'd7:  O_rd_data = bank_rd_data[127:112];
            5'd8:  O_rd_data = bank_rd_data[143:128];
            5'd9:  O_rd_data = bank_rd_data[159:144];
            5'd10: O_rd_data = bank_rd_data[175:160];
            5'd11: O_rd_data = bank_rd_data[191:176];
            5'd12: O_rd_data = bank_rd_data[207:192];
            5'd13: O_rd_data = bank_rd_data[223:208];
            5'd14: O_rd_data = bank_rd_data[239:224];
            5'd15: O_rd_data = bank_rd_data[255:240];
            5'd16: O_rd_data = bank_rd_data[271:256];
            5'd17: O_rd_data = bank_rd_data[287:272];
            default: O_rd_data = bank_rd_data[303:288];
        endcase
    end

    genvar bank_index;
    generate
        for (bank_index = 0; bank_index < 19; bank_index = bank_index + 1) begin : G_frame_eram
            PH1P_LOGIC_ERAM #(
                .DATA_WIDTH_A          (16),
                .DATA_WIDTH_B          (16),
                .ADDR_WIDTH_A          (10),
                .ADDR_WIDTH_B          (10),
                .DATA_DEPTH_A          (1024),
                .DATA_DEPTH_B          (1024),
                .MODE                  ("PDPW"),
                .REGMODE_A             ("NOREG"),
                .REGMODE_B             ("NOREG"),
                .WRITEMODE_A           ("NORMAL"),
                .WRITEMODE_B           ("NORMAL"),
                .IMPLEMENT             ("20K(FAST)"),
                .ECC_ENCODE            ("DISABLE"),
                .ECC_DECODE            ("DISABLE"),
                .CLKMODE               ("SYNC"),
                .SSROVERCE             ("DISABLE"),
                .OREGSET_A             ("RESET"),
                .OREGSET_B             ("RESET"),
                .RESETMODE_A           ("ASYNC"),
                .RESETMODE_B           ("ASYNC"),
                .ASYNC_RESET_RELEASE_A ("ASYNC"),
                .ASYNC_RESET_RELEASE_B ("ASYNC"),
                .INIT_FILE             ("NONE"),
                .FILL_ALL              ("NONE")
            ) u_eram (
                .dia            (I_wr_data),
                .dib            (16'd0),
                .addra          (I_wr_addr[9:0]),
                .addrb          (I_rd_addr[9:0]),
                .cea            (1'b1),
                .ceb            (1'b1),
                .ocea           (1'b0),
                .oceb           (1'b1),
                .clka           (I_clk),
                .clkb           (I_clk),
                .wea            (I_wr_en && (I_wr_addr[14:10] == bank_index)),
                .web            (1'b0),
                .bea            (1'b0),
                .beb            (1'b0),
                .rsta           (1'b0),
                .rstb           (1'b0),
                .ecc_sbiterr    (),
                .ecc_dbiterr    (),
                .ecc_sbiterrinj (1'b0),
                .ecc_dbiterrinj (1'b0),
                .doa            (),
                .dob            (bank_rd_data[(bank_index*16) +: 16])
            );
        end
    endgenerate

endmodule
