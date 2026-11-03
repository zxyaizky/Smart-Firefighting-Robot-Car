`timescale 1ns/1ps
module tb_red_denoise_frames;
    reg clk=0, rst=1, valid=0, sof=0, eof=0;
    reg [23:0] rgb=0;
    reg [10:0] x=0;
    reg [9:0] y=0;
    wire [1:0] color;
    wire update, box_valid, green_valid, red_valid, fire_valid, fire_sample;
    always #5 clk=~clk;
    color_green_red_frame #(.IMG_HDISP(64), .IMG_VDISP(8),
        .DENOISE_ENABLE(1), .MIN_PIXELS(12), .SAMPLE_SHIFT(0),
        .CLK_FREQ_HZ(1000), .RESULT_TIMEOUT_MS(5000)) dut (
        .clk(clk), .rst(rst), .pixel_rgb_i(rgb), .pixel_valid_i(valid),
        .pixel_x_i(x), .pixel_y_i(y), .frame_start_i(sof),
        .frame_end_i(eof), .frame_abort_i(1'b0),
        .green_s_min_i(8'd55), .green_s_max_i(8'd255),
        .green_v_min_i(8'd70), .green_v_max_i(8'd255),
        .color_o(color), .result_update_o(update), .bbox_valid_o(box_valid),
        .bbox_x1_o(), .bbox_x2_o(), .bbox_y1_o(), .bbox_y2_o(),
        .green_valid_o(green_valid), .red_valid_o(red_valid),
        .green_x1_o(), .green_x2_o(), .green_y1_o(), .green_y2_o(),
        .red_x1_o(), .red_x2_o(), .red_y1_o(), .red_y2_o(),
        .red_fire_valid_o(fire_valid), .red_fire_sample_o(fire_sample));
    task frame;
        input with_red;
        integer ix,iy;
        begin
            for (iy=0;iy<8;iy=iy+1)
                for (ix=0;ix<64;ix=ix+1) begin
                    @(negedge clk);
                    x=ix; y=iy; valid=1;
                    sof=(ix==0 && iy==0); eof=(ix==63 && iy==7);
                    rgb=with_red && ix<16 ? 24'hff0000 :
                        ix>=16 && ix<48 ? 24'h00ff00 : 24'h000000;
                end
            @(negedge clk); valid=0; sof=0; eof=0;
            repeat(250) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst=0;
        frame(0); frame(0);
        if (color !== 2'd1 || !green_valid)
            $fatal(1,"denoised green acquisition failed color=%d",color);
        frame(1);
        if (color !== 2'd1 || fire_valid)
            $fatal(1,"denoised red acquired on first frame");
        frame(1);
        if (color !== 2'd2 || !red_valid || !fire_valid)
            $fatal(1,"denoised red priority after two frames failed color=%d red=%b fire=%b",
                color,red_valid,fire_valid);
        $display("PASS tb_red_denoise_frames"); $finish;
    end
endmodule
