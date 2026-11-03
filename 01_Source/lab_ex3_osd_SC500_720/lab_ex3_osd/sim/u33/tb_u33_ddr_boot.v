`timescale 1ns/1ps
module tb_u33_ddr_boot;
    localparam BLOCKS = 20480;
    localparam WORDS = BLOCKS * 4;
    reg npu_clk = 0;
    reg ddr_clk = 0;
    reg ahb_clk = 0;
    reg rst_n = 0;
    always #25 npu_clk = ~npu_clk;
    always #5 ddr_clk = ~ddr_clk;
    always #7 ahb_clk = ~ahb_clk;

    reg [1:0] htrans = 0;
    reg hwrite = 0;
    reg [30:0] haddr = 0;
    reg [2:0] hsize = 0;
    reg [31:0] hwdata = 0;
    wire [31:0] hrdata;
    wire [1:0] hresp;
    wire hready;
    wire load_begin, load_begin_ready, load_valid, load_ready, load_last;
    wire [23:0] load_size;
    wire [31:0] load_crc;
    wire [127:0] load_data;
    wire boot_done, boot_error;
    wire load_busy, load_error, params_ready, transport_error;

    reg video_wr = 0, video_rd = 0;
    reg [24:0] video_addr = 0;
    reg [127:0] video_data = 0;
    wire video_ready, video_rd_valid;
    wire [127:0] video_rd_data;
    reg npu_req = 0;
    reg [23:0] npu_addr = 0;
    reg [15:0] npu_len = 0;
    wire npu_ready, npu_valid;
    wire [15:0] npu_data;
    wire app_en, wdf_valid, wdf_end, read_ready, write_ready, wdf_ready;
    wire [24:0] app_addr;
    wire [2:0] app_cmd;
    wire [127:0] wdf_data, rd_data;
    wire [15:0] wdf_mask;
    wire rd_valid, rd_end;
    reg hold_responses = 0, stall_commands = 0, corrupt_readback = 0;
    reg [127:0] expected [0:BLOCKS-1];
    integer word_index;
    integer i;
    integer video_cycle = 0;
    integer video_index = 0;
    integer video_reads = 0;
    integer npu_words = 0;
    reg boot_done_seen = 0;
    reg run_video = 0;

    function [127:0] video_payload;
        input integer n;
        begin
            video_payload = {32'hfeed0000+n, 32'hcafe0000+n,
                             32'h12340000+n, 32'h56780000+n};
        end
    endfunction

    task ahb_word_write;
        input [18:0] address;
        input [31:0] data;
        begin
            @(negedge ahb_clk);
            htrans = 2'b10; hwrite = 1; haddr = {12'd0,address}; hsize = 3'b010;
            @(posedge ahb_clk);
            while (!hready) @(posedge ahb_clk);
            @(negedge ahb_clk);
            htrans = 0; hwdata = data;
            @(posedge ahb_clk);
            while (!hready) @(posedge ahb_clk);
        end
    endtask

    npu_u33_mcu_bridge boot (
        .clk_ahb(ahb_clk), .rst_ahb(!rst_n), .i_htrans(htrans),
        .i_hwrite(hwrite), .i_haddr(haddr), .i_hsize(hsize), .i_hwdata(hwdata),
        .o_hrdata(hrdata), .o_hresp(hresp), .o_hready(hready),
        .clk_ddr(ddr_clk), .rst_ddr(!rst_n),
        .o_load_begin_valid(load_begin), .i_load_begin_ready(load_begin_ready),
        .o_load_size_bytes(load_size), .o_load_crc32(load_crc),
        .o_load_valid(load_valid), .i_load_ready(load_ready),
        .o_load_data(load_data), .o_load_last(load_last),
        .o_done(boot_done), .o_error(boot_error)
    );

    npu_ddr_subsystem memory_path (
        .clk_ddr(ddr_clk), .clk_npu(npu_clk), .rst_n(rst_n),
        .i_client_rst_n(params_ready),
        .i_video_wr(video_wr), .i_video_rd(video_rd),
        .i_video_addr(video_addr), .i_video_data(video_data),
        .o_video_ready(video_ready), .o_video_rd_valid(video_rd_valid),
        .o_video_rd_data(video_rd_data),
        .i_load_begin_valid(load_begin), .o_load_begin_ready(load_begin_ready),
        .i_load_size_bytes(load_size), .i_load_crc32(load_crc),
        .i_load_valid(load_valid), .o_load_ready(load_ready),
        .i_load_data(load_data), .i_load_last(load_last),
        .o_load_busy(load_busy), .o_load_error(load_error),
        .o_params_ready_npu(params_ready),
        .i_npu_req_valid(npu_req), .o_npu_req_ready(npu_ready),
        .i_npu_req_addr(npu_addr), .i_npu_req_len(npu_len),
        .o_npu_rd_valid(npu_valid), .o_npu_rd_data(npu_data),
        .o_app_en(app_en), .o_app_addr(app_addr), .o_app_cmd(app_cmd),
        .i_app_read_ready(read_ready), .i_app_write_ready(write_ready),
        .o_wdf_valid(wdf_valid), .o_wdf_data(wdf_data),
        .o_wdf_end(wdf_end), .o_wdf_mask(wdf_mask), .i_wdf_ready(wdf_ready),
        .i_rd_valid(rd_valid), .i_rd_end(rd_end), .i_rd_data(rd_data),
        .o_transport_error(transport_error)
    );

    native_memory_model mem (
        .clk(ddr_clk), .rst_n(rst_n), .app_en(app_en), .app_cmd(app_cmd),
        .app_addr(app_addr), .read_ready(read_ready), .write_ready(write_ready),
        .wdf_valid(wdf_valid), .wdf_data(wdf_data), .wdf_end(wdf_end),
        .wdf_mask(wdf_mask), .wdf_ready(wdf_ready), .rd_valid(rd_valid),
        .rd_end(rd_end), .rd_data(rd_data), .hold_responses(hold_responses),
        .stall_commands(stall_commands), .corrupt_readback(corrupt_readback)
    );

    always @(negedge ddr_clk) begin
        video_wr = 0; video_rd = 0;
        if (!rst_n) begin video_cycle = 0; video_index = 0; end
        else if (run_video && video_ready && !params_ready) begin
            if (video_cycle % 97 == 0) begin
                video_wr = 1; video_addr = (video_index % 128) * 8;
                video_data = video_payload(video_index % 128);
            end else if (video_cycle % 97 == 40 && mem.video_writes > video_index) begin
                video_rd = 1; video_addr = (video_index % 128) * 8;
                video_index = video_index + 1;
            end
            video_cycle = video_cycle + 1;
        end
    end

    always @(posedge ddr_clk) begin
        if (boot_done) boot_done_seen <= 1;
        if (video_rd_valid) begin
            if (video_rd_data !== video_payload(video_reads % 128)) begin
                $display("FAIL video data during U33 boot index=%0d", video_reads);
                $finish;
            end
            video_reads <= video_reads + 1;
        end
    end

    always @(posedge npu_clk) begin
        if (npu_valid) begin
            if (npu_words == 0 && npu_data !== expected[16565][15:0]) begin
                $display("FAIL first L0 halfword got=%04h", npu_data); $finish;
            end
            if (npu_words == 1 && npu_data !== expected[16565][31:16]) begin
                $display("FAIL second L0 halfword got=%04h", npu_data); $finish;
            end
            npu_words <= npu_words + 1;
        end
    end

    initial begin
        $readmemh("deployment/npu12/parameters128.hex", expected);
        repeat (10) @(posedge ddr_clk);
        rst_n <= 1;
        run_video <= 1;
        for (word_index = 0; word_index < WORDS; word_index = word_index + 1)
            ahb_word_write(word_index * 4,
                expected[word_index/4][(word_index%4)*32 +: 32]);
        wait (params_ready);
        if (!boot_done_seen || boot_error || load_error || transport_error || video_reads == 0) begin
            $display("FAIL U33 DDR flags done=%0d be=%0d le=%0d te=%0d video=%0d",
                     boot_done_seen, boot_error, load_error, transport_error, video_reads);
            $finish;
        end
        for (i = 0; i < BLOCKS; i = i + 1)
            if (mem.params[i] !== expected[i]) begin
                $display("FAIL U33 DDR image block=%0d", i); $finish;
            end
        repeat (5) @(negedge npu_clk);
        npu_addr = 24'hc205a8; npu_len = 16'd2; npu_req = 1;
        @(posedge npu_clk); while (!npu_ready) @(posedge npu_clk);
        @(negedge npu_clk); npu_req = 0;
        wait (npu_words == 2);
        $display("U33_DDR_BOOT_PASS bytes=%0d blocks=%0d video_reads=%0d l0_halfwords=%0d",
                 WORDS*4, BLOCKS, video_reads, npu_words);
        $finish;
    end

    initial begin
        #50000000;
        $display("FAIL U33 DDR timeout words=%0d load_busy=%0d", word_index, load_busy);
        $finish;
    end
endmodule
