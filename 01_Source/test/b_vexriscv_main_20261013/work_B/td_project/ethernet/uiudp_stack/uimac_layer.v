/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2022/12/23
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

/*******************************uimac_layerģ��*********************
--��������������Ƶ�uimac_layer���Ϳ�����ģ��
uimac_layer��Ҫ��ɶ�ip���ݰ���arp����macЭ����ƣ�������������ģ�� uimac_tx��uimac_rx���ֱ���� mac ֡�ą��ͺͽ��ա�
���⣬uimac_rx ���� mac ��ͣ֡������ģ��uimac_tx_pause_ctrl��CRC ��У����ģ�� CRC32_check����ͨ�� receive_fifo ��� phy �ӿ�ʱ�������û��ӿ�ʱ�����ת����
*********************************************************************/

`timescale 1ns / 1ps

module uimac_layer #
(
parameter           TX_COMMON_CLOCK = 1'b0,
parameter           CRC_GEN_EN          = 1'b1,
parameter           INTER_FRAME_GAP     = 4'd12
)
(	
input  wire [47:0]  I_mac_local_addr,   //MAC���ص�ַ	
input  wire         I_mac_reset,	
//���յ�MAC�����ݸ��ϲ�Э���
input  wire         I_mac_rclk,         //MAC������Ч����ʱ��
output wire         O_mac_rvalid,       //MAC����������Ч�ź�
output wire [7 :0]  O_mac_rdata,        //MAC��������
output wire [15:0]  O_mac_rdata_type,   //MAC���յ������ݰ�����
output wire         O_mac_rdata_error,  //MAC����֡����
//�����ϲ�Э������ݸ�MAC��
input  wire         I_mac_tclk,         //MAC��������ʱ��
input  wire         I_mac_tvalid,       //MAC������������
input  wire [7 :0]  I_mac_tdata,        //MAC������Ч����
input  wire [1 :0]  I_mac_tdata_type,   //MAC������������
input  wire [47:0]  I_mac_tdest_addr,   //MACĿ�ĵ�ַ
output wire         O_mac_tbusy,        //MAC����ģ���Ƿ��ڷ���æ

//RGMIIתGMIIģ�������
input  wire         I_gmii_rclk,        //RGMII ����ʱ�� 
input  wire         I_gmii_rvalid,      //RGMII����������Ч�ź� 
input  wire [7 :0]  I_gmii_rdata,	    //RGMII������Ч����
//RGMIIתGMIIģ�����
input  wire         I_gmii_tclk,        //GMII ���ʱ��
output wire         O_gmii_tvalid,      //����� RGMII ģ��
output wire [7 :0]  O_gmii_tdata        //����� RGMII ģ��
		
);

//PAUSE��ͣ֡�����źţ�������ģ����յ�����һ���豸���͵�PAUSE֡������uimac_txģ����ͣһ��ʱ���ٷ��ͣ�
wire           mac_pause_en;
wire [21:0]    mac_pause_time; 
wire [47:0]    mac_pause_addr;

reg					mac_rfifo_pause_ren;
wire		[47:0]		mac_rfifo_pause_addr;
wire		[21:0]		mac_rfifo_pause_time;

wire	[69:0]	rfifo_dout;
wire			rdempty;
reg				STATE;


//MAC����ģ��
uimac_tx #
(
.COMMON_CLOCK (TX_COMMON_CLOCK),
.IFG                        (INTER_FRAME_GAP    )
)
mac_tx_inst
(
.I_mac_local_addr           (I_mac_local_addr   ),
.I_crc32_en		            (CRC_GEN_EN         ), 
.I_reset					(I_mac_reset        ), 
//����֡�����ź�
.I_mac_tclk			        (I_mac_tclk         ), 
.O_mac_tbusy                (O_mac_tbusy        ),    //MAC����ģ���Ƿ��ڷ���æ��ͬʱ��0��1�������ֳɹ�
.I_mac_tvalid			    (I_mac_tvalid       ),    //֡������Ч
.I_mac_tdata				(I_mac_tdata        ),    //��Ч����
.I_mac_tdata_type			(I_mac_tdata_type   ),    //֡����
.I_mac_tdest_addr	        (I_mac_tdest_addr    ),    //Ŀ��MAC��ַ
//PAUSE ֡�����ź�
.I_mac_pause_en		        (mac_rfifo_pause_ren    ),    //ʹ�ܷ���PAUSE֡
.I_mac_pause_time	        (mac_rfifo_pause_time   ),    //PAUSE��ʱ��
.I_mac_pause_addr           (mac_rfifo_pause_addr   ),    //PAUSE��MAC��ַ
//MAC RGMII�����ź�
.I_gmii_tclk		        (I_gmii_tclk        ),    //RGMII����ʱ��
.O_gmii_tvalid	            (O_gmii_tvalid      ),    //RGMII����������Ч  
.O_gmii_tdata				(O_gmii_tdata       )     //RGMII��������
);
	 
udp_pkg_buf #(
.DATA_WIDTH_W(70), 
.DATA_WIDTH_R(70)  , 
.ADDR_WIDTH_W(7) , 
.ADDR_WIDTH_R(7) , 
.SHOW_AHEAD_EN(1'b1), 
.OUTREG_EN("NOREG")
) 
udp_pkg_buf_inst(
.rst	(I_mac_reset),  //asynchronous port,active hight
.clkw	(I_gmii_rclk),  //write clock
.we		(mac_pause_en),  //write enable,active hight
.di		({mac_pause_addr[47:0], mac_pause_time[21:0]}),  //write data
.clkr	(I_gmii_tclk),  //read clock
.re		(mac_rfifo_pause_ren),  //read enable,active hight
.dout	(rfifo_dout),  //read data
.empty_flag	(rdempty)    
) ;

assign	mac_rfifo_pause_addr	=	rfifo_dout[69:22];
assign	mac_rfifo_pause_time	=	rfifo_dout[21:0];

always@(posedge I_gmii_tclk or posedge I_mac_reset) begin
	if(I_mac_reset) begin
		mac_rfifo_pause_ren		<=	1'b0;
		STATE					<=	1'b0;
	end
	else begin
		case(STATE)
			0:begin
				if(~rdempty) begin
					mac_rfifo_pause_ren		<=	1'b1;
					STATE					<=	1'b1;
				end
				else begin
					mac_rfifo_pause_ren		<=	1'b0;
					STATE					<=	1'b0;	
				end
			end
			1:begin
				mac_rfifo_pause_ren		<=	1'b0;
				if(rdempty)
					STATE	<=	1'b0;
				else
					STATE	<=	1'b1;	
			end				
		endcase
	end
end

//MAC����ģ��
uimac_rx mac_rx_inst
(
.I_mac_local_addr           (I_mac_local_addr   ),
.I_crc32_en			        (CRC_GEN_EN         ),    //CRCУ��ʹ��
.I_reset					(I_mac_reset        ),    //ϵͳ��λ

.I_mac_rclk			        (I_mac_rclk         ),    //MAC����ʱ�ӣ�Ϊ�û���ʱ��
.O_mac_rvalid		        (O_mac_rvalid       ),    //MAC����������Ч�ź�
.O_mac_rdata				(O_mac_rdata        ),    //MAC����������Ч�ź�
.O_mac_rdata_type			(O_mac_rdata_type   ),    //֡����
.O_mac_rdata_error			(O_mac_rdata_error  ),    //֡error
//��Զ�������������������ݿ������󱾵�����PAUSE��ͣʱ�䣬����������յ�Զ��������PAUSE֡
.O_mac_pause_en		        (mac_pause_en       ),    //����PAUSEʹ��
.O_mac_pause_time	        (mac_pause_time     ),    //����PAUSEʱ��
.O_mac_pause_addr           (mac_pause_addr     ),    //����PAUSE��MAC
//MAC RGMIIģ������
.I_gmii_rclk	            (I_gmii_rclk        ),    //PHYʱ�� 
.I_gmii_rvalid			    (I_gmii_rvalid      ),    //GMII���յ���Ч�����ź�
.I_gmii_rdata				(I_gmii_rdata       )   //GMII���յ���Ч�����ź�
);

endmodule

