`timescale 1ns/1ps
module tb_u33_bridge;
    localparam BLOCKS = 20480;
    localparam WORDS = BLOCKS * 4;
    reg ahb_clk = 0;
    reg ddr_clk = 0;
    reg ahb_rst = 1;
    reg ddr_rst = 1;
    always #7 ahb_clk = ~ahb_clk;
    always #5 ddr_clk = ~ddr_clk;

    reg [1:0] htrans = 0;
    reg hwrite = 0;
    reg [30:0] haddr = 0;
    reg [2:0] hsize = 0;
    reg [31:0] hwdata = 0;
    wire [31:0] hrdata;
    wire [1:0] hresp;
    wire hready;
    wire load_begin, load_valid, load_last, done, error;
    reg load_begin_ready = 0;
    reg load_ready = 0;
    wire [23:0] load_size;
    wire [31:0] load_crc;
    wire [127:0] load_data;

    reg [127:0] expected [0:BLOCKS-1];
    integer word_index;
    integer block_index = 0;
    integer stalls = 0;
    integer reset_restarts = 0;

    npu_u33_mcu_bridge dut (
        .clk_ahb(ahb_clk), .rst_ahb(ahb_rst), .i_htrans(htrans),
        .i_hwrite(hwrite), .i_haddr(haddr), .i_hsize(hsize),
        .i_hwdata(hwdata), .o_hrdata(hrdata), .o_hresp(hresp),
        .o_hready(hready), .clk_ddr(ddr_clk), .rst_ddr(ddr_rst),
        .o_load_begin_valid(load_begin), .i_load_begin_ready(load_begin_ready),
        .o_load_size_bytes(load_size), .o_load_crc32(load_crc),
        .o_load_valid(load_valid), .i_load_ready(load_ready),
        .o_load_data(load_data), .o_load_last(load_last),
        .o_done(done), .o_error(error)
    );

    task ahb_word_write;
        input [18:0] address;
        input [31:0] data;
        begin
            @(negedge ahb_clk);
            htrans = 2'b10;
            hwrite = 1'b1;
            haddr = {12'd0, address};
            hsize = 3'b010;
            @(posedge ahb_clk);
            while (!hready) @(posedge ahb_clk);
            @(negedge ahb_clk);
            htrans = 2'b00;
            hwdata = data;
            @(posedge ahb_clk);
            while (!hready) begin
                stalls = stalls + 1;
                @(posedge ahb_clk);
            end
        end
    endtask

    always @(negedge ddr_clk) begin
        if (ddr_rst) begin
            load_begin_ready = 0;
            load_ready = 0;
        end else begin
            load_begin_ready = 1;
            load_ready = (($time / 10) % 20) == 0;
        end
    end

    always @(posedge ddr_clk) begin
        if (ddr_rst) begin
            block_index <= 0;
        end else if (load_valid && load_ready) begin
            if (load_data !== expected[block_index]) begin
                $display("FAIL U33 bridge block=%0d got=%032h expected=%032h",
                         block_index, load_data, expected[block_index]);
                $finish;
            end
            if (load_last !== (block_index == BLOCKS-1)) begin
                $display("FAIL U33 last block=%0d last=%0d", block_index, load_last);
                $finish;
            end
            block_index <= block_index + 1;
        end
    end

    initial begin
        $readmemh("deployment/npu12/parameters128.hex", expected);
        repeat (8) @(posedge ahb_clk);
        ahb_rst <= 0;
        ddr_rst <= 0;

        // Start a transfer, reset both domains, then restart from byte zero.
        for (word_index = 0; word_index < 68; word_index = word_index + 1)
            ahb_word_write(word_index * 4,
                expected[word_index/4][(word_index%4)*32 +: 32]);
        @(negedge ahb_clk);
        ahb_rst = 1;
        @(negedge ddr_clk);
        ddr_rst = 1;
        repeat (8) @(posedge ahb_clk);
        ahb_rst <= 0;
        ddr_rst <= 0;
        reset_restarts = reset_restarts + 1;

        for (word_index = 0; word_index < WORDS; word_index = word_index + 1)
            ahb_word_write(word_index * 4,
                expected[word_index/4][(word_index%4)*32 +: 32]);
        wait (done);
        repeat (5) @(posedge ddr_clk);
        if (error || hresp != 2'b00 || load_size != 24'd327680 ||
            load_crc != 32'hf918606b || block_index != BLOCKS || stalls == 0) begin
            $display("FAIL U33 bridge flags error=%0d resp=%0d size=%0d crc=%08h blocks=%0d",
                     error, hresp, load_size, load_crc, block_index);
            $finish;
        end
        $display("U33_BRIDGE_PASS bytes=%0d blocks=%0d stalls=%0d reset_restarts=%0d",
                 WORDS*4, BLOCKS, stalls, reset_restarts);
        $finish;
    end

    initial begin
        #20000000;
        $display("FAIL U33 bridge timeout words=%0d blocks=%0d", word_index, block_index);
        $finish;
    end
endmodule
