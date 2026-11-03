`timescale 1ns/1ps
module tb_rgb_input;
    reg vclk = 0, clk = 0;
    integer vhalf = 7, nhalf = 5;
    reg npu_clock_enable = 1;
    always begin #(vhalf); vclk = ~vclk; end
    always begin #(nhalf); if (npu_clock_enable) clk = ~clk; end
    reg rst_n = 0, sof = 0, valid = 0;
    reg [23:0] rgb = 0;
    wire frame, byte_valid, busy, capture_busy;
    wire [7:0] pixel;
    wire inference_done, tile_error;
    reg desc_we = 0;
    reg [2:0] desc_word = 0;
    reg [31:0] desc_data = 0;
    reg [31:0] desc [0:7];
    wire req;
    wire [23:0] req_addr;
    wire [15:0] req_len;
    reg req_ready = 0, rd_valid = 0;
    reg [1:0] dma_state = 0;
    integer fd, dummy, mode = 0, done_count = 0, epoch = 0;
    integer source_id = 0;
    integer bytes = 0, writes = 0, loads = 0, reads = 0;
    integer p, i;
    reg expect_busy = 0;
    reg [1023:0] directory;
    npu_rgb_input front (
        .clk_video(vclk), .clk_npu(clk), .rst_n(rst_n),
        .i_sof(sof), .i_valid(valid), .i_rgb(rgb), .i_npu_busy(busy),
        .o_frame_valid(frame), .o_byte_valid(byte_valid), .o_byte(pixel),
        .o_capture_busy(capture_busy)
    );
    npu_top_with_sdram_dma #(.USE_DESC_RAM(1)) dut (
        .clk(clk), .rst_n(rst_n), .o_input_busy(busy),
        .i_frame_valid(frame), .i_lbp_valid(byte_valid), .i_lbp_pixel(pixel),
        .i_desc_we(desc_we), .i_desc_layer(5'd0), .i_desc_word(desc_word),
        .i_desc_wdata(desc_data), .i_layer_count(6'd1), .i_desc_mode(1'b1),
        .o_inference_done(inference_done), .o_tile_error(tile_error),
        .o_sdram_rd_req_valid(req), .i_sdram_rd_req_ready(req_ready),
        .o_sdram_rd_addr(req_addr), .o_sdram_rd_len_halfwords(req_len),
        .i_sdram_rd_data(16'd0), .i_sdram_rd_valid(rd_valid), .i_num4_sel(7'd0)
    );
    // Real SDRAM wrapper, with zero kernel/bias responses through its public port.
    always @(negedge clk) begin
        req_ready = 0;
        rd_valid = 0;
        if (!rst_n) dma_state = 0;
        else case (dma_state)
            0: if (req) begin req_ready = 1; dma_state = 1; end
            1: begin rd_valid = 1; dma_state = 2; end
            2: dma_state = 3;
            3: begin rd_valid = 1; dma_state = 0; end
            default: dma_state = 0;
        endcase
    end
    function [23:0] source_rgb;
        input integer id, x, y;
        reg [7:0] r, g, b;
        begin
            r = x*7 + y*13 + id*29 + (x >> 8)*31;
            g = x*11 + y*3 + id*47 + (y >> 8)*17;
            b = (x ^ (y*5)) + id*61 + (x >> 4);
            source_rgb = {r,g,b};
        end
    endfunction
    task start_frame;
        input integer id;
        begin
            source_id = id;
            @(negedge vclk); sof = 1; valid = 0;
            $fdisplay(fd, "S %0d %0d", epoch, id);
            @(negedge vclk); sof = 0;
        end
    endtask
    task pixels;
        input integer id, first, count, gaps;
        integer n;
        begin
            for (n = first; n < first+count; n = n+1) begin
                @(negedge vclk);
                valid = 1; rgb = source_rgb(id, n%1280, n/1280);
                if (gaps && n%997 == 83) begin
                    @(negedge vclk); valid = 0; rgb = 24'hbadbad;
                    repeat (3) @(negedge vclk);
                end
            end
            @(negedge vclk); valid = 0;
        end
    endtask
    task source_frame;
        input integer id, gaps;
        begin start_frame(id); pixels(id,0,921600,gaps); end
    endtask
    task reset_all;
        begin
            #2; rst_n = 0; sof = 0; valid = 0;
            npu_clock_enable = 1;
            repeat (10) @(negedge clk);
            rst_n = 1;
            epoch = epoch+1;
            $fdisplay(fd,"Z %0d",epoch);
            bytes = 0; writes = 0; reads = 0;
            repeat (12) @(negedge vclk);
            for (i=0;i<8;i=i+1) begin
                @(negedge clk); desc_we=1; desc_word=i; desc_data=desc[i];
            end
            @(negedge clk); desc_we=0;
        end
    endtask

    // Observations are checked independently in Python, including EVERY RAM byte
    // and EVERY physical BCU request / registered response, not just checksums.
    always @(posedge clk) begin
        if (!rst_n) expect_busy <= 0;
        else begin
            if (expect_busy && !busy) begin
                $fdisplay(fd,"FAIL ownership gap"); $finish;
            end
            if (dut.w_preload_done) expect_busy <= 1;
            if (inference_done) expect_busy <= 0;
        end
    end
    reg frame_d = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            frame_d <= 1'b0;
        end else begin
            frame_d <= frame;
            if (frame && !frame_d) begin
                bytes = 0;
                writes = 0;
                $fdisplay(fd,"A %0d %0d",epoch,source_id);
            end
        end
    end
    always @(posedge clk) if (rst_n) begin
        if (tile_error) begin $fdisplay(fd,"FAIL tile_error"); $finish; end
        if (byte_valid) begin
            if (!frame) begin $fdisplay(fd,"FAIL byte outside frame"); $finish; end
            $fdisplay(fd,"B %0d %0d %02x",epoch,bytes,pixel);
            bytes = bytes+1;
        end
        if (dut.w_preload_wr_en) begin
            if (dut.r_inference_busy) begin
                $fdisplay(fd,"FAIL overwrite during inference"); $finish;
            end
            $fdisplay(fd,"W %0d %0d %04x %032x",epoch,dut.w_preload_wr_addr,
                dut.w_preload_wr_mask,dut.w_preload_wr_data);
            writes = writes+1;
        end
        if (dut.w_preload_done) begin
            if (bytes != 43200 || writes != 6300 || !busy ||
                dut.w_packer_pixel_count != 57600) begin
                $fdisplay(fd,"FAIL load count %0d %0d %0d",bytes,writes,
                    dut.w_packer_pixel_count); $finish;
            end
            $fdisplay(fd,"L %0d",epoch);
            loads = loads+1;
            bytes = 0; writes = 0;
        end
        if (dut.u_core.w_ping_rd_en) begin
            $fdisplay(fd,"R %0d %0d %0d",epoch,dut.u_core.w_bcu_rd_addr,
                dut.u_core.w_bcu_cin_idx);
            reads = reads+1;
        end
        if (dut.u_core.w_npu_in_valid) begin
            if (!busy) begin $fdisplay(fd,"FAIL busy gap"); $finish; end
            $fdisplay(fd,"V %0d %02x %0d %0d",epoch,dut.u_core.o_dbg_npu_pixel_in,
                dut.u_core.w_npu_is_first_cin,dut.u_core.w_npu_is_last_cin);
        end
        if (inference_done) begin
            $fdisplay(fd,"D %0d",epoch); done_count = done_count+1;
        end
    end
    // Snapshot all 16 physical banks after the final registered write commits.
    // Generate indices are constants; no mux overrides or model replacement.
    genvar bank;
    generate for (bank=0;bank<16;bank=bank+1) begin : audit_bank
        integer address;
        always @(posedge clk) if (rst_n && dut.w_preload_done) begin
            for (address=0;address<3600;address=address+1)
                $fdisplay(fd,"M %0d %0d %02x",epoch,address*16+bank,
                    dut.u_core.u_ping_array.gen_sram_bank[bank].mem[address]);
        end
    end endgenerate
    // Audit sampling against externally counted source coordinates.
    integer source_index=0, selected_count=0;
    always @(posedge vclk) if (rst_n) begin
        if (sof) begin source_index=0; selected_count=0; end
        if (front.sample_write) begin
            $fdisplay(fd,"T %0d %0d %0d %0d",epoch,selected_count,
                      source_index%1280,source_index/1280);
            if (front.sample_addr !== selected_count) begin
                $fdisplay(fd,"FAIL sample address"); $finish;
            end
            selected_count=selected_count+1;
        end
        if (valid) source_index=source_index+1;
    end
    initial begin
        dummy=$value$plusargs("DIR=%s",directory);
        dummy=$value$plusargs("MODE=%d",mode);
        dummy=$value$plusargs("VHALF=%d",vhalf);
        dummy=$value$plusargs("NHALF=%d",nhalf);
        fd=$fopen({directory,"/observed.txt"},"w");
        $readmemh({directory,"/desc.hex"},desc);
        reset_all;
        if (mode == 0) begin
            source_frame(1,0);
            source_frame(2,1); // back-to-back: complete mailbox/inference owns input
            wait (dut.u_core.w_tile_y_base == 118);
            start_frame(3);
            pixels(3,0,100,0);
            wait (done_count == 1); // busy clears inside rejected frame 3
            pixels(3,100,921500,1);
            repeat (20) @(negedge vclk);
            if (loads != 1) begin $fdisplay(fd,"FAIL mid-frame admission"); $finish; end
            source_frame(4,1);
            wait (done_count == 2);
        end else begin
            pixels(5,0,10000,1); // no SOF after reset: ignored
            start_frame(5); pixels(5,0,123456,1);
            reset_all; // reset during capture
            pixels(5,123456,1000,0); // stale tail after reset: ignored
            start_frame(6); pixels(6,0,920320,0); // all samples, but source EOF absent
            repeat (100) @(negedge clk);
            if (loads != 0) begin $fdisplay(fd,"FAIL early publish"); $finish; end
            start_frame(7); // new SOF discards incomplete frame 6
            pixels(7,0,300000,1);
            if (bytes == 0 || bytes >= 43200) begin
                $fdisplay(fd,"FAIL reset did not hit active stream"); $finish;
            end
            reset_all; // reset during streamed RGB / PING load
            // Stop NPU clock before capture publishes the next mailbox request.
            @(negedge clk); npu_clock_enable=0;
            source_frame(8,0);
            repeat (20) @(negedge vclk);
            reset_all; // reset with pending cross-clock request
            source_frame(9,0);
            wait (dut.u_core.w_tile_y_base == 4);
            reset_all; // reset during inference with PING owned
            source_frame(10,1);
            wait (done_count == 1);
        end
        repeat (32) @(negedge clk);
        if (busy) begin $fdisplay(fd,"FAIL busy stuck"); $finish; end
        $fdisplay(fd,"PASS %0d %0d",loads,done_count);
        $fclose(fd); $display("RGB_INPUT_PASS"); $finish;
    end
    initial begin #1000000000; $fdisplay(fd,"FAIL timeout"); $finish; end
endmodule
