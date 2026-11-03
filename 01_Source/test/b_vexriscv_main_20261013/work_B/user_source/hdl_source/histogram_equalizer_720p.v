// -----------------------------------------------------------------------------
// Streaming 8-bit histogram equalizer for 1280x720 video.
//
// A frame histogram is collected in one 20-Kbit ERAM.  During vertical blank
// the 256-bin CDF is converted into an 8-bit lookup table in a second ERAM and
// the histogram is cleared for the next frame.  Frame N is therefore displayed
// with the mapping calculated from frame N-1; the first frame is passed through.
// -----------------------------------------------------------------------------
module histogram_equalizer_720p #(
    parameter integer IMG_WIDTH  = 1280,
    parameter integer IMG_HEIGHT = 720
)(
    input  wire       I_clk,
    input  wire       I_rst_n,
    input  wire       I_vsync,
    input  wire       I_de,
    input  wire [7:0] I_img_y,

    output reg        O_vsync,
    output reg        O_de,
    output wire [7:0] O_img_y
);

    localparam [1:0] ST_CLEAR   = 2'd0;
    localparam [1:0] ST_COLLECT = 2'd1;
    localparam [1:0] ST_SCAN    = 2'd2;

    reg [1:0]  S_state;
    reg        S_vsync_d;
    reg [7:0]  S_img_y_d;
    reg        S_pixel_valid_d;

    reg [7:0]  S_clear_addr;
    reg [7:0]  S_scan_addr;
    reg [7:0]  S_scan_addr_d;
    reg        S_scan_valid_d;
    reg        S_scan_all_issued;
    reg [19:0] S_cdf_sum;
    reg        S_lut_valid;

    reg        S_last_hist_wr_en;
    reg [7:0]  S_last_hist_wr_addr;
    reg [19:0] S_last_hist_wr_data;

    wire       S_frame_boundary = I_vsync && !S_vsync_d;

    wire [7:0]  S_hist_rd_addr = (S_state == ST_SCAN) ? S_scan_addr : I_img_y;
    wire [19:0] S_hist_rd_data;
    wire        S_hist_collect_wr = (S_state == ST_COLLECT) && S_pixel_valid_d;
    wire [19:0] S_hist_inc_data =
        (S_last_hist_wr_en && (S_img_y_d == S_last_hist_wr_addr)) ?
        (S_last_hist_wr_data + 20'd1) : (S_hist_rd_data + 20'd1);

    wire        S_hist_clear_wr = (S_state == ST_CLEAR) ||
                                  ((S_state == ST_SCAN) && S_scan_valid_d);
    wire        S_hist_wr_en = S_hist_collect_wr || S_hist_clear_wr;
    wire [7:0]  S_hist_wr_addr = (S_state == ST_CLEAR) ? S_clear_addr :
                                 ((S_state == ST_SCAN) ? S_scan_addr_d : S_img_y_d);
    wire [19:0] S_hist_wr_data = S_hist_clear_wr ? 20'd0 : S_hist_inc_data;

    wire [20:0] S_cdf_next = {1'b0,S_cdf_sum} + {1'b0,S_hist_rd_data};

    // 255/921600 represented in Q28.  The coefficient 74275 gives less than
    // one output-code error and replaces a large constant divider with a DSP
    // friendly constant multiply.  Saturation preserves CDF(max)=255.
    wire [37:0] S_cdf_scaled = S_cdf_next * 17'd74275;
    wire [9:0]  S_cdf_level  = S_cdf_scaled[37:28];
    wire [7:0]  S_lut_wr_data = (S_cdf_level >= 10'd255) ?
                                8'hff : S_cdf_level[7:0];
    wire        S_lut_wr_en = (S_state == ST_SCAN) && S_scan_valid_d;
    wire [7:0]  S_lut_rd_data;

    assign O_img_y = S_lut_valid ? S_lut_rd_data : S_img_y_d;

    PH1P_LOGIC_ERAM #(
        .DATA_WIDTH_A          (20),
        .DATA_WIDTH_B          (20),
        .ADDR_WIDTH_A          (8),
        .ADDR_WIDTH_B          (8),
        .DATA_DEPTH_A          (256),
        .DATA_DEPTH_B          (256),
        .MODE                  ("DP"),
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
    ) u_histogram_eram (
        .dia           (20'd0),
        .dib           (S_hist_wr_data),
        .addra         (S_hist_rd_addr),
        .addrb         (S_hist_wr_addr),
        .cea           (1'b1),
        .ceb           (1'b1),
        .ocea          (1'b1),
        .oceb          (1'b0),
        .clka          (I_clk),
        .clkb          (I_clk),
        .wea           (1'b0),
        .web           (S_hist_wr_en),
        .bea           (1'b0),
        .beb           (1'b0),
        .rsta          (1'b0),
        .rstb          (1'b0),
        .ecc_sbiterr   (),
        .ecc_dbiterr   (),
        .ecc_sbiterrinj(1'b0),
        .ecc_dbiterrinj(1'b0),
        .doa           (S_hist_rd_data),
        .dob           ()
    );

    PH1P_LOGIC_ERAM #(
        .DATA_WIDTH_A          (8),
        .DATA_WIDTH_B          (8),
        .ADDR_WIDTH_A          (8),
        .ADDR_WIDTH_B          (8),
        .DATA_DEPTH_A          (256),
        .DATA_DEPTH_B          (256),
        .MODE                  ("DP"),
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
    ) u_equalize_lut_eram (
        .dia           (S_lut_wr_data),
        .dib           (8'd0),
        .addra         (S_scan_addr_d),
        .addrb         (I_img_y),
        .cea           (1'b1),
        .ceb           (1'b1),
        .ocea          (1'b0),
        .oceb          (1'b1),
        .clka          (I_clk),
        .clkb          (I_clk),
        .wea           (S_lut_wr_en),
        .web           (1'b0),
        .bea           (1'b0),
        .beb           (1'b0),
        .rsta          (1'b0),
        .rstb          (1'b0),
        .ecc_sbiterr   (),
        .ecc_dbiterr   (),
        .ecc_sbiterrinj(1'b0),
        .ecc_dbiterrinj(1'b0),
        .doa           (),
        .dob           (S_lut_rd_data)
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_state             <= ST_CLEAR;
            S_vsync_d           <= 1'b0;
            S_img_y_d           <= 8'd0;
            S_pixel_valid_d     <= 1'b0;
            S_clear_addr        <= 8'd0;
            S_scan_addr         <= 8'd0;
            S_scan_addr_d       <= 8'd0;
            S_scan_valid_d      <= 1'b0;
            S_scan_all_issued   <= 1'b0;
            S_cdf_sum           <= 20'd0;
            S_lut_valid         <= 1'b0;
            S_last_hist_wr_en   <= 1'b0;
            S_last_hist_wr_addr <= 8'd0;
            S_last_hist_wr_data <= 20'd0;
            O_vsync             <= 1'b0;
            O_de                <= 1'b0;
        end
        else begin
            S_vsync_d       <= I_vsync;
            S_img_y_d       <= I_img_y;
            S_pixel_valid_d <= I_de && (S_state == ST_COLLECT);
            O_vsync         <= I_vsync;
            O_de            <= I_de;

            S_last_hist_wr_en <= S_hist_collect_wr;
            if(S_hist_collect_wr) begin
                S_last_hist_wr_addr <= S_img_y_d;
                S_last_hist_wr_data <= S_hist_inc_data;
            end

            case(S_state)
                ST_CLEAR: begin
                    S_pixel_valid_d   <= 1'b0;
                    S_last_hist_wr_en <= 1'b0;
                    if(S_clear_addr == 8'hff) begin
                        S_clear_addr <= 8'd0;
                        S_state      <= ST_COLLECT;
                    end
                    else begin
                        S_clear_addr <= S_clear_addr + 8'd1;
                    end
                end

                ST_COLLECT: begin
                    S_scan_valid_d <= 1'b0;
                    if(S_frame_boundary) begin
                        S_scan_addr       <= 8'd0;
                        S_scan_addr_d     <= 8'd0;
                        S_scan_all_issued <= 1'b0;
                        S_cdf_sum         <= 20'd0;
                        S_state           <= ST_SCAN;
                    end
                end

                ST_SCAN: begin
                    S_pixel_valid_d   <= 1'b0;
                    S_last_hist_wr_en <= 1'b0;

                    if(!S_scan_all_issued) begin
                        S_scan_valid_d <= 1'b1;
                        S_scan_addr_d  <= S_scan_addr;
                        if(S_scan_addr == 8'hff)
                            S_scan_all_issued <= 1'b1;
                        else
                            S_scan_addr <= S_scan_addr + 8'd1;
                    end
                    else begin
                        S_scan_valid_d <= 1'b0;
                    end

                    if(S_scan_valid_d) begin
                        S_cdf_sum <= S_cdf_next[19:0];
                        if(S_scan_addr_d == 8'hff) begin
                            S_lut_valid <= 1'b1;
                            S_state     <= ST_COLLECT;
                        end
                    end
                end

                default: S_state <= ST_CLEAR;
            endcase
        end
    end

endmodule
