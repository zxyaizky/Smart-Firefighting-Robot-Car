// -----------------------------------------------------------------------------
// Coarse block-based frame-difference motion detector for a 1280x720 stream.
//
// The image is averaged in 8x8 blocks.  One 160x90 gray frame and one 160x90
// binary mask are retained in embedded RAM, avoiding another external-DDR read
// port.  Detection results are intentionally displayed one frame later so that
// the bounding box, block mask and count remain stable for a complete frame.
// -----------------------------------------------------------------------------
module motion_frame_diff #(
    parameter integer IMG_WIDTH          = 1280,
    parameter integer IMG_HEIGHT         = 720,
    parameter integer BLOCK_SHIFT        = 3,
    parameter [7:0]   DIFF_THRESHOLD     = 8'd12,
    parameter [14:0]  MIN_MOTION_BLOCKS  = 15'd12
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_frame_vsync,
    input  wire        I_frame_de,
    input  wire [7:0]  I_img_y,

    output reg         O_frame_vsync,
    output reg         O_frame_de,
    output reg  [23:0] O_motion_rgb,
    output reg  [23:0] O_diff_rgb,
    output reg         O_motion_active,
    output reg  [15:0] O_motion_count,
    output reg  [19:0] O_motion_count_bcd
);

    localparam integer BLOCK_WIDTH  = IMG_WIDTH  >> BLOCK_SHIFT;
    localparam integer BLOCK_HEIGHT = IMG_HEIGHT >> BLOCK_SHIFT;
    localparam integer BLOCK_COUNT  = BLOCK_WIDTH * BLOCK_HEIGHT;

    reg [13:0] S_block_accum   [0:BLOCK_WIDTH-1];

    reg         S_vsync_d;
    reg         S_seen_frame;
    reg         S_history_valid;
    reg [10:0]  S_x;
    reg [9:0]   S_y;
    reg [10:0]  S_x_d;
    reg [9:0]   S_y_d;
    reg [7:0]   S_pixel_y_d;
    reg [10:0]  S_row_sum;
    wire        S_mask_display;

    reg         S_sample_valid;
    reg [13:0]  S_sample_addr;
    reg [7:0]   S_sample_bx;
    reg [6:0]   S_sample_by;
    reg [7:0]   S_sample_average;
    reg [7:0]   S_sample_previous;
    reg         S_sample_ignore;

    reg [14:0]  S_motion_count_work;
    reg         S_bbox_work_valid;
    reg [7:0]   S_bbox_min_bx;
    reg [7:0]   S_bbox_max_bx;
    reg [6:0]   S_bbox_min_by;
    reg [6:0]   S_bbox_max_by;

    reg [10:0]  S_bbox_min_x;
    reg [10:0]  S_bbox_max_x;
    reg [9:0]   S_bbox_min_y;
    reg [9:0]   S_bbox_max_y;

    wire        S_frame_start;
    wire [7:0]  S_block_x;
    wire [6:0]  S_block_y;
    wire [13:0] S_display_addr;
    wire [11:0] S_row_sum_plus;
    wire [15:0] S_block_total;
    wire [7:0]  S_block_average;
    wire        S_block_complete;
    wire [7:0]  S_sample_diff;
    wire        S_sample_motion;
    wire [8:0]  S_frame_store_rd_data;
    wire        S_frame_store_wr_en;
    wire [8:0]  S_frame_store_wr_data;

    assign S_frame_start = I_frame_vsync && !S_vsync_d;
    assign S_block_x = S_x >> BLOCK_SHIFT;
    assign S_block_y = S_y >> BLOCK_SHIFT;
    assign S_display_addr = (S_block_y * BLOCK_WIDTH) + S_block_x;

    assign S_row_sum_plus = {1'b0, S_row_sum} + {4'd0, I_img_y};
    assign S_block_total = {2'd0, S_block_accum[S_block_x]} +
                           {4'd0, S_row_sum_plus};
    assign S_block_average = S_block_total >> (2 * BLOCK_SHIFT);
    assign S_block_complete = I_frame_de &&
                              (&S_x[BLOCK_SHIFT-1:0]) &&
                              (&S_y[BLOCK_SHIFT-1:0]);

    assign S_sample_diff = (S_sample_average >= S_sample_previous) ?
                           (S_sample_average - S_sample_previous) :
                           (S_sample_previous - S_sample_average);
    assign S_sample_motion = S_history_valid && !S_sample_ignore &&
                             (S_sample_diff >= DIFF_THRESHOLD);

    assign S_frame_store_wr_en   = !S_frame_start && S_sample_valid;
    assign S_frame_store_wr_data = {S_sample_motion, S_sample_average};
    assign S_mask_display        = S_history_valid && O_frame_de &&
                                   S_frame_store_rd_data[8];

    // Ignore the pre-processing OSD rectangles.  The final-stage logo is not
    // present in this stream, while changing status digits could look like
    // motion.  Ranges are rounded to 8x8 blocks.
    function F_ignore_block;
        input [10:0] I_x_end;
        input [9:0]  I_y_end;
        begin
            F_ignore_block =
                ((I_x_end >= 11'd1088) && (I_x_end < 11'd1272) &&
                 (I_y_end >= 10'd640) && (I_y_end < 10'd712)) ||
                ((I_x_end >= 11'd368) && (I_x_end < 11'd584) &&
                 (I_y_end >= 10'd112) && (I_y_end < 10'd152));
        end
    endfunction

    // One 9-bit word per 8x8 block: {last-frame motion mask, last-frame luma}.
    // The explicit store uses eight 20-Kbit embedded-RAM blocks so the 160x90
    // history cannot be silently implemented as distributed LUT RAM.
    motion_frame_store u_motion_frame_store (
        .I_clk      (I_clk),
        .I_rd_addr  (S_display_addr),
        .O_rd_data  (S_frame_store_rd_data),
        .I_wr_en    (S_frame_store_wr_en),
        .I_wr_addr  (S_sample_addr),
        .I_wr_data  (S_frame_store_wr_data)
    );

    function [19:0] F_binary_to_bcd5;
        input [14:0] I_binary;
        integer i;
        reg [34:0] S_shift;
        begin
            S_shift = 35'd0;
            S_shift[14:0] = I_binary;
            for(i = 0; i < 15; i = i + 1) begin
                if(S_shift[18:15] >= 4'd5)
                    S_shift[18:15] = S_shift[18:15] + 4'd3;
                if(S_shift[22:19] >= 4'd5)
                    S_shift[22:19] = S_shift[22:19] + 4'd3;
                if(S_shift[26:23] >= 4'd5)
                    S_shift[26:23] = S_shift[26:23] + 4'd3;
                if(S_shift[30:27] >= 4'd5)
                    S_shift[30:27] = S_shift[30:27] + 4'd3;
                if(S_shift[34:31] >= 4'd5)
                    S_shift[34:31] = S_shift[34:31] + 4'd3;
                S_shift = S_shift << 1;
            end
            F_binary_to_bcd5 = S_shift[34:15];
        end
    endfunction

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_vsync_d             <= 1'b0;
            S_seen_frame          <= 1'b0;
            S_history_valid       <= 1'b0;
            S_x                   <= 11'd0;
            S_y                   <= 10'd0;
            S_x_d                 <= 11'd0;
            S_y_d                 <= 10'd0;
            S_pixel_y_d           <= 8'd0;
            S_row_sum             <= 11'd0;
            S_sample_valid        <= 1'b0;
            S_sample_addr         <= 14'd0;
            S_sample_bx           <= 8'd0;
            S_sample_by           <= 7'd0;
            S_sample_average      <= 8'd0;
            S_sample_previous     <= 8'd0;
            S_sample_ignore       <= 1'b0;
            S_motion_count_work   <= 15'd0;
            S_bbox_work_valid     <= 1'b0;
            S_bbox_min_bx         <= 8'd0;
            S_bbox_max_bx         <= 8'd0;
            S_bbox_min_by         <= 7'd0;
            S_bbox_max_by         <= 7'd0;
            S_bbox_min_x          <= 11'd0;
            S_bbox_max_x          <= 11'd0;
            S_bbox_min_y          <= 10'd0;
            S_bbox_max_y          <= 10'd0;
            O_frame_vsync         <= 1'b0;
            O_frame_de            <= 1'b0;
            O_motion_active       <= 1'b0;
            O_motion_count        <= 16'd0;
            O_motion_count_bcd    <= 20'd0;
        end
        else begin
            S_vsync_d     <= I_frame_vsync;
            O_frame_vsync <= I_frame_vsync;
            O_frame_de    <= I_frame_de;
            S_pixel_y_d   <= I_img_y;
            S_x_d         <= S_x;
            S_y_d         <= S_y;

            S_sample_valid <= 1'b0;

            if(S_frame_start) begin
                S_x       <= 11'd0;
                S_y       <= 10'd0;
                S_row_sum <= 11'd0;

                S_seen_frame    <= 1'b1;
                if(S_seen_frame)
                    S_history_valid <= 1'b1;

                O_motion_count     <= {1'b0, S_motion_count_work};
                O_motion_count_bcd <= F_binary_to_bcd5(S_motion_count_work);

                if(S_bbox_work_valid &&
                   (S_motion_count_work >= MIN_MOTION_BLOCKS)) begin
                    O_motion_active <= 1'b1;
                    S_bbox_min_x <= S_bbox_min_bx << BLOCK_SHIFT;
                    S_bbox_max_x <= (S_bbox_max_bx << BLOCK_SHIFT) |
                                    ((1 << BLOCK_SHIFT) - 1);
                    S_bbox_min_y <= S_bbox_min_by << BLOCK_SHIFT;
                    S_bbox_max_y <= (S_bbox_max_by << BLOCK_SHIFT) |
                                    ((1 << BLOCK_SHIFT) - 1);
                end
                else begin
                    O_motion_active <= 1'b0;
                    S_bbox_min_x <= 11'd0;
                    S_bbox_max_x <= 11'd0;
                    S_bbox_min_y <= 10'd0;
                    S_bbox_max_y <= 10'd0;
                end

                S_motion_count_work <= 15'd0;
                S_bbox_work_valid   <= 1'b0;
            end
            else if(I_frame_de) begin
                if(S_x == (IMG_WIDTH - 1)) begin
                    S_x <= 11'd0;
                    if(S_y == (IMG_HEIGHT - 1))
                        S_y <= 10'd0;
                    else
                        S_y <= S_y + 10'd1;
                end
                else begin
                    S_x <= S_x + 11'd1;
                end

                if(S_x[BLOCK_SHIFT-1:0] == {BLOCK_SHIFT{1'b0}})
                    S_row_sum <= {3'd0, I_img_y};
                else if(&S_x[BLOCK_SHIFT-1:0])
                    S_row_sum <= 11'd0;
                else
                    S_row_sum <= S_row_sum_plus[10:0];

                if(&S_x[BLOCK_SHIFT-1:0]) begin
                    if(S_y[BLOCK_SHIFT-1:0] == {BLOCK_SHIFT{1'b0}})
                        S_block_accum[S_block_x] <= S_row_sum_plus;
                    else if(&S_y[BLOCK_SHIFT-1:0])
                        S_block_accum[S_block_x] <= 14'd0;
                    else
                        S_block_accum[S_block_x] <=
                            S_block_accum[S_block_x] + S_row_sum_plus;
                end

                if(S_block_complete) begin
                    S_sample_valid    <= 1'b1;
                    S_sample_addr     <= S_display_addr;
                    S_sample_bx       <= S_block_x;
                    S_sample_by       <= S_block_y;
                    S_sample_average  <= S_block_average;
                    S_sample_previous <= S_frame_store_rd_data[7:0];
                    S_sample_ignore   <= F_ignore_block(S_x, S_y);
                end
            end

            if(!S_frame_start && S_sample_valid) begin
                if(S_sample_motion) begin
                    if(S_motion_count_work != 15'h7fff)
                        S_motion_count_work <= S_motion_count_work + 15'd1;

                    if(!S_bbox_work_valid) begin
                        S_bbox_work_valid <= 1'b1;
                        S_bbox_min_bx <= S_sample_bx;
                        S_bbox_max_bx <= S_sample_bx;
                        S_bbox_min_by <= S_sample_by;
                        S_bbox_max_by <= S_sample_by;
                    end
                    else begin
                        if(S_sample_bx < S_bbox_min_bx)
                            S_bbox_min_bx <= S_sample_bx;
                        if(S_sample_bx > S_bbox_max_bx)
                            S_bbox_max_bx <= S_sample_bx;
                        if(S_sample_by < S_bbox_min_by)
                            S_bbox_min_by <= S_sample_by;
                        if(S_sample_by > S_bbox_max_by)
                            S_bbox_max_by <= S_sample_by;
                    end
                end
            end
        end
    end

    always @(*) begin
        O_motion_rgb = 24'd0;
        O_diff_rgb   = 24'd0;

        if(O_frame_de) begin
            O_motion_rgb = {S_pixel_y_d, S_pixel_y_d, S_pixel_y_d};
            O_diff_rgb   = S_mask_display ? 24'hffffff : 24'h000000;

            if(O_motion_active && S_mask_display)
                O_motion_rgb = 24'hff8000;
        end
    end

endmodule

// -----------------------------------------------------------------------------
// 16384 x 9 simple dual-port frame store built from eight PH1P 20-Kbit ERAMs.
// Port A writes one completed block; port B continuously reads the display block.
// -----------------------------------------------------------------------------
module motion_frame_store (
    input  wire        I_clk,
    input  wire [13:0] I_rd_addr,
    output reg  [8:0]  O_rd_data,
    input  wire        I_wr_en,
    input  wire [13:0] I_wr_addr,
    input  wire [8:0]  I_wr_data
);

    wire [71:0] S_bank_rd_data;
    reg  [2:0]  S_rd_bank;

    always @(posedge I_clk)
        S_rd_bank <= I_rd_addr[13:11];

    always @(*) begin
        case(S_rd_bank)
            3'd0: O_rd_data = S_bank_rd_data[8:0];
            3'd1: O_rd_data = S_bank_rd_data[17:9];
            3'd2: O_rd_data = S_bank_rd_data[26:18];
            3'd3: O_rd_data = S_bank_rd_data[35:27];
            3'd4: O_rd_data = S_bank_rd_data[44:36];
            3'd5: O_rd_data = S_bank_rd_data[53:45];
            3'd6: O_rd_data = S_bank_rd_data[62:54];
            default: O_rd_data = S_bank_rd_data[71:63];
        endcase
    end

    genvar G_bank;
    generate
        for(G_bank = 0; G_bank < 8; G_bank = G_bank + 1) begin : G_motion_eram
            PH1P_LOGIC_ERAM #(
                .DATA_WIDTH_A          (9),
                .DATA_WIDTH_B          (9),
                .ADDR_WIDTH_A          (11),
                .ADDR_WIDTH_B          (11),
                .DATA_DEPTH_A          (2048),
                .DATA_DEPTH_B          (2048),
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
                .dia          (I_wr_data),
                .dib          (9'd0),
                .addra        (I_wr_addr[10:0]),
                .addrb        (I_rd_addr[10:0]),
                .cea          (1'b1),
                .ceb          (1'b1),
                .ocea         (1'b0),
                .oceb         (1'b1),
                .clka         (I_clk),
                .clkb         (I_clk),
                .wea          (I_wr_en && (I_wr_addr[13:11] == G_bank)),
                .web          (1'b0),
                .bea          (1'b0),
                .beb          (1'b0),
                .rsta         (1'b0),
                .rstb         (1'b0),
                .ecc_sbiterr  (),
                .ecc_dbiterr  (),
                .ecc_sbiterrinj(1'b0),
                .ecc_dbiterrinj(1'b0),
                .doa          (),
                .dob          (S_bank_rd_data[(G_bank*9) +: 9])
            );
        end
    endgenerate

endmodule
