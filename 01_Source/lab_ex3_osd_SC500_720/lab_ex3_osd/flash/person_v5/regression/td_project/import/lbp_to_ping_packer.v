// Packs either legacy CHW bytes or streamed RGB samples into 16-bank PING.
`timescale 1ns/1ps
module lbp_to_ping_packer #(
    parameter FRAME_PIXELS=3*160*120,
    parameter STREAMED_RGB=0
)(
    input wire clk,input wire rst_n,input wire i_enable,
    input wire i_frame_valid,input wire i_lbp_valid,input wire [7:0] i_lbp_pixel,
    output reg o_preload_wr_en,output reg [12:0] o_preload_wr_addr,
    output reg [15:0] o_preload_wr_mask,output reg [127:0] o_preload_wr_data,
    output reg o_preload_done,output wire [15:0] o_dbg_pixel_count,
    output wire o_loading,output wire o_dbg_final_write_pending
);
generate
if(!STREAMED_RGB) begin: G_LEGACY_CHW
    reg [15:0] r_pixel_count;
    reg [127:0] r_pack_data;
    reg r_final_write_pending,r_frame_d,r_accept;
    wire [3:0] w_lane=r_pixel_count[3:0];
    wire w_accept=r_frame_d ? r_accept : i_enable;
    wire [127:0] w_pack_with_current=
        r_pack_data|({120'd0,i_lbp_pixel}<<(w_lane*8));
    assign o_dbg_pixel_count=r_pixel_count;
    assign o_dbg_final_write_pending=r_final_write_pending;
    assign o_loading=r_accept||r_final_write_pending||o_preload_done;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            r_pixel_count<=0; r_frame_d<=0; r_accept<=0; r_pack_data<=0;
            r_final_write_pending<=0; o_preload_wr_en<=0;
            o_preload_wr_addr<=0; o_preload_wr_mask<=0;
            o_preload_wr_data<=0; o_preload_done<=0;
        end else begin
            r_frame_d<=i_frame_valid;
            if(i_frame_valid&&!r_frame_d) r_accept<=i_enable;
            o_preload_wr_en<=0; o_preload_done<=0;
            if(r_final_write_pending) begin
                r_final_write_pending<=0; o_preload_done<=1; r_accept<=0;
            end else if(!i_frame_valid) begin
                r_pixel_count<=0; r_accept<=0; r_pack_data<=0;
                r_final_write_pending<=0;
            end else if(w_accept&&i_lbp_valid&&r_pixel_count<FRAME_PIXELS) begin
                if(w_lane==15||r_pixel_count==FRAME_PIXELS-1) begin
                    o_preload_wr_en<=1;
                    o_preload_wr_addr<={1'b0,r_pixel_count[15:4]};
                    o_preload_wr_mask<=16'hffff>>(15-w_lane);
                    o_preload_wr_data<=w_pack_with_current;
                    r_pack_data<=0; r_pixel_count<=r_pixel_count+1'b1;
                    if(r_pixel_count==FRAME_PIXELS-1)
                        r_final_write_pending<=1;
                end else begin
                    r_pack_data<=w_pack_with_current;
                    r_pixel_count<=r_pixel_count+1'b1;
                end
            end
        end
    end
end else begin: G_STREAMED_RGB
    // On frame admission first clear all 3600 words, thereby creating the top
    // and bottom 15 black rows.  Incoming R,G,B bytes then update one byte lane
    // at CHW word bases 150, 1350 and 2550 respectively.
    reg r_frame_d,r_accept,r_clearing,r_final_write_pending;
    reg r_stream_complete;
    reg [11:0] r_clear_addr;
    reg [13:0] r_sample_count;
    reg [1:0] r_channel;
    reg [15:0] r_debug_count;
    wire [11:0] channel_base=(r_channel==0)?12'd150:
                              (r_channel==1)?12'd1350:12'd2550;
    wire [12:0] sample_word={1'b0,channel_base}+
                            {3'd0,r_sample_count[13:4]};
    wire [3:0] sample_lane=r_sample_count[3:0];
    assign o_dbg_pixel_count=r_debug_count;
    assign o_dbg_final_write_pending=r_final_write_pending;
    assign o_loading=r_accept||r_clearing||r_final_write_pending||o_preload_done;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            r_frame_d<=0; r_accept<=0; r_clearing<=0; r_clear_addr<=0;
            r_sample_count<=0; r_channel<=0; r_debug_count<=0;
            r_stream_complete<=0; r_final_write_pending<=0; o_preload_wr_en<=0;
            o_preload_wr_addr<=0; o_preload_wr_mask<=0;
            o_preload_wr_data<=0; o_preload_done<=0;
        end else begin
            r_frame_d<=i_frame_valid;
            o_preload_wr_en<=0;
            o_preload_done<=0;
            if(i_frame_valid&&!r_frame_d) begin
                r_accept<=i_enable;
                r_clearing<=i_enable;
                r_clear_addr<=0; r_sample_count<=0; r_channel<=0;
                r_debug_count<=0; r_stream_complete<=0;
                r_final_write_pending<=0;
            end else if(r_final_write_pending) begin
                r_final_write_pending<=0;
                o_preload_done<=1;
                r_accept<=0;
                r_stream_complete<=0;
                r_debug_count<=16'd57600;
            end else if(!i_frame_valid) begin
                r_clearing<=0; r_clear_addr<=0;
                if(r_accept&&r_stream_complete) begin
                    r_final_write_pending<=1;
                end else begin
                    r_accept<=0; r_sample_count<=0; r_channel<=0;
                    r_stream_complete<=0;
                    if(!r_final_write_pending) r_debug_count<=0;
                end
            end else if(r_accept&&r_clearing) begin
                o_preload_wr_en<=1;
                o_preload_wr_addr<={1'b0,r_clear_addr};
                o_preload_wr_mask<=16'hffff;
                o_preload_wr_data<=128'd0;
                if(r_clear_addr==3599) r_clearing<=0;
                else r_clear_addr<=r_clear_addr+1'b1;
            end else if(r_accept&&i_lbp_valid&&r_sample_count<14400) begin
                o_preload_wr_en<=1;
                o_preload_wr_addr<=sample_word;
                o_preload_wr_mask<=16'h0001<<sample_lane;
                o_preload_wr_data<={120'd0,i_lbp_pixel}<<(sample_lane*8);
                r_debug_count<=r_debug_count+1'b1;
                if(r_channel==2) begin
                    r_channel<=0;
                    if(r_sample_count==14399) begin
                        r_sample_count<=r_sample_count;
                        r_stream_complete<=1;
                    end else r_sample_count<=r_sample_count+1'b1;
                end else r_channel<=r_channel+1'b1;
            end
        end
    end
end
endgenerate
endmodule
