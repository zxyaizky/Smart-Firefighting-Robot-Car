// ============================================================================
// File Name   : npu_preproc.v
// Description : NPU 前端图像预处理链 wrapper.
//
//               链路:
//                  RGB888 (640x480, vsync+href 像流)
//                     │
//                     ▼  rgb2y          (OpenCV BT.601 BGR->Y)
//                     │
//                     ▼  img_downsampler (固定 4:1 resize 近似 -> 160x120)
//                     │
//                     ▼  lbp_extractor   (3x3 LBP, 与 webcam_inference 编码一致)
//                     │
//                     ▼  19200 字节/帧, 光栅顺序, 严格 1 拍 1 像素 valid
//                     │
//                  npu_core_top.{i_frame_valid, i_lbp_valid, i_lbp_pixel}
//
//               帧契约 (与 NPU 集成方案 §6.3 对齐):
//                 i_frame_valid: 在 1 帧 19200 个 LBP 像素期间持续高
//                                (本模块用 [LBP 第 1 个像素 .. 第 19200 个像素]
//                                 覆盖范围生成)。
//                 i_lbp_valid  : 单拍脉冲, 与 lbp_extractor.valid_out 对齐。
//                 i_lbp_pixel  : 8-bit LBP 字节。
// ============================================================================
module npu_preproc #(
    parameter SRC_W = 640,
    parameter SRC_H = 480,
    parameter DST_W = 160,
    parameter DST_H = 120,
    // Default to the legacy deployed input.  face_grid24_v2 binds this
    // explicitly from c_board_top: 0 = direct integer Y, 1 = LBP.
    parameter USE_LBP = 1'b1
)(
    input  wire        clk,
    input  wire        rst_n,

    // VIP 上游: RGB888 像流
    input  wire        vip_vsync,    // 帧起始下降沿 (低有效, 与 OV5640 风格一致;
                                     // 顶层若是高有效, 在外部取反后再接进来)
    input  wire        vip_pix_valid,// 像素有效 (对应 href & DE)
    input  wire [7:0]  vip_r,
    input  wire [7:0]  vip_g,
    input  wire [7:0]  vip_b,

    // 下游: NPU 前端
    output wire        o_frame_valid,
    output wire        o_lbp_valid,
    output wire [7:0]  o_lbp_pixel,

    // 调试: LBP 像素行列号 (来自 lbp_extractor)
    output wire [7:0]  o_lbp_x,
    output wire [7:0]  o_lbp_y
);

    localparam integer INPUT_FRAME_PIXELS = DST_W * DST_H;  // 19200

    // ------------------------------------------------------------------------
    // 1. RGB -> Y
    // ------------------------------------------------------------------------
    wire        y_valid;
    wire [7:0]  y_pixel;

    rgb2y u_rgb2y (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (vip_pix_valid),
        .r_in      (vip_r),
        .g_in      (vip_g),
        .b_in      (vip_b),
        .valid_out (y_valid),
        .y_out     (y_pixel)
    );

    // ------------------------------------------------------------------------
    // 2. 固定 4:1 resize 近似: 640x480 -> 160x120
    //    对每个 4x4 区块中心 2x2 灰度像素做四舍五入平均，
    //    对齐软件训练/推理路径中的 resize -> gray -> LBP。
    // ------------------------------------------------------------------------
    wire        ds_valid;
    wire [7:0]  ds_pixel;

    img_downsampler #(
        .IMG_W (SRC_W),
        .IMG_H (SRC_H)
    ) u_downsample (
        .clk       (clk),
        .rst_n     (rst_n),
        .pixel_in  (y_pixel),
        .valid_in  (y_valid),
        .pixel_out (ds_pixel),
        .valid_out (ds_valid)
    );

    // ------------------------------------------------------------------------
    // 3. LBP (3x3, padding=1) -> 与训练数据集 bit-true 一致的编码
    // ------------------------------------------------------------------------
    wire       lbp_valid;
    wire [7:0] lbp_pixel;
    wire [7:0] lbp_x, lbp_y;

    lbp_extractor #(
        .IMG_W (DST_W),
        .IMG_H (DST_H)
    ) u_lbp (
        .clk       (clk),
        .rst_n     (rst_n),
        .pixel_in  (ds_pixel),
        .valid_in  (ds_valid),
        .lbp_out   (lbp_pixel),
        .valid_out (lbp_valid),
        .out_x     (lbp_x),
        .out_y     (lbp_y)
    );

    // ------------------------------------------------------------------------
    // 4. Compile-time input representation selection.
    //
    // The NPU preload ABI keeps its historical o_lbp_* names.  In direct-Y
    // mode those ports carry the downsampled integer-Y raster byte-for-byte;
    // in LBP mode they carry the extractor output.  Both representations are
    // therefore driven by the same RGB565->RGB888->integer-Y->fixed-resize
    // board path used during training.
    // ------------------------------------------------------------------------
    reg [7:0] ds_x;
    reg [7:0] ds_y;

    wire       selected_valid = USE_LBP ? lbp_valid : ds_valid;
    wire [7:0] selected_pixel = USE_LBP ? lbp_pixel : ds_pixel;
    wire [7:0] selected_x     = USE_LBP ? lbp_x : ds_x;
    wire [7:0] selected_y     = USE_LBP ? lbp_y : ds_y;

    // ------------------------------------------------------------------------
    // 5. i_frame_valid 生成
    //
    //    定义: 当前帧第 1 个选定输入字节到达 (含) -> 第 19200 个到达 (含)
    //    期间持续高。两帧之间为低 (供 NPU sequencer 识别帧边界并完成 layer-9
    //    bbox 输出 + 复位前段 line_buffer)。
    //
    //    实现: 用一个 15-bit 计数器对 selected_valid 计数。
    //      - 计数 0~INPUT_FRAME_PIXELS-1: o_frame_valid = 1
    //      - 计数 == INPUT_FRAME_PIXELS: 被 vsync 下降沿清零回到 0
    //
    //    vsync 下降沿用同步检测; 不跨域 (假设 vsync 已经在 clk 域)。
    // ------------------------------------------------------------------------
    reg [14:0] input_cnt;        // 0..19200
    reg        frame_active;
    reg        vsync_d1;

    wire vsync_falling = vsync_d1 & ~vip_vsync;  // 高->低

    // ds_x/ds_y describe the current ds_valid byte.  Nonblocking updates make
    // the old coordinate visible for the same clock edge on which downstream
    // logic consumes ds_pixel, matching the extractor's raster convention.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ds_x <= 8'd0;
            ds_y <= 8'd0;
        end else if (vsync_falling) begin
            ds_x <= 8'd0;
            ds_y <= 8'd0;
        end else if (ds_valid) begin
            if (ds_x == DST_W - 1) begin
                ds_x <= 8'd0;
                if (ds_y == DST_H - 1)
                    ds_y <= 8'd0;
                else
                    ds_y <= ds_y + 8'd1;
            end else begin
                ds_x <= ds_x + 8'd1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            input_cnt      <= 15'd0;
            frame_active <= 1'b0;
            vsync_d1     <= 1'b1;
        end else begin
            vsync_d1 <= vip_vsync;

            if (vsync_falling) begin
                // 帧起始: 重置计数, 等第 1 个 selected_valid 再拉 frame_active
                input_cnt      <= 15'd0;
                frame_active <= 1'b0;
            end else if (selected_valid) begin
                if (input_cnt == INPUT_FRAME_PIXELS - 1) begin
                    // 收齐 19200, 关闭 frame_active 等下一帧
                    input_cnt      <= INPUT_FRAME_PIXELS[14:0];
                    frame_active <= 1'b0;
                end else begin
                    input_cnt      <= input_cnt + 15'd1;
                    frame_active <= 1'b1;
                end
            end
        end
    end

    // 帧内: selected_valid 首拍也拉高 o_frame_valid (覆盖第一个字节)。
    assign o_frame_valid = frame_active | (selected_valid & (input_cnt < INPUT_FRAME_PIXELS));
    assign o_lbp_valid   = selected_valid & (input_cnt < INPUT_FRAME_PIXELS);
    assign o_lbp_pixel   = selected_pixel;
    assign o_lbp_x       = selected_x;
    assign o_lbp_y       = selected_y;

endmodule
