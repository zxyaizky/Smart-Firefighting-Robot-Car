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

/*******************************uimac_txģ��*********************
--��������������Ƶ�uimac_tx���Ϳ�����ģ��
--1.����ip_arp_txģ�����arp����ip���ݰ���������Ӧ��֡�ײ������Գ��Ȳ���46�ֽڵİ�����ĩβ��0��ʹÿ��������С����Ϊ46�ֽڡ�
--2.ͨ����ģ��crc32_gen����ÿ֡������Ӧ��CRC����ֵ����֡β��
--3.ͨ����ģ��uimac_tx_pause_ctrl���� uimac_rx�������ͣ����ʹ�ܡ���ͣʱ�����ͣmac��ַ�����з����������ơ�
--4.����ip_arp_tx��� phy оƬ����ʱ�Ӻ��û�����ʱ�ӵ�ʱ����ת����������������ⲿ phy оƬ��
*********************************************************************/
`timescale 1ns / 1ps

module uimac_tx #
(
parameter COMMON_CLOCK = 1'b0,
parameter  IFG = 4'd12
)
(  
input 	wire [47:0]  I_mac_local_addr	,	//����MAC��ַ
input 	wire         I_crc32_en			, 	//���ڿ���ģ���Ƿ����������4�ֽڵ�CRC-32��У��ֵ
input 	wire         I_reset			,
//����֡�����ź�
input 	wire         I_mac_tclk			,	//����ʱ��
output 	reg          O_mac_tbusy		,	//MAC����ģ��׼����
input 	wire         I_mac_tvalid		,	//MAC֡������Ч
input 	wire [7 :0]  I_mac_tdata		,	//MAC��Ч����
input 	wire [1 :0]  I_mac_tdata_type	,	//MAC֡����
input 	wire [47:0]  I_mac_tdest_addr	,	//Ŀ��MAC��ַ

input 	wire         I_mac_pause_en		,	//ʹ�ܷ���PAUSE֡
input 	wire [21:0]  I_mac_pause_time	,	//PAUSE��ʱ��
input 	wire [47:0]  I_mac_pause_addr	,	//PAUSE��MAC��ַ

input 	wire         I_gmii_tclk		,	//RGMII����ʱ��
output 	reg          O_gmii_tvalid		,	//GMII����������Ч�ź�
output 	wire [7 :0]  O_gmii_tdata 			//GMII��������	
);

localparam   WAIT_DATA_PACKET 			= 0;
localparam   WRITE_FIFO 				= 2'd1;
localparam   RECORD_DATA_PACKET_INFO  	= 2'd2;
localparam   READ_DATA_PACKET_INFO 		= 3'd1;
localparam   READ_DATA_PACKET 			= 3'd2;
localparam   WAIT_CRC_TRANS_DONE 		= 3'd3;
localparam   ADD_IFG 					= 3'd4;
localparam   WAIT_PAUSE_END 			= 3'd5;

localparam   IP_PACKET 					= 16'h0800;  //������̫��֡���ݵ���IP���ݱ�
localparam   ARP_PACKET 				= 16'h0806;  //����ARP��
localparam   SEND_PAUSE_THRESHOLD 		= 12'd2500;  //����FIFO����2500

reg  [1 :0]  S_WFIFO;
reg  [2 :0]  S_RFIFO;

//֡��Ϣ����ź�
reg          mac_wfifo_en_info;  			//д֡��Ϣ��֡��ϢFIFOʹ��
reg  [47:0]  mac_wfifo_data_addr_info;      //д֡��ϢĿ�ĵ�ַMAC����ϢFIFO
reg  [15:0]  mac_wfifo_data_type_info;      //д֡��Ϣ��֡���͵���ϢFIFO
reg  [10:0]  mac_wfifo_data_cnt_info;       //д֡��Ϣ�������ֽ�������ϢFIFO	
//֡����FIFO����ź�
reg          mac_wfifo_en;					//д֡���ݵ�FIFOʹ��
reg  [7 :0]  mac_wfifo_data;				//д֡���ݵ�FIFO
wire [11:0]  mac_wfifo_data_cnt;			//д֡�����ֽڼ�����

wire [74:0]  mac_rfifo_data_info;           //��֡��Ϣ���ݣ�һ�ζ���Ŀ�ĵ�ַMAC��֡���ͣ������ֽ���
wire         mac_rfifo_empty_info;          //֡��ϢFIFO�գ����ǿմ�����֡��Ϣ��Ҫ����
wire [7 :0]  mac_rfifo_data;				//��FIFO��֡����
reg          mac_rfifo_data_en;				//��FIFO��֡����ʹ��
reg          mac_rfifo_en_info;             //��֡��ϢFIFOʹ��
reg  [10:0]  mac_rfifo_data_cnt;			//��FIFO��֡�����ֽڼ�����
reg  [10:0]  mac_rfifo_data_length;			//�������ϢFIFO����֡���ݳ���
reg  [47:0]  mac_rfifo_data_addr;
reg  [15:0]  ether_type;		   			//��̫��֡����
reg  [3 :0]  inter_gap_cnt;        			//������̫����϶

reg  [7 :0]  mac_tdata; 		   			//����MAC���ݵ�RGMII	
reg          mac_tdata_crc_en;     			//CRCУ����㿪ʼʹ��
reg  [4:0]   data22_cnt;
reg  [4:0]   data22_shift_cnt;	
reg  [2 :0]  crc_cnt;						//crc������
reg          crc_read;             			//CRCУ�������俪ʼʹ��
wire [7 :0]  crc32_chksum;					//crcУ��
wire [7: 0]  mac_tdata_shift_out;  			//����λ�Ĵ����Ƴ�����

//��ģ��������MAC֡����д�뵽֡����FIFO,֡��Ϣд�뵽֡��ϢFIFO	 

reg [8:0] rst_cnt;
always@(posedge I_mac_tclk or posedge I_reset)begin
	if(I_reset)
		rst_cnt <= 0;
	else if(rst_cnt[8]==0)
		rst_cnt <= rst_cnt + 1'b1;

end

wire rst = rst_cnt[8] == 0;
always@(posedge I_mac_tclk or posedge rst)begin
	if(rst) begin
		mac_wfifo_en_info 			<= 1'b0;  //MAC��ϢFIFO����MAC����Ϣ����,Ŀ��MAC��ַ����Ч���ݳ��ȡ�֡����д�뵽info fifo�ݴ�
		mac_wfifo_data_addr_info 	<= 48'd0; //MACĿ�ĵ�ַ���ݴ�info fifo
		mac_wfifo_data_type_info  	<= 16'd0; //MAC֡���ͣ��ݴ�info fifo
		mac_wfifo_data_cnt_info 	<= 11'd0; //MAC���ݲ��ַ����ֽڼ�����
		mac_wfifo_en 				<= 1'b0;  //��֡����д�뵽mac_send_fifo����
		mac_wfifo_data 				<= 8'd0;  //��֡����д�뵽mac_send_fifo����
		O_mac_tbusy 				<= 1'b1;  //֪ͨ�ⲿģ�飬��æ
		S_WFIFO 					<= WAIT_DATA_PACKET;
	end
	else begin
        case(S_WFIFO)
			WAIT_DATA_PACKET:begin
				if(mac_wfifo_data_cnt > SEND_PAUSE_THRESHOLD) begin//��FIFOдͨ�����ݼ���������SEND_PAUSE_THRESHOLD���������µ�һ֡���䣬O_mac_tbusyΪ�����źţ�����������(����)
					O_mac_tbusy 			 	 <= 1'b1;
					S_WFIFO 					 <= WAIT_DATA_PACKET;
				end
				else begin						   
					if(I_mac_tvalid) begin										//����Ч���ݷ��͹�����ʼ�������ݲ��һ��浽FIFO
						O_mac_tbusy 		 	 <= 1'b1;						//mac_send æ
						mac_wfifo_en 			 <= 1'b1;						//������д��FIFO
						mac_wfifo_data 			 <= I_mac_tdata;				//д��FIFO������
						mac_wfifo_data_addr_info <= I_mac_tdest_addr;				//Ŀ��MAC��ַ
						mac_wfifo_data_type_info <= {14'd0, I_mac_tdata_type};	//��������	
						mac_wfifo_data_cnt_info  <= mac_wfifo_data_cnt_info + 1'b1;//һ֡���ݵĳ��ȣ���BYTEΪ��λ
						S_WFIFO 				 <= WRITE_FIFO;					//������һ��״̬�ȴ�дFIFO
					end
					else begin
						O_mac_tbusy 			 <= 1'b0;						////mac_send ��æ
						S_WFIFO 				 <= WAIT_DATA_PACKET;
					end
				end
			end
            WRITE_FIFO:begin//д���ݵ�FIFO��FIFO���ڻ���udpЭ�鷢�͹���������
                if(I_mac_tvalid) begin//һ֡���ݽ��չ�����O_gmii_tdata_validʼ��Ϊ�ߵ�ƽ
                     mac_wfifo_en 				<= 1'b1;	//����дFIFO
					 mac_wfifo_data 			<= I_mac_tdata;	//д��FIFO������
					 mac_wfifo_data_cnt_info 	<= mac_wfifo_data_cnt_info + 1'b1;//֡�ֽڼ������ۼ�
					 S_WFIFO 					<= WRITE_FIFO;
				end
                else begin
					if(mac_wfifo_data_cnt_info < 11'd46) begin //��һ��/֡���ݵĳ���С��46�ֽڣ��Զ���0��һ֡������С64bytes���������ݲ�����С46bytes��
						mac_wfifo_en 			<= 1'b1;	
						mac_wfifo_data	 		<= 8'd0;
						mac_wfifo_en_info 		<= 1'b0;
						mac_wfifo_data_cnt_info <= mac_wfifo_data_cnt_info + 1'b1;
						S_WFIFO 				<= WRITE_FIFO;
					end
					else begin //��һ��/֡���ݽ����꣬д��/֡��Ϣ ����/֡��ϢFIFO
						mac_wfifo_en 			<= 1'b0;
						mac_wfifo_data 			<= 8'd0;
						mac_wfifo_en_info 		<= 1'b1;
                        S_WFIFO 				<= RECORD_DATA_PACKET_INFO;	
					end
                end							
			end
            RECORD_DATA_PACKET_INFO:begin//ʱ���У����������д��/֡��Ϣ ����/֡��ϢFIFO
    			mac_wfifo_en_info 				<= 1'b0;
				mac_wfifo_data_addr_info 		<= 48'd0;
				mac_wfifo_data_type_info 		<= 16'd0;
				mac_wfifo_data_cnt_info 		<= 11'd0;
                S_WFIFO 						<= WAIT_DATA_PACKET;
            end
          endcase
    end	
end		 

assign O_gmii_tdata = crc_read ? crc32_chksum : mac_tdata;

//fifo �û�������Ч֡����,һ֡������д��FIFO��FIFO�Ĵ�С������д����Ի���������������д��̫������Ҳ�ᶪ��	


udp_pkg_buf #(
.COMMON_CLOCK(COMMON_CLOCK),
.DATA_WIDTH_W(8), 
.DATA_WIDTH_R(8)  , 
.ADDR_WIDTH_W(12) , 
.ADDR_WIDTH_R(12) , 
.SHOW_AHEAD_EN(1'b1), 
.OUTREG_EN("NOREG")
) 
max_send_fifo(
.rst	(I_reset),  //asynchronous port,active hight
.clkw	(I_mac_tclk),  //write clock
.we		(mac_wfifo_en),  //write enable,active hight
.di		(mac_wfifo_data),  //write data
.clkr	(I_gmii_tclk),  //read clock
.re		(mac_rfifo_data_en),  //read enable,active hight
.dout	(mac_rfifo_data),  //read data
.wrusedw(mac_wfifo_data_cnt),  //stored data number in fifo
.rdusedw() //available data number for read      
) ;


	
//fifo�û�����֡��Ϣ��MACĿ�ĵ�ַ/���ݰ�����/���ݰ�����

udp_pkg_buf #(
.COMMON_CLOCK(COMMON_CLOCK),
.DATA_WIDTH_W(75), 
.DATA_WIDTH_R(75)  , 
.ADDR_WIDTH_W(7) , 
.ADDR_WIDTH_R(7) , 
.SHOW_AHEAD_EN(1'b1), 
.OUTREG_EN("NOREG")
) 
mac_tx_frame_info_fifo(
.rst	(I_reset),  //asynchronous port,active hight
.clkw	(I_mac_tclk),  //write clock
.we		(mac_wfifo_en_info),  //write enable,active hight
.di		({mac_wfifo_data_addr_info, mac_wfifo_data_cnt_info, mac_wfifo_data_type_info}),//write data
.clkr	(I_gmii_tclk),  //read clock
.re		(mac_rfifo_en_info),  //read enable,active hight
.dout	(mac_rfifo_data_info),  //read data
.empty_flag	(mac_rfifo_empty_info)
     
) ;

//22��������λ�Ĵ����飬��̫��֡�ײ���ǰ����7+֡��ʼ�綨��1+Ŀ��MAC��ַ6+ԴMAC��ַ6+��̫������2=22byte
PH1P_LOGIC_SHIFTER#
(
.DATA_WIDTH(8),
.DATA_DEPTH(22),
.INIT_FILE("NONE"),
.SHIFT_TYPE("FIXED")
)
shift_mac_inst
(
.depth({1{1'b0}}),
.dataout(mac_tdata_shift_out),
.clk(I_gmii_tclk),
.en(mac_rfifo_data_en | O_gmii_tvalid),
.datain(mac_rfifo_data)
);

//CRC32У��
crc32_gen  crc32_gen_inst
(
.reset			(I_reset),
.clk			(I_gmii_tclk),
.CRC32_en		(I_crc32_en & mac_tdata_crc_en),         //CRCУ��ʹ���ź�
.CRC32_init		( ~O_gmii_tvalid ),              //CRCУ��ֵ��ʼ���ź�
.CRC_read		(crc_read),
//.CRC32_valid( crc32_en & (I_mac_tvalid | O_gmii_tvalid)),      //CRCУ��ֵά����Ч
.data			(mac_tdata),	 
.CRC_out		(crc32_chksum)	 
);

//MAC���Ͷˣ�PAUSE������ģ��
wire [47:0]  pause_dst_mac_addr;
wire         pause_flag;
uimac_tx_pause_ctrl mac_tx_pause_ctrl_inst 
(
.I_clk					(I_gmii_tclk), 
.I_reset				(I_reset), 
.I_mac_state			(S_RFIFO), 
.I_mac_pause_en			(I_mac_pause_en), 
.I_mac_pause_time		(I_mac_pause_time), 
.I_mac_pause_addr		(I_mac_pause_addr), 
.O_pause_dst_mac_addr	(pause_dst_mac_addr), 
.O_pause_flag			(pause_flag)
);






//���MAC֡�ķ��ͣ��õ���ǰ���֡����FIFO����Ϣ����FIFO,�Լ�SHIFT�Ĵ���(ʵ��MAC֡ͷ��Ϣ����)
always@(posedge I_gmii_tclk or posedge I_reset) begin
    if(I_reset) begin
        mac_rfifo_data_en 			<= 1'b0;
		mac_rfifo_en_info 			<= 1'b0;
		mac_rfifo_data_cnt 			<= 11'd0;
		mac_rfifo_data_length 		<= 11'd0;
		mac_rfifo_data_addr 		<= 48'd0;
		ether_type  				<= 16'd0;
		inter_gap_cnt 				<= 4'd0;
		S_RFIFO 					<= WAIT_DATA_PACKET;
	end
    else begin
         case(S_RFIFO)
            WAIT_DATA_PACKET:begin
                //����Դ������е�����ģ�Ĭ��FIFO��FWTģʽ������ᵼ�¸���һ��FIFO����һ�ε�ֵ��ʧ
                if(!mac_rfifo_empty_info)	begin //֡��ϢFIFO�ǿմ�����֡��Ҫ����
                    mac_rfifo_en_info 		<= 1'b1; //FIFO�����õ�FWTģʽ�����ֻ��1֡���ݣ���ôFIFO�����գ�����FIFO������µ���һ֡
					S_RFIFO 				<= READ_DATA_PACKET_INFO;//
				end
				else
					S_RFIFO <= WAIT_DATA_PACKET;
			end
			READ_DATA_PACKET_INFO:begin 	
				if(mac_rfifo_data_info[15:0] == 16'h0002) begin		//���͵�ARP������ΪӦ���
					ether_type  			<= ARP_PACKET;
					mac_rfifo_data_addr 	<= mac_rfifo_data_info[74:27];//MAC��ַ
				end
				else if(mac_rfifo_data_info[15:0] == 16'h0003) begin
					ether_type  			<= ARP_PACKET;
					mac_rfifo_data_addr 	<= 48'hffffffffffff; //�㲥��ַ
				end
				else begin
					ether_type  			<= IP_PACKET; //IP ��
					mac_rfifo_data_addr		<= mac_rfifo_data_info[74:27];//MAC��ַ
				end
					mac_rfifo_data_length 	<= mac_rfifo_data_info[26:16];//���ݳ���
					mac_rfifo_en_info 	  	<= 1'b0;
						
				if(pause_flag && mac_rfifo_data_info[74:27] == pause_dst_mac_addr) begin//�������PAUSE֡��Ҫ���ͣ�����Ŀ�ĵ�ַ�͵�ǰĿ�ĵ�ַһ��
					mac_rfifo_data_en 		<= 1'b0; 			//PAUSE ֡�׶β���FIFO������				
					S_RFIFO 				<= WAIT_PAUSE_END;  //�ȴ�PAUSE�����ƽ���
				end
				else begin                
					mac_rfifo_data_en 		<= 1'b1;						
					S_RFIFO 				<= READ_DATA_PACKET;
				end
			end
			READ_DATA_PACKET:begin
                if(mac_rfifo_data_cnt == (mac_rfifo_data_length - 1'b1)) begin	//һ֡���ݴ�FIFO����
                    mac_rfifo_data_en 		<= 1'b0;
					mac_rfifo_data_length 	<= 11'd0;
					mac_rfifo_data_cnt 		<= 11'd0;
					mac_rfifo_data_addr 	<= 48'd0;
					ether_type  			<= 16'd0;
					S_RFIFO 				<= WAIT_CRC_TRANS_DONE;
                end
				else begin
						mac_rfifo_data_en 	<= 1'b1;
						mac_rfifo_data_cnt 	<= mac_rfifo_data_cnt + 1'b1;
						S_RFIFO 			<= READ_DATA_PACKET;
				end
			end
			WAIT_CRC_TRANS_DONE:begin//�ȴ����ڷ��͵�MAC���ݰ�CRC�������
				if(crc_cnt)
					S_RFIFO 				<= WAIT_CRC_TRANS_DONE;
				else
					S_RFIFO 				<= ADD_IFG;
			end
			ADD_IFG:begin//���ݰ����ͺ󣬲���֡�����2֮֡��������ҪIFGmini=96bit/speed,����1000M 96ns 100M 960ns 10M 9600ns
				if(inter_gap_cnt == (IFG - 4'd4)) begin  //������С֡������ڣ��ڴ�״̬����mac_tx_pause_ctrl ������ģ���Է���PAUSE֡����ȥ4'd4�Ǳ������������󣬾�����һ֡����ʵ����Ҫ��Ҫ����4��ʱ������
					inter_gap_cnt 			<= 4'd0;
					S_RFIFO 				<= WAIT_DATA_PACKET;//����WAIT_DATA_PACKET
				end
				else begin
					inter_gap_cnt 			<= inter_gap_cnt + 1'b1;
					S_RFIFO	 				<= ADD_IFG;
				end
			end
			WAIT_PAUSE_END:begin//�ȴ���ͣ���������´�������
				if(pause_flag) begin //pause ����
					mac_rfifo_data_en 		<= 1'b0;					   
					S_RFIFO 				<= WAIT_PAUSE_END;
				end
				else begin
					mac_rfifo_data_en 		<= 1'b1;//��ͣ�����󣬼�����֡FIFO������
					S_RFIFO 				<= READ_DATA_PACKET;
				end
			end
			endcase
		end
	end
           						
//��ģ�����MAC���ݷ��͵�RGMIIģ��	
always@(posedge I_gmii_tclk or posedge I_reset)begin
	if(I_reset)begin
		O_gmii_tvalid 		<= 1'b0;
		mac_tdata 			<= 8'h00;
		mac_tdata_crc_en 	<= 1'b0;
		data22_cnt 			<= 5'd0;
		data22_shift_cnt 	<= 5'd22;
		crc_cnt 			<= 3'd4;
		crc_read 			<= 1'b0;
	end
	else if(mac_rfifo_data_en)begin
		case(data22_cnt) //����׶���λ�Ĵ����������ݵ����
		//����7��ǰ����
		0:  begin mac_tdata <= 8'h55; 					 	data22_cnt <= data22_cnt + 1'b1; O_gmii_tvalid <= 1'b1; data22_shift_cnt <= 5'd22; end
		1:  begin mac_tdata <= 8'h55; 					 	data22_cnt <= data22_cnt + 1'b1; end
		2:  begin mac_tdata <= 8'h55; 						data22_cnt <= data22_cnt + 1'b1; end
		3:  begin mac_tdata <= 8'h55; 						data22_cnt <= data22_cnt + 1'b1; end
		4:  begin mac_tdata <= 8'h55; 					 	data22_cnt <= data22_cnt + 1'b1; end
		5:  begin mac_tdata <= 8'h55; 					 	data22_cnt <= data22_cnt + 1'b1; end
		6:  begin mac_tdata <= 8'h55; 						data22_cnt <= data22_cnt + 1'b1; end
		7:  begin mac_tdata <= 8'hd5; 						data22_cnt <= data22_cnt + 1'b1; end  //����֡��ʼ�綨��
		8:  begin mac_tdata <= mac_rfifo_data_addr[47:40]; 	data22_cnt <= data22_cnt + 1'b1; mac_tdata_crc_en <= 1'b1; end //��ʼ����CRCУ��ֵ
		9:  begin mac_tdata <= mac_rfifo_data_addr[39:32]; 	data22_cnt <= data22_cnt + 1'b1; end
		10: begin mac_tdata <= mac_rfifo_data_addr[31:24]; 	data22_cnt <= data22_cnt + 1'b1; end
		11: begin mac_tdata <= mac_rfifo_data_addr[23:16]; 	data22_cnt <= data22_cnt + 1'b1; end
		12: begin mac_tdata <= mac_rfifo_data_addr[15:8] ; 	data22_cnt <= data22_cnt + 1'b1; end
		13: begin mac_tdata <= mac_rfifo_data_addr[7:0]  ; 	data22_cnt <= data22_cnt + 1'b1; end
		14: begin mac_tdata <= I_mac_local_addr[47:40]; 	data22_cnt <= data22_cnt + 1'b1; end
		15: begin mac_tdata <= I_mac_local_addr[39:32]; 	data22_cnt <= data22_cnt + 1'b1; end
		16: begin mac_tdata <= I_mac_local_addr[31:24]; 	data22_cnt <= data22_cnt + 1'b1; end
		17: begin mac_tdata <= I_mac_local_addr[23:16]; 	data22_cnt <= data22_cnt + 1'b1; end
		18: begin mac_tdata <= I_mac_local_addr[15:8] ; 	data22_cnt <= data22_cnt + 1'b1; end
		19: begin mac_tdata <= I_mac_local_addr[7:0]  ; 	data22_cnt <= data22_cnt + 1'b1; end
		20: begin mac_tdata <= ether_type[15:8]; 		 	data22_cnt <= data22_cnt + 1'b1; end
		21: begin mac_tdata <= ether_type[7:0]; 		 	data22_cnt <= data22_cnt + 1'b1; end
		22: begin mac_tdata <= mac_tdata_shift_out; end //����λ�Ĵ���ȡ����
		default: data22_cnt <= 5'd0;
		endcase
	end
	else if(!mac_rfifo_data_en)begin //tmac_en=1�׶λ��ȡmac_tx_frame_info_fifo�����е�����д����λ�Ĵ�������tmac_en=0����λ�Ĵ���ʣ��22����Ч������Ҫ�Ƴ�
		if(data22_shift_cnt != 5'd0)  begin //����λ�Ĵ������е�ʣ��22�����ݶ��� 
			mac_tdata 			<= mac_tdata_shift_out;
			data22_shift_cnt	<= data22_shift_cnt -1'b1;
		end
		else begin//if(data22_shift_cnt == 5'd0)  
			if(I_crc32_en==1'b1 && O_gmii_tvalid == 1'b1)begin     //��ʼ����֡��CRC32У��ֵ
				O_gmii_tvalid 		<= 1'b1;
				data22_cnt 			<= 5'd0;
				mac_tdata_crc_en 	<= 1'b0;           //ֹͣCRC����
				crc_read 			<= 1'b1;           //��ʼ����CRC32У��ֵ
				if(crc_cnt!=3'd0)
					crc_cnt 		<= crc_cnt - 1'b1;
				else begin
					O_gmii_tvalid 	<= 1'b0;
					crc_read 		<= 1'b0;		//4�ֽڵ�CRCУ��ֵ�������						
					crc_cnt 		<= 3'd4;
				end
			end
			else begin                          	//������CRC32У�飬���贫��У��ֵ	  
				O_gmii_tvalid 		<= 1'b0;
				data22_shift_cnt 	<= 5'd0;
			end						    						  
		end
	end
end

	 
endmodule



