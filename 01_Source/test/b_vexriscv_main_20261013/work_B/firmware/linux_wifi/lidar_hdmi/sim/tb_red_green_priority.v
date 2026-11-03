`timescale 1ns/1ps
module tb_red_green_priority;
    reg clk = 0, rst = 1, valid = 0, sof = 0, eof = 0, abort = 0;
    reg [23:0] rgb = 0;
    reg [10:0] x = 0;
    reg [9:0] y = 0;
    wire [1:0] color;
    wire update, box_valid, green_valid, red_valid, fire_valid, fire_sample;
    wire [10:0] bx1, bx2, gx1, gx2, rx1, rx2;
    wire [9:0] by1, by2, gy1, gy2, ry1, ry2;
    always #5 clk = ~clk;

    color_green_red_frame #(.IMG_HDISP(64), .IMG_VDISP(8),
        .DENOISE_ENABLE(0), .MIN_PIXELS(4), .SAMPLE_SHIFT(0),
        .CLK_FREQ_HZ(1000), .RESULT_TIMEOUT_MS(5000)) dut (
        .clk(clk), .rst(rst), .pixel_rgb_i(rgb), .pixel_valid_i(valid),
        .pixel_x_i(x), .pixel_y_i(y), .frame_start_i(sof),
        .frame_end_i(eof), .frame_abort_i(abort),
        .green_s_min_i(8'd55), .green_s_max_i(8'd255),
        .green_v_min_i(8'd70), .green_v_max_i(8'd255),
        .color_o(color), .result_update_o(update), .bbox_valid_o(box_valid),
        .bbox_x1_o(bx1), .bbox_x2_o(bx2), .bbox_y1_o(by1), .bbox_y2_o(by2),
        .green_valid_o(green_valid), .red_valid_o(red_valid),
        .green_x1_o(gx1), .green_x2_o(gx2), .green_y1_o(gy1), .green_y2_o(gy2),
        .red_x1_o(rx1), .red_x2_o(rx2), .red_y1_o(ry1), .red_y2_o(ry2),
        .red_fire_valid_o(fire_valid), .red_fire_sample_o(fire_sample));

    task frame;
        input integer red_pixels;
        input integer green_pixels;
        input [23:0] other_rgb;
        integer i;
        begin
            for (i=0; i<32; i=i+1) begin
                @(negedge clk);
                valid = 1; sof = (i==0); eof = (i==31);
                x = i; y = 0;
                rgb = i<red_pixels ? 24'hff0000 :
                      i<red_pixels+green_pixels ? 24'h00ff00 : other_rgb;
            end
            @(negedge clk);
            valid=0; sof=0; eof=0; rgb=0;
            repeat (8) @(negedge clk);
        end
    endtask

    integer n;
    initial begin
        repeat (4) @(negedge clk);
        rst=0;
        frame(0,16,24'h000000);
        frame(0,16,24'h000000);
        if (color !== 2'd1 || !green_valid || fire_valid)
            $fatal(1,"green two-frame acquisition failed: color=%d",color);
        frame(8,16,24'h000000);
        if (color !== 2'd1 || fire_valid)
            $fatal(1,"red acquired before two frames");
        frame(8,16,24'h000000);
        if (color !== 2'd2 || !red_valid || !fire_valid ||
            bx1 !== 0 || bx2 !== 7)
            $fatal(1,"red priority/box/fire failed: color=%d box=%d..%d fire=%b",
                color,bx1,bx2,fire_valid);
        frame(0,0,24'hffff00);
        if (fire_valid)
            $fatal(1,"yellow must not sustain red fire");
        repeat (4) frame(0,0,24'hffff00);
        if (red_valid || color !== 2'd0)
            $fatal(1,"yellow was recognized or stale red not cleared");
        $display("PASS tb_red_green_priority");
        $finish;
    end
endmodule
