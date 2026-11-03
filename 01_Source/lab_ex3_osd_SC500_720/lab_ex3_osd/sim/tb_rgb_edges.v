`timescale 1ns/1ps
module tb_rgb_edges;
    reg vclk=0,clk=0,clk_enable=1;
    always #7 vclk=~vclk;
    always begin #11; if(clk_enable) clk=~clk; end
    reg rst_n=0,sof=0,valid=0,busy=0;
    reg [23:0] rgb=0;
    wire frame,byte_valid,capture_busy;
    wire [7:0] pixel;
    reg [7:0] golden [0:43199];
    reg frame_d=0,overflow_seen=0;
    integer bytes=0,frames=0,aborted=0,accepted_samples=0;
    integer accepted_before_overflow=0;

    npu_rgb_input dut (
        .clk_video(vclk),.clk_npu(clk),.rst_n(rst_n),
        .i_sof(sof),.i_valid(valid),.i_rgb(rgb),.i_npu_busy(busy),
        .o_frame_valid(frame),.o_byte_valid(byte_valid),.o_byte(pixel),
        .o_capture_busy(capture_busy)
    );

    function [23:0] source_rgb;
        input integer x,y;
        reg [7:0] r,g,b;
        begin
            r=x*7+y*13+31*29+(x/256)*31;
            g=x*11+y*3+31*47+(y/256)*17;
            b=(x^(y*5))+31*61+x/16;
            source_rgb={r,g,b};
        end
    endfunction

    // SOF and source pixel (0,0) intentionally coincide.
    task source_frame;
        input integer invert;
        integer n;
        begin
            for(n=0;n<921600;n=n+1) begin
                @(negedge vclk); sof=(n==0); valid=1;
                rgb=source_rgb(n%1280,n/1280)^{24{invert[0]}};
            end
            @(negedge vclk); sof=0; valid=0;
        end
    endtask

    always @(posedge vclk) if(rst_n) begin
        if(dut.fifo_full) overflow_seen<=1;
        if(dut.fifo_wr_en &&
           (dut.fifo_wr_data[25:24]==2'b01 || dut.fifo_wr_data[25:24]==2'b11))
            accepted_samples=accepted_samples+1;
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            frame_d<=0; bytes=0;
        end else begin
            frame_d<=frame;
            if(byte_valid) begin
                if(!frame||bytes>=43200||
                   pixel!==(golden[bytes]^((frames==1)?8'hff:8'h00))) begin
                    $display("FAIL edge byte frame=%0d index=%0d",frames,bytes);
                    $finish;
                end
                bytes=bytes+1;
            end
            if(!frame&&frame_d) begin
                if(bytes==43200) frames=frames+1;
                else if(bytes!=0) aborted=aborted+1;
                bytes=0;
            end
        end
    end

    initial begin
        $readmemh("sim/rgb_input/edge_golden.hex",golden);
        repeat(10) @(negedge vclk); rst_n=1;
        repeat(20) @(negedge vclk);

        source_frame(0);
        source_frame(1);
        wait(frames==2);
        if(accepted_samples!=28800) begin
            $display("FAIL gapless samples %0d",accepted_samples); $finish;
        end

        // A stopped consumer must fail closed at FIFO full, then recover on a
        // later SOF without publishing the partial frame.
        @(negedge clk); clk_enable=0;
        accepted_before_overflow=accepted_samples;
        source_frame(0);
        if(!overflow_seen||dut.capture_reg||
           accepted_samples<=accepted_before_overflow||
           accepted_samples>accepted_before_overflow+256) begin
            $display("FAIL bounded FIFO overflow handling"); $finish;
        end
        clk_enable=1;
        repeat(6000) @(negedge clk);
        if(dut.fifo_full) begin
            $display("FAIL FIFO did not drain"); $finish;
        end
        source_frame(0);
        wait(frames==3);
        repeat(32) @(negedge vclk);
        if(aborted!=1||bytes!=0||capture_busy) begin
            $display("FAIL FIFO recovery frames=%0d aborted=%0d",frames,aborted);
            $finish;
        end
        $display("RGB_EDGES_PASS frames=3 bytes=129600 overflow_recovered=1");
        $finish;
    end
    initial begin #300000000; $display("FAIL edge timeout"); $finish; end
endmodule
