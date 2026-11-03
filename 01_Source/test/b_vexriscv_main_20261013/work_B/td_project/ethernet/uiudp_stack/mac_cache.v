/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2024-06-24
*Module Name:
*File Name:
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.1
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_ system internal signal
*5) _n activ low
*6) _dg debug signal 
*7) _r delay or register
*8) _s state mechine
*********************************************************************/

/*******************************xxxxģ��*********************
--��������������Ƶ�xxxxxģ��
1.
2.
3.
4.
*********************************************************************/
`timescale 1ns/1ps
module	mac_cache
(
	input	wire				I_wclk,
	input	wire				I_reset,
	input	wire				I_wen,
	input	wire	[31:0]		I_wip_addr,
	input	wire	[47:0]		I_wmac_addr,

	input	wire				I_rclk,
	input	wire				I_ren,
	input	wire	[31:0]		I_rip_addr,
	output	reg		[47:0]		O_rmac_addr,
	output	reg					O_rmac_done
);

reg				mac_cache_flag		[0:3];
reg		[31:0]	ip_address_cache	[0:3];
(* ram_style = "dram" *) reg [47:0] mac_address_cache	[0:3];
reg		[1:0]	index;

// 2026-10-13: Shared hit decode and per-entry write enables. Capacity,
// round-robin replacement, update priority and read latency are unchanged.
wire [3:0] write_hit;
wire [3:0] read_hit;
wire [3:0] read_select;
wire write_miss = !(|write_hit);
genvar entry;
generate
    for (entry = 0; entry < 4; entry = entry + 1) begin : cache_entry
        assign write_hit[entry] = mac_cache_flag[entry]
            && ip_address_cache[entry] == I_wip_addr;
        assign read_hit[entry] = mac_cache_flag[entry]
            && ip_address_cache[entry] == I_rip_addr;
        wire allocate_entry = write_miss && index == entry;
        wire update_entry;
        if (entry == 0) begin : first
            assign update_entry = write_hit[entry];
            assign read_select[entry] = read_hit[entry];
        end else begin : remaining
            assign update_entry = write_hit[entry] && !(|write_hit[entry-1:0]);
            assign read_select[entry] = read_hit[entry] && !(|read_hit[entry-1:0]);
        end
        always @(posedge I_wclk or posedge I_reset) begin
            if (I_reset) begin
                mac_cache_flag[entry] <= 1'b0;
                ip_address_cache[entry] <= 32'd0;
            end else if (I_wen) begin
                if (allocate_entry) begin
                    mac_cache_flag[entry] <= 1'b1;
                    ip_address_cache[entry] <= I_wip_addr;
                end
            end
        end
    end
endgenerate
wire [1:0] write_entry = write_miss ? index :
    (write_hit[0] ? 2'd0 : (write_hit[1] ? 2'd1 : (write_hit[2] ? 2'd2 : 2'd3)));
wire [1:0] read_entry = read_select[0] ? 2'd0 :
    (read_select[1] ? 2'd1 : (read_select[2] ? 2'd2 : 2'd3));
// The valid flags hide stale storage after reset. No reset on the MAC table
// allows inference of a single distributed RAM write port and read port.
always @(posedge I_wclk) begin
    if (!I_reset && I_wen) mac_address_cache[write_entry] <= I_wmac_addr;
end
always @(posedge I_wclk or posedge I_reset) begin
    if (I_reset) index <= 2'd0;
    else if (I_wen && write_miss) index <= index + 1'b1;
end
always @(posedge I_rclk or posedge I_reset) begin
    if (I_reset) begin
        O_rmac_addr <= 48'd0;
        O_rmac_done <= 1'b0;
    end else begin
        O_rmac_done <= I_ren;
        if (I_ren) begin
            if (|read_select) O_rmac_addr <= mac_address_cache[read_entry];
            else O_rmac_addr <= 48'd0;
        end
    end
end

endmodule
