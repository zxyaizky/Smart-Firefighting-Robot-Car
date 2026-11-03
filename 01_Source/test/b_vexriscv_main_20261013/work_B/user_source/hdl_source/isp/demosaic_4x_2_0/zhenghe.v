`timescale 1ns / 1ps
/*****************************************************************
Company : MiLianKe Electronic Technology Co., Ltd.
WebSite:https://www.milianke.com
TechWeb:https://www.uisrc.com
tmall-shop:https://milianke.tmall.com
jd-shop:https://milianke.jd.com
taobao-shop: https://milianke.taobao.com
Description: 
The reference demo provided by Milianke is only used for learning. 
We cannot ensure that the demo itself is free of bugs, so users 
should be responsible for the technical problems and consequences
caused by the use of their own products.
@Author      :   XiaoQingquan 
@Time        :   2024/10 
version:     :   1.0
@Description :   使用BRAM进行FIFO整合，并且不影响下一帧的数据传输
*****************************************************************/


module zhenghe#(
    parameter [12:0] IMG_WIDTH  = 640,
    parameter [12:0] IMG_HEIGHT = 480,
    parameter [8:0]  DATA_WIDTH = 96 ,
    parameter [8:0]  data_complete_delay = 50 //每行BRAM完成数据传输后与这行最后一个数据的距离
) 
(
    input                   I_clk  ,
    input                   I_rst_n,

    input                   I_tlast  ,
    input                   I_tuser  ,
    input [DATA_WIDTH-1:0]  I_tdata  ,
    input                   I_tvalid , 

    output reg              O_tlast  ,
    output reg              O_tuser  ,
    output [DATA_WIDTH-1:0] O_tdata  ,
    output reg              O_tvalid,
    output wire [4:0] O_frame_diag
);
    // 2026-10-11 Codex v2: launch reads from accepted line EOF, rather
    // than a previous frame's estimated valid duration. RAW10 contains gaps.
    // Existing single-row RAM and both port interfaces remain unchanged.
    localparam [10:0] LAST_WORD = (IMG_WIDTH >> 2) - 1;
    localparam [13:0] LAST_ROW = IMG_HEIGHT - 1;
    localparam [1:0] IDLE = 2'd0, WAIT_ROW = 2'd1,
                     READ_ROW = 2'd2, WAIT_REPLAY = 2'd3;
    reg [10:0] addra, addrb;
    reg valid_r0, last_r0;
    reg [DATA_WIDTH-1:0] data_d0;
    reg [13:0] write_row;
    reg [1:0] read_state;
    reg [8:0] wait_count;
    reg read_first_row, read_last_row, replay_read;
    wire [DATA_WIDTH-1:0] data_d;
    // Read-only probes. No counter, read-job, RAM or video qualifier is changed.
    assign O_frame_diag[0] = (write_row == IMG_HEIGHT);
    assign O_frame_diag[1] = read_last_row;
    assign O_frame_diag[2] = replay_read;
    assign O_frame_diag[3] = (read_state == IDLE);
    assign O_frame_diag[4] = (write_row == LAST_ROW);

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            valid_r0 <= 0;
            last_r0 <= 0;
            data_d0 <= 0;
            addra <= 0;
            write_row <= 0;
        end else begin
            valid_r0 <= I_tvalid;
            last_r0 <= I_tvalid && I_tlast;
            data_d0 <= I_tdata;
            if (I_tuser) begin
                addra <= 0;
                write_row <= 0;
            end else begin
                if (valid_r0) addra <= (addra == LAST_WORD) ? 0 : addra + 1'b1;
                if (last_r0) write_row <= write_row + 1'b1;
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            addrb <= 0;
            read_state <= IDLE;
            wait_count <= 0;
            read_first_row <= 0;
            read_last_row <= 0;
            replay_read <= 0;
            O_tvalid <= 0;
            O_tlast <= 0;
            O_tuser <= 0;
        end else if (I_tuser) begin
            // Discard an unfinished old read job on a new source frame.
            addrb <= 0;
            read_state <= IDLE;
            wait_count <= 0;
            read_first_row <= 0;
            read_last_row <= 0;
            replay_read <= 0;
            O_tvalid <= 0;
            O_tlast <= 0;
            O_tuser <= 0;
        end else begin
            // Registered qualifiers match the synchronous NOREG RAM read.
            O_tvalid <= (read_state == READ_ROW);
            O_tlast <= (read_state == READ_ROW && addrb == LAST_WORD);
            O_tuser <= (read_state == READ_ROW && addrb == 0 &&
                        read_first_row && !replay_read);
            case (read_state)
                IDLE: begin
                    if (last_r0) begin
                        addrb <= 0;
                        read_first_row <= (write_row == 0);
                        read_last_row <= (write_row == LAST_ROW);
                        replay_read <= 0;
                        wait_count <= data_complete_delay;
                        read_state <= (data_complete_delay == 0) ? READ_ROW : WAIT_ROW;
                    end
                end
                WAIT_ROW, WAIT_REPLAY: begin
                    if (wait_count <= 1) begin
                        wait_count <= 0;
                        read_state <= READ_ROW;
                    end else wait_count <= wait_count - 1'b1;
                end
                READ_ROW: begin
                    addrb <= (addrb == LAST_WORD) ? 0 : addrb + 1'b1;
                    if (addrb == LAST_WORD) begin
                        if (read_last_row && !replay_read) begin
                            // The real last line has been fully written AND read.
                            // Replay it through the existing line delays, leaving
                            // a short gap for the matrix/packing pipeline to drain.
                            replay_read <= 1;
                            wait_count <= data_complete_delay;
                            read_state <= (data_complete_delay == 0) ? READ_ROW : WAIT_REPLAY;
                        end else read_state <= IDLE;
                    end
                end
                default: read_state <= IDLE;
            endcase
        end
    end

    blk_mem_gen_zhenghe blk_mem_gen_zhenghe_d1 (
        .clka(I_clk), .wea(valid_r0), .addra(addra), .dia(data_d0),
        .clkb(I_clk), .addrb(addrb), .dob(data_d)
    );
    assign O_tdata = data_d;
endmodule
