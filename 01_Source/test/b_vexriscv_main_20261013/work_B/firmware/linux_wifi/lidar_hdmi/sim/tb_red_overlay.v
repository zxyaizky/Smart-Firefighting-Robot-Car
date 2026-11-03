`timescale 1ns/1ps
module tb_red_overlay;
    reg clk=0, rst=1, de=0, vs=0, result=0, box=0, red=0;
    reg [15:0] source_id=0;
    reg [10:0] x=0, xmin=10, xmax=20;
    reg [9:0] y=0, ymin=10, ymax=20;
    wire [23:0] rgb;
    always #5 clk=~clk;
    rescue_color_bbox_overlay #(.X_WIDTH(11), .Y_WIDTH(10),
        .COORD_SHIFT(0), .BOX_INSET(0), .MAX_AGE_CYCLES(1000)) dut (
        .clk(clk), .rst(rst), .rgb_i(24'h123456), .de_i(de),
        .hsync_i(1'b0), .vsync_i(vs), .pixel_x_i(x), .pixel_y_i(y),
        .result_valid_i(result), .bbox_valid_i(box), .box_red_i(red),
        .xmin_i(xmin), .xmax_i(xmax), .ymin_i(ymin), .ymax_i(ymax),
        .source_frame_valid_i(1'b1), .source_frame_id_i(source_id),
        .rgb_o(rgb), .de_o(), .hsync_o(), .vsync_o(),
        .active_valid_o(), .active_source_frame_id_o(),
        .display_xmin_o(), .display_xmax_o(), .display_ymin_o(),
        .display_ymax_o(), .draw_hit_o(), .clear_reason_o());
    task publish;
        input is_red;
        input [15:0] id;
        begin
            @(negedge clk); result=1; box=1; red=is_red; source_id=id;
            @(negedge clk); result=0; vs=1;
            @(negedge clk); vs=0; de=1; x=10; y=10;
            #1;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst=0;
        publish(1,1);
        if (rgb !== 24'hff0000) $fatal(1,"red border=%h",rgb);
        @(negedge clk); de=0;
        publish(0,2);
        if (rgb !== 24'h00ff00) $fatal(1,"green border=%h",rgb);
        $display("PASS tb_red_overlay"); $finish;
    end
endmodule
