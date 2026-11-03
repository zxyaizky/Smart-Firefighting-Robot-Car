`timescale 1ns/1ps
module tb_rgb_packer;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, enable=0, frame=0, valid=0;
    reg [7:0] pixel=0;
    wire we, done, loading, pending;
    wire [12:0] addr;
    wire [15:0] mask, count;
    wire [127:0] data;
    integer p, lane, writes=0, dones=0, cycles=0, last_write=-10;
    integer phase=0;
    reg [127:0] expected;
    lbp_to_ping_packer dut (
        .clk(clk),.rst_n(rst_n),.i_enable(enable),.i_frame_valid(frame),
        .i_lbp_valid(valid),.i_lbp_pixel(pixel),.o_preload_wr_en(we),
        .o_preload_wr_addr(addr),.o_preload_wr_mask(mask),.o_preload_wr_data(data),
        .o_preload_done(done),.o_dbg_pixel_count(count),
        .o_loading(loading),.o_dbg_final_write_pending(pending)
    );
    function [7:0] golden;
        input integer n;
        begin golden=n*17+(n/256); end
    endfunction
    task beat;
        input integer n;
        begin @(negedge clk); valid=1; pixel=golden(n); end
    endtask
    always @(posedge clk) begin
        cycles=cycles+1;
        if (rst_n && we) begin
            if (phase != 2 || addr != writes || mask != 65535) begin
                $display("FAIL admission/address phase=%0d addr=%0d",phase,addr); $finish;
            end
            for (lane=0;lane<16;lane=lane+1)
                expected[lane*8+:8]=golden(writes*16+lane);
            if (data !== expected) begin $display("FAIL data"); $finish; end
            writes=writes+1; last_write=cycles;
        end
        if (rst_n && done) begin
            if (writes != 3600 || count != 57600 || cycles != last_write+1 || !loading) begin
                $display("FAIL commit-before-done"); $finish;
            end
            dones=dones+1;
        end
    end
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        // Reject at boundary; enable becoming high in the middle must not admit.
        @(negedge clk); frame=1; enable=0; phase=1;
        for(p=0;p<64;p=p+1) beat(p);
        @(negedge clk); enable=1;
        for(p=64;p<57600;p=p+1) beat(p);
        @(negedge clk); frame=0; valid=0;
        repeat(4) @(negedge clk);
        if (writes || dones) begin $display("FAIL rejected frame"); $finish; end
        // Accept a first byte coincident with frame rise; finish admitted frame
        // even when admission-enable falls, with arbitrary valid gaps.
        @(negedge clk); frame=1; valid=1; pixel=golden(0); phase=2;
        for(p=1;p<57600;p=p+1) begin
            beat(p);
            if (p==31) enable=0;
            if (p%113==17) begin
                @(negedge clk); valid=0;
                repeat(7) @(negedge clk);
            end
        end
        @(negedge clk); frame=0; valid=0;
        // The final registered write is pending as frame-valid drops.
        repeat(4) @(negedge clk);
        if(writes!=3600 || dones!=1) begin $display("FAIL completion"); $finish; end
        phase=3;
        @(negedge clk); frame=1;
        for(p=0;p<40;p=p+1) beat(p);
        @(negedge clk); frame=0; valid=0;
        repeat(4) @(negedge clk);
        if(writes!=3600 || dones!=1) begin $display("FAIL duplicate"); $finish; end
        $display("RGB_PACKER_PASS bytes=57600 writes=3600"); $finish;
    end
    initial begin #5000000; $display("FAIL timeout"); $finish; end
endmodule
