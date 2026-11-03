`timescale 1ns/1ps
module tb_red_hsv_threshold;
    reg clk=0, rst=1, valid=0;
    reg [23:0] rgb=0;
    wire red, green, out_valid, meta;
    always #5 clk=~clk;
    color_hsv_pixel dut (
        .clk(clk), .rst(rst), .rgb_i(rgb), .valid_i(valid),
        .green_s_min_i(8'd55), .green_s_max_i(8'd255),
        .green_v_min_i(8'd70), .green_v_max_i(8'd255),
        .metadata_i(1'b0), .red_o(red), .green_o(green),
        .valid_o(out_valid), .metadata_o(meta));
    task check;
        input [23:0] sample;
        input want_red, want_green;
        begin
            @(negedge clk); rgb=sample; valid=1;
            @(negedge clk); valid=0;
            repeat (2) @(negedge clk);
            if (red !== want_red || green !== want_green || !out_valid)
                $fatal(1,"RGB=%h red=%b green=%b expected=%b/%b",
                    sample,red,green,want_red,want_green);
            repeat (2) @(negedge clk);
        end
    endtask
    initial begin
        repeat (3) @(negedge clk); rst=0;
        check(24'hff0000,1,0); // H=0
        check(24'hff0055,1,0); // H=340 inclusive
        check(24'hff5500,0,0); // H=20 excluded
        check(24'hffff00,0,0); // old yellow interval removed
        check(24'h00ff00,0,1); // green remains
        check(24'hffb0b0,0,0); // red saturation below 100
        check(24'h200000,0,0); // red value below 50
        $display("PASS tb_red_hsv_threshold"); $finish;
    end
endmodule
