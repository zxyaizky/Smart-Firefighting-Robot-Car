`timescale 1ns/1ps

module tb_npu_bbox_threshold;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg tensor_valid = 1'b0;
    reg [63:0] tensor_data = 64'd0;
    reg inference_done = 1'b0;
    wire frame_start, pixel_valid, frame_end, frame_abort;
    wire [23:0] pixel_rgb;
    integer failures = 0;

    npu_bbox_overlay_160x120 dut (
        .clk(clk), .rst(rst),
        .tensor_valid_i(tensor_valid), .tensor_data_i(tensor_data),
        .inference_done_i(inference_done),
        .source_frame_id_i(16'd0),
        .bbox_valid_o(), .bbox_x1_o(), .bbox_y1_o(), .bbox_x2_o(), .bbox_y2_o(),
        .bbox_source_valid_o(), .bbox_source_frame_id_o(), .bbox_result_id_o(),
        .frame_start_i(1'b0), .pixel_valid_i(1'b0),
        .pixel_rgb_i(24'd0), .frame_end_i(1'b0),
        .frame_abort_i(1'b0),
        .frame_start_o(frame_start), .pixel_valid_o(pixel_valid),
        .pixel_rgb_o(pixel_rgb), .frame_end_o(frame_end),
        .frame_abort_o(frame_abort)
    );

    task check_result;
        input [7:0] obj;
        input [7:0] fire;
        input expected_detect;
        begin
            @(negedge clk);
            tensor_data = {8'd7, 8'd10, fire, 8'd32,
                           8'd40, 8'd128, 8'd128, obj};
            tensor_valid = 1'b1;
            inference_done = 1'b1;
            @(negedge clk);
            tensor_valid = 1'b0;
            inference_done = 1'b0;
            repeat (6) @(posedge clk);
            #1;
            if (dut.detect_reg !== expected_detect) begin
                $display("FAIL obj=%0d fire=%0d detected=%b expected=%b",
                         obj, fire, dut.detect_reg, expected_detect);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;
        check_result(8'd128, 8'd128, 1'b1);
        check_result(8'd63, 8'd255, 1'b0);
        check_result(8'd127, 8'd255, 1'b0);
        check_result(8'd255, 8'd31, 1'b0);
        check_result(8'd255, 8'd127, 1'b0);
        check_result(8'd128, 8'd255, 1'b1);
        check_result(8'd255, 8'd128, 1'b1);
        check_result(8'd81, 8'd49, 1'b0);
        check_result(8'd63, 8'd63, 1'b0);
        check_result(8'd122, 8'd115, 1'b0);
        check_result(8'd255, 8'd255, 1'b1);
        if (failures == 0)
            $display("NPU_BBOX_THRESHOLD_PASS obj=128 person=128");
        else
            $display("NPU_BBOX_THRESHOLD_FAIL failures=%0d", failures);
        $finish;
    end
endmodule
