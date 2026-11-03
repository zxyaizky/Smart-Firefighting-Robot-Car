`timescale 1ns/1ps
module tb_npu_result_overlay;
    reg clk_npu = 0, clk_video = 0;
    always #5 clk_npu = ~clk_npu;
    always #2 clk_video = ~clk_video;
    reg rst_n_npu = 0, rst_n_video = 0;
    reg model_ready = 0, error_flag = 0, tensor_valid = 0;
    reg [63:0] tensor_data = 0;
    reg inference_done = 0, video_vsync = 0, video_de = 0;
    reg [23:0] video_data = 24'h123456;
    wire out_vsync, out_de;
    wire [23:0] out_data;
    integer failures = 0;

    npu_result_overlay #(.NPU_CLK_HZ(32)) dut (
        .clk_npu(clk_npu), .rst_n_npu(rst_n_npu),
        .i_model_ready(model_ready), .i_error(error_flag),
        .i_tensor_valid(tensor_valid), .i_tensor_data(tensor_data),
        .i_inference_done(inference_done), .i_debug_flags(8'd0), .clk_video(clk_video),
        .rst_n_video(rst_n_video), .i_video_vsync(video_vsync),
        .i_video_de(video_de), .i_video_data(video_data),
        .o_video_vsync(out_vsync), .o_video_de(out_de), .o_video_data(out_data));

    task send_result;
        input [7:0] gx, gy, fire, obj;
        input [7:0] w, h;
        begin
            @(negedge clk_npu);
            tensor_data = {gy,gx,fire,h,w,8'd128,8'd128,obj};
            tensor_valid = 1;
            @(negedge clk_npu);
            tensor_valid = 0;
            inference_done = 1;
            @(negedge clk_npu);
            inference_done = 0;
            repeat (8) @(posedge clk_video);
            #1;
            if (dut.active_result_reg !== tensor_data) begin
                $display("FAIL winner bytes/coordinates did not cross CDC");
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk_video);
        rst_n_npu = 1; rst_n_video = 1; model_ready = 1;
        send_result(8'd10,8'd7,8'd128,8'd128,8'd40,8'd32);
        if (!dut.active_detect_reg || dut.box_x0 !== 11'd572 ||
            dut.box_x1 !== 11'd773 || dut.box_y0 !== 10'd300 ||
            dut.box_y1 !== 10'd420) begin
            $display("FAIL fire threshold or cell-local bbox: %d,%d,%d,%d",
                     dut.box_x0,dut.box_y0,dut.box_x1,dut.box_y1);
            failures = failures + 1;
        end
        if (dut.active_fire !== 8'd128 || dut.active_gx !== 8'd10 ||
            dut.active_gy !== 8'd7 || dut.active_dx !== 8'd128)
            failures = failures + 1;
        send_result(8'd10,8'd7,8'd127,8'd255,8'd40,8'd32);
        if (dut.active_detect_reg) begin
            $display("FAIL fire below threshold detected"); failures = failures + 1;
        end
        send_result(8'd10,8'd7,8'd255,8'd127,8'd40,8'd32);
        if (dut.active_detect_reg) begin
            $display("FAIL obj below threshold detected"); failures = failures + 1;
        end
        send_result(8'd10,8'd7,8'd128,8'd128,8'd40,8'd32);
        if (!dut.active_detect_reg) begin
            $display("FAIL obj at threshold not detected"); failures = failures + 1;
        end
        send_result(8'd10,8'd7,8'd49,8'd81,8'd40,8'd32);
        if (dut.active_detect_reg) begin
            $display("FAIL below-gate obj=81 person=49 detected"); failures = failures + 1;
        end
        send_result(8'd10,8'd7,8'd115,8'd122,8'd40,8'd32);
        if (dut.active_detect_reg) begin
            $display("FAIL below-gate obj=122 person=115 detected"); failures = failures + 1;
        end
        send_result(8'd0,8'd0,8'd255,8'd255,8'd40,8'd32);
        if (dut.box_x0 !== 0 || dut.box_y0 !== 0)
            failures = failures + 1;
        send_result(8'd19,8'd14,8'd255,8'd255,8'd40,8'd32);
        if (dut.box_x1 !== 11'd1279 || dut.box_y1 !== 10'd719)
            failures = failures + 1;

        // Half-extent product-width regression.
        //
        // W*640 and H*480 must be evaluated in 32 bits: 255*640 = 163200 and
        // 255*480 = 122400 both exceed 16 bits. From W >= 103 or H >= 137 a
        // 16-bit product wraps and collapses the box (e.g. W=103 gives
        // half_w = 1 instead of 258). Every case below is kept well clear of
        // the 1280x720 clip so the multiplier width, not the clamp, decides
        // the expected box.
        //
        // All cases use gx=10, gy=7, dx=dy=128, i.e. center (672,360).
        //
        // W=150,H=150 -> half 376/282. Both axes wrap. Before the fix this
        // produced a 553..791 x 335..385 box instead of 296..1049 x 78..642.
        send_result(8'd10,8'd7,8'd128,8'd128,8'd150,8'd150);
        if (dut.box_x0 !== 11'd296 || dut.box_x1 !== 11'd1049 ||
            dut.box_y0 !== 10'd78 || dut.box_y1 !== 10'd642) begin
            $display("FAIL W=150 H=150 half-extent: %d,%d,%d,%d",
                     dut.box_x0,dut.box_y0,dut.box_x1,dut.box_y1);
            failures = failures + 1;
        end
        // W=102,H=136 -> half 256/256. 102*640 = 136*480 = 65280, the largest
        // product that still fits in 16 bits. Last non-wrapping boundary; this
        // case must behave identically before and after the fix.
        send_result(8'd10,8'd7,8'd128,8'd128,8'd102,8'd136);
        if (dut.box_x0 !== 11'd416 || dut.box_x1 !== 11'd928 ||
            dut.box_y0 !== 10'd104 || dut.box_y1 !== 10'd616) begin
            $display("FAIL W=102 H=136 half-extent: %d,%d,%d,%d",
                     dut.box_x0,dut.box_y0,dut.box_x1,dut.box_y1);
            failures = failures + 1;
        end
        // W=103,H=136 -> half 258/256. First wrapping width (103*640 = 65920),
        // height still exact. Isolates the W axis.
        send_result(8'd10,8'd7,8'd128,8'd128,8'd103,8'd136);
        if (dut.box_x0 !== 11'd414 || dut.box_x1 !== 11'd931 ||
            dut.box_y0 !== 10'd104 || dut.box_y1 !== 10'd616) begin
            $display("FAIL W=103 H=136 half-extent: %d,%d,%d,%d",
                     dut.box_x0,dut.box_y0,dut.box_x1,dut.box_y1);
            failures = failures + 1;
        end
        // W=102,H=137 -> half 256/257. First wrapping height (137*480 = 65760),
        // width still exact. Isolates the H axis.
        send_result(8'd10,8'd7,8'd128,8'd128,8'd102,8'd137);
        if (dut.box_x0 !== 11'd416 || dut.box_x1 !== 11'd928 ||
            dut.box_y0 !== 10'd102 || dut.box_y1 !== 10'd618) begin
            $display("FAIL W=102 H=137 half-extent: %d,%d,%d,%d",
                     dut.box_x0,dut.box_y0,dut.box_x1,dut.box_y1);
            failures = failures + 1;
        end
        // W=103,H=137 -> half 258/257. Both axes wrap simultaneously. Before
        // the fix this collapsed to a 671..673 x 360..360 box.
        send_result(8'd10,8'd7,8'd128,8'd128,8'd103,8'd137);
        if (dut.box_x0 !== 11'd414 || dut.box_x1 !== 11'd931 ||
            dut.box_y0 !== 10'd102 || dut.box_y1 !== 10'd618) begin
            $display("FAIL W=103 H=137 half-extent: %d,%d,%d,%d",
                     dut.box_x0,dut.box_y0,dut.box_x1,dut.box_y1);
            failures = failures + 1;
        end

        // Start a fresh measurement window and complete 12 inferences in it.
        rst_n_npu = 0; rst_n_video = 0;
        repeat (4) @(negedge clk_npu);
        rst_n_npu = 1; rst_n_video = 1;
        repeat (12) begin
            @(negedge clk_npu); inference_done = 1;
            @(negedge clk_npu); inference_done = 0;
        end
        repeat (12) @(negedge clk_npu);
        if (dut.fps_digits_video !== 12'h012) begin
            $display("FAIL NPU FPS count/CDC: got %h, expected 012", dut.fps_digits_video);
            failures = failures + 1;
        end

        // The next empty window must replace the old reading with zero.
        repeat (32) @(negedge clk_npu);
        if (dut.fps_digits_video !== 12'h000) begin
            $display("FAIL NPU FPS idle reset: got %h", dut.fps_digits_video);
            failures = failures + 1;
        end

        // First lit pixel of the upper-right N glyph must override video RGB.
        video_de = 1;
        force dut.x_reg = 11'd1136;
        force dut.y_reg = 10'd16;
        repeat (2) @(negedge clk_video);
        if (out_data !== 24'hffffff) begin
            $display("FAIL NPU FPS glyph pixel: got %h", out_data);
            failures = failures + 1;
        end
        force dut.x_reg = 11'd1134;
        repeat (2) @(negedge clk_video);
        if (out_data !== 24'h101820) begin
            $display("FAIL NPU FPS panel pixel: got %h", out_data);
            failures = failures + 1;
        end
        release dut.x_reg;
        release dut.y_reg;

        if (failures == 0) $display("NPU_OVERLAY_PASS obj_threshold=128 person_threshold=128 cdc_bits=64");
        else $display("NPU_OVERLAY_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
