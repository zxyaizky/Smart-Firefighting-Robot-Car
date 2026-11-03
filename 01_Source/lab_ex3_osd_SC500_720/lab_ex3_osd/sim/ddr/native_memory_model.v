`timescale 1ns/1ps
// Test-only ordered 128-bit native DDR model, independent command/data channels.
// It deliberately accepts W before AW and AW before W on different cycles.
module native_memory_model #(
    parameter VIDEO_WORDS=256
) (
    input wire clk, input wire rst_n,
    input wire app_en, input wire [2:0] app_cmd, input wire [24:0] app_addr,
    output wire read_ready, output wire write_ready,
    input wire wdf_valid, input wire [127:0] wdf_data,
    input wire wdf_end, input wire [15:0] wdf_mask, output wire wdf_ready,
    output reg rd_valid, output reg rd_end, output reg [127:0] rd_data,
    input wire hold_responses, input wire stall_commands,
    input wire corrupt_readback
);
    reg [127:0] params [0:524287];
    reg [127:0] video [0:VIDEO_WORDS-1];
    reg [127:0] responses [0:255];
    integer deadlines [0:255];
    integer cycle=0, head=0, tail=0, count=0;
    integer param_writes=0, param_reads=0, video_writes=0, video_reads=0;
    integer aw_first=0, w_first=0, max_outstanding=0;
    reg address_seen=0, data_seen=0;
    reg [24:0] saved_addr;
    reg [127:0] saved_data;
    reg cmd_stalled=0, data_stalled=0;
    reg [27:0] cmd_held;
    reg [127:0] data_held;
    assign read_ready=rst_n && !stall_commands && cycle%7!=0 && cycle%7!=1 && count<250;
    assign write_ready=rst_n && !stall_commands && cycle%11>=4 && !address_seen;
    assign wdf_ready=rst_n && cycle%13<7 && !data_seen;

    always @(posedge clk) begin
        if(!rst_n) begin
            cycle=0; head=0; tail=0; count=0; address_seen=0; data_seen=0;
            cmd_stalled=0; data_stalled=0;
            rd_valid<=0; rd_end<=0; rd_data<=0;
        end else begin
            if(cmd_stalled && (!app_en || {app_cmd,app_addr}!==cmd_held)) begin
                $display("FAIL native command changed while stalled"); $finish;
            end
            if(data_stalled && (!wdf_valid || wdf_data!==data_held || !wdf_end || wdf_mask!=0)) begin
                $display("FAIL native write data changed while stalled"); $finish;
            end
            cmd_stalled=app_en && !(app_cmd==1 ? read_ready : write_ready);
            data_stalled=wdf_valid && !wdf_ready;
            cmd_held={app_cmd,app_addr}; data_held=wdf_data;
            if(app_en && app_cmd==0 && write_ready) begin
                if(app_addr[2:0]!=0) begin $display("FAIL unaligned write"); $finish; end
                saved_addr=app_addr; address_seen=1;
                if(!data_seen) aw_first=aw_first+1;
            end
            if(wdf_valid && wdf_ready) begin
                if(!wdf_end || wdf_mask!=0) begin $display("FAIL write mask/end"); $finish; end
                saved_data=wdf_data; data_seen=1;
                if(!address_seen) w_first=w_first+1;
            end
            if(address_seen && data_seen) begin
                if(saved_addr>=25'h1800000 && saved_addr<25'h1c00000) begin
                    params[(saved_addr-25'h1800000)/8]=saved_data;
                    param_writes=param_writes+1;
                end else if(saved_addr<VIDEO_WORDS*8) begin
                    video[saved_addr/8]=saved_data; video_writes=video_writes+1;
                end else begin $display("FAIL write address outside reservations %h",saved_addr); $finish; end
                address_seen=0; data_seen=0;
            end
            rd_valid<=0; rd_end<=0;
            if(!hold_responses && count>0 && cycle>=deadlines[head] && cycle%5!=2) begin
                rd_valid<=1; rd_end<=1; rd_data<=responses[head];
                head=(head+1)%256; count=count-1;
            end
            if(app_en && app_cmd==1 && read_ready) begin
                if(app_addr[2:0]!=0) begin $display("FAIL unaligned read"); $finish; end
                if(app_addr>=25'h1800000 && app_addr<25'h1c00000) begin
                    responses[tail]=params[(app_addr-25'h1800000)/8] ^ (corrupt_readback ? 128'd1 : 128'd0);
                    param_reads=param_reads+1;
                end else if(app_addr<VIDEO_WORDS*8) begin
                    responses[tail]=video[app_addr/8]; video_reads=video_reads+1;
                end else begin $display("FAIL read address outside reservations %h",app_addr); $finish; end
                deadlines[tail]=cycle+8+(cycle%29);
                tail=(tail+1)%256; count=count+1;
                if(count>max_outstanding) max_outstanding=count;
            end
            cycle=cycle+1;
        end
    end
endmodule
