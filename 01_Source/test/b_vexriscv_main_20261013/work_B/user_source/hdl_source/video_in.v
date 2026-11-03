// Change Log: 2026-10-11 Codex v3.2 Expose existing word count for passive diagnostics.
// Change Log: 2026-10-11 Codex v3.1 Passive capture status port; data path unchanged.
// Change Log: 2026-10-02 Codex v3.0 Reuse capture IDs; commit stereo page tags.


module video_in #(parameter FRAME_WORDS = 172800) (
    input wire         I_rst_n,

    input wire         I_camera_clk,
    input wire         I_camera_frame_start,
    input wire         I_camera_valid,
    input wire[127:0]  I_camera_data,
    input wire         I_mipi_rx_error,

    input wire         I_ddr_clk,
    input wire         I_left_sync_event,
    input wire [15:0]  I_left_sync_id,
    output wire        O_left_write_frame_start,
    output wire [1:0]  O_left_write_page,
    output wire        O_left_selected_valid,
    output wire [15:0] O_left_selected_sync_id,
    output wire [15:0] O_left_selected_source_frame_id,
    output wire [31:0] O_left_selected_count,
    output wire        O_left_request_overflow,
    output wire        O_video_out_sync_valid,
    output wire [15:0] O_video_out_sync_id,

    input wire         I_display_pause,
    input wire         I_video_out_rd_busy,
    output wire        O_video_in_wr_busy,
    output reg[1:0]    O_video_out_rp,     ///读指针
    output reg[15:0]   O_capture_frame_id,
    output wire[15:0]  O_video_out_frame_id,
    output wire        O_video_out_frame_valid,
    // Snapshot only at O_left_write_frame_start, before the next RAW frame.
    // [7] previous write page valid, [6] previous capture FIFO overflow,
    // [5] previous full word count, [4] any words written, [3] still writing,
    // [2] previous start rejected, [1] selected display page valid,
    // [0] new start would be rejected (busy or source error). Never used for video control.
    output wire [7:0]  O_capture_debug_status,
    output wire [17:0] O_capture_debug_word_count,

    output reg         O_ddr_user_wr_en,
    output reg[24:0]   O_ddr_user_addr,
    output wire[127:0] O_ddr_user_wr_data,
    input wire         I_ddr_user_ready
);

    wire        S_fifo_rst;
    reg         S_camera_frame_start_extend; ///脉冲展宽，同步到ddr_clk时钟域
    reg[3:0]    S_extend_cnt;
    reg         S_camera_frame_start_extend_1d;
    reg         S_camera_frame_start_extend_2d;
    reg         S_camera_frame_start_extend_3d;
    wire        S_frame_start;
    reg[1:0]    S_video_in_wp;       ///写指针
    wire[8:0]   S_fifo_rd_num;      
    wire        S_fifo_rd_en;   
    wire        S_fifo_rd_valid;
    wire[127:0] S_fifo_rd_data; 
    reg         S_ddr_wr_valid;
    reg[9:0]    S_ddr_wr_cnt;
    reg[15:0]   S_page_frame_id[0:3];
    reg[3:0]    S_page_frame_valid;

    localparam integer LEFT_COUNT_WIDTH = $clog2(FRAME_WORDS + 1);
    localparam [LEFT_COUNT_WIDTH-1:0] LEFT_LAST_WORD = FRAME_WORDS - 1;
    reg [15:0] S_page_sync_id [0:3];
    reg [3:0] S_page_sync_valid = 4'b0000;
    reg [1:0] S_left_write_page_reg = 2'd0;
    reg [LEFT_COUNT_WIDTH-1:0] S_left_word_count = {LEFT_COUNT_WIDTH{1'b0}};
    reg S_left_writing = 1'b0;
    reg S_left_camera_bad = 1'b0;
    (* async_reg = "true" *) reg [1:0] S_left_camera_bad_sync = 2'b00;
    wire S_left_camera_fifo_full;
    wire [1:0] S_left_write_page;
    wire S_left_capture_start;
    wire S_left_write_invalid;
    reg S_capture_overflow_debug = 1'b0;
    reg S_capture_start_reject_debug = 1'b0;

    localparam IMAGE_BASE_ADDR_0 = 25'd0;
    localparam IMAGE_BASE_ADDR_1 = 25'h0200000;
    localparam IMAGE_BASE_ADDR_2 = 25'h0400000;
    localparam IMAGE_BASE_ADDR_3 = 25'h0600000;


    assign S_left_write_page = I_mipi_rx_error ? S_video_in_wp - 2'd1 : S_video_in_wp;
    assign S_left_capture_start = S_frame_start && !I_mipi_rx_error;
    assign S_left_write_invalid = I_mipi_rx_error || S_ddr_wr_valid || O_ddr_user_wr_en;
    assign O_left_write_frame_start = S_frame_start;
    assign O_left_write_page = S_left_write_page;
    assign O_video_out_frame_id = S_page_frame_id[O_video_out_rp];
    assign O_video_out_frame_valid = S_page_frame_valid[O_video_out_rp];
    assign O_video_out_sync_valid = S_page_frame_valid[O_video_out_rp] &&
                                    S_page_sync_valid[O_video_out_rp];
    assign O_video_out_sync_id = S_page_sync_id[O_video_out_rp];
    // Sample with status at the next RAW SOF, before the counter clears.
    // Zero extends for small FRAME_WORDS simulation configurations.
    assign O_capture_debug_word_count = S_left_word_count;
    assign O_capture_debug_status = {
        S_page_frame_valid[S_left_write_page_reg], S_capture_overflow_debug,
        (S_left_word_count == FRAME_WORDS), (S_left_word_count != 0),
        S_left_writing, S_capture_start_reject_debug,
        O_video_out_frame_valid, S_left_write_invalid
    };
    stereo_left_frame_selector stereo_left_frame_selector_inst (
        .clk (I_ddr_clk), .rst (~I_rst_n),
        .sync_event_i (I_left_sync_event), .sync_id_i (I_left_sync_id),
        .capture_frame_start_i (S_left_capture_start),
        .capture_source_frame_id_i (O_capture_frame_id + 16'd1),
        .left_selected_valid_o (O_left_selected_valid),
        .left_selected_sync_id_o (O_left_selected_sync_id),
        .left_selected_source_frame_id_o (O_left_selected_source_frame_id),
        .request_overflow_o (O_left_request_overflow),
        .left_selected_count_o (O_left_selected_count)
    );
    // Diagnostic latches only: keep the previous frame's fault visible until
    // the source mailbox samples it at the next RAW boundary. The camera-side
    // overflow flag itself clears before that synchronized boundary arrives.
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_capture_overflow_debug <= 1'b0;
            S_capture_start_reject_debug <= 1'b0;
        end else if (S_frame_start) begin
            S_capture_overflow_debug <= 1'b0;
            S_capture_start_reject_debug <= S_left_write_invalid;
        end else if (S_left_camera_bad_sync[1]) begin
            S_capture_overflow_debug <= 1'b1;
        end
    end

    // CDC: camera FIFO overflow is sticky for one RAW frame. The existing
    // stretched RAW boundary crosses to DDR before delayed ISP payload arrives.
    always @(posedge I_camera_clk) begin
        if (I_camera_valid && S_left_camera_fifo_full) S_left_camera_bad <= 1'b1;
        if (I_camera_frame_start || !I_rst_n) S_left_camera_bad <= 1'b0;
    end

    assign S_fifo_rst = S_camera_frame_start_extend_3d;

    // 以完整DDR写突发的占用标志仲裁，避免连续视频写入长期阻塞读通道。
    assign O_video_in_wr_busy = S_ddr_wr_valid;

    w128_d512_fifo U_w128_d512_fifo(
        .rst        ( S_fifo_rst         ),   

        .clkw       ( I_camera_clk       ),     
        .we         ( I_camera_valid     ),
        .di         ( I_camera_data      ),
        .afull      (),
        .full_flag  ( S_left_camera_fifo_full ),
        .wrusedw    (),
 
        .clkr       ( I_ddr_clk          ),
        .re         ( S_fifo_rd_en       ), 
        .dout       ( O_ddr_user_wr_data ),  
        .rdusedw    ( S_fifo_rd_num      ),
        .valid      (), 
        .empty_flag (),
        .aempty     ()
    );


    always @(posedge I_camera_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            S_camera_frame_start_extend <= 1'b0;
        else
            if(I_camera_frame_start)
                S_camera_frame_start_extend <= 1'b1;
            else if(S_extend_cnt == 'd7)
                S_camera_frame_start_extend <= 1'b0;
            else
                S_camera_frame_start_extend <= S_camera_frame_start_extend;
    end

	
    always @ (posedge I_camera_clk) begin
    	if(S_camera_frame_start_extend)
        	S_extend_cnt <= S_extend_cnt + 'd1;
      	else
          	S_extend_cnt <= 'd0;
    end


    always @(posedge I_ddr_clk) begin
        S_camera_frame_start_extend_1d <= S_camera_frame_start_extend;
        S_camera_frame_start_extend_2d <= S_camera_frame_start_extend_1d;
        S_camera_frame_start_extend_3d <= S_camera_frame_start_extend_2d;
    end

    assign S_frame_start = ~S_camera_frame_start_extend_3d & S_camera_frame_start_extend_2d;

	/*
		如果前一帧图像有误少行了，那么地址回退为之前的，覆盖有问题的那帧图像
	*/
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            S_video_in_wp <= 'd0;
        else
            if(I_display_pause)
                S_video_in_wp <= S_video_in_wp;
            else if(S_frame_start)
                begin
                    if(I_mipi_rx_error)
                        S_video_in_wp <= S_video_in_wp;
                    else
                        S_video_in_wp <= S_video_in_wp + 'd1;
                end
            else
                S_video_in_wp <= S_video_in_wp;
    end


    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            O_video_out_rp <= 'd0;
        else
            if(I_display_pause)
                O_video_out_rp <= O_video_out_rp;
            else if(S_frame_start)
                begin
                    case(S_video_in_wp)
                        'd0: O_video_out_rp <= 'd2;
                        'd1: O_video_out_rp <= 'd3;
                        'd2: O_video_out_rp <= 'd0;
                        'd3: O_video_out_rp <= 'd1;
                    endcase
                end
            else
                O_video_out_rp <= O_video_out_rp;
    end

    // Preserve the existing capture ID boundary and page-address mapping.
    // A page is now qualified only after a complete, non-overflowing write.
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_capture_frame_id <= 16'd0;
            S_page_frame_id[0] <= 16'd0;
            S_page_frame_id[1] <= 16'd0;
            S_page_frame_id[2] <= 16'd0;
            S_page_frame_id[3] <= 16'd0;
            S_page_frame_valid <= 4'b0000;
            S_page_sync_valid <= 4'b0000;
            S_page_sync_id[0] <= 16'd0;
            S_page_sync_id[1] <= 16'd0;
            S_page_sync_id[2] <= 16'd0;
            S_page_sync_id[3] <= 16'd0;
            S_left_write_page_reg <= 2'd0;
            S_left_word_count <= {LEFT_COUNT_WIDTH{1'b0}};
            S_left_writing <= 1'b0;
            S_left_camera_bad_sync <= 2'b00;
        end else begin
            S_left_camera_bad_sync <= {S_left_camera_bad_sync[0], S_left_camera_bad};
            if (S_frame_start) begin
                S_page_frame_valid[S_left_write_page] <= 1'b0;
                S_left_write_page_reg <= S_left_write_page;
                S_left_word_count <= {LEFT_COUNT_WIDTH{1'b0}};
                S_left_writing <= !S_left_write_invalid;
                if (!I_mipi_rx_error) begin
                    O_capture_frame_id <= O_capture_frame_id + 16'd1;
                    S_page_frame_id[S_left_write_page] <= O_capture_frame_id + 16'd1;
                    S_page_sync_valid[S_left_write_page] <= O_left_selected_valid;
                    S_page_sync_id[S_left_write_page] <= O_left_selected_sync_id;
                end else begin
                    S_page_sync_valid[S_left_write_page] <= 1'b0;
                    S_page_sync_id[S_left_write_page] <= 16'd0;
                end
            end else if (S_left_camera_bad_sync[1]) begin
                S_page_frame_valid[S_left_write_page_reg] <= 1'b0;
                S_left_writing <= 1'b0;
            end else if (O_ddr_user_wr_en && S_left_writing) begin
                S_left_word_count <= S_left_word_count +
                                     {{(LEFT_COUNT_WIDTH-1){1'b0}}, 1'b1};
                if (S_left_word_count == LEFT_LAST_WORD) begin
                    S_page_frame_valid[S_left_write_page_reg] <= 1'b1;
                    S_left_writing <= 1'b0;
                end
            end
        end
    end

    /*
        fifo的深度是512，实际的深度是510，因此需要注意每次读出的长度避免为256，否则连续两次读写会引起fifo读空，丢失数据
    */
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            S_ddr_wr_valid <= 1'b0;
        else
            if(S_ddr_wr_valid && I_ddr_user_ready && S_ddr_wr_cnt == 'd239)
                S_ddr_wr_valid <= 1'b0;
            else if(S_fifo_rd_num >= 'd240 && (!I_video_out_rd_busy) && (!S_fifo_rst))
                S_ddr_wr_valid <= 1'b1;
            else
                S_ddr_wr_valid <= S_ddr_wr_valid;
    end

    always @(posedge I_ddr_clk) begin
        if(S_ddr_wr_valid)
            begin
                if(I_ddr_user_ready)
                    S_ddr_wr_cnt <= S_ddr_wr_cnt + 'd1;
                else
                    S_ddr_wr_cnt <= S_ddr_wr_cnt;
            end
        else
            S_ddr_wr_cnt <= 'd0;
    end

    assign S_fifo_rd_en = S_ddr_wr_valid & I_ddr_user_ready;

    always @(posedge I_ddr_clk) begin
        O_ddr_user_wr_en <= S_fifo_rd_en;
    end

	/*
		如果前一帧图像有误少行了，那么地址回退为之前的，覆盖有问题的那帧图像
	*/
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            O_ddr_user_addr <= 1'b0;
        else
            if(S_frame_start && (!I_mipi_rx_error))
                begin
                    case(S_video_in_wp)
                        'd0: O_ddr_user_addr <= IMAGE_BASE_ADDR_0;
                        'd1: O_ddr_user_addr <= IMAGE_BASE_ADDR_1;
                        'd2: O_ddr_user_addr <= IMAGE_BASE_ADDR_2;
                        'd3: O_ddr_user_addr <= IMAGE_BASE_ADDR_3;
                    endcase
                end
			else if(S_frame_start && I_mipi_rx_error)
				begin
                	case(S_video_in_wp)
                        'd0: O_ddr_user_addr <= IMAGE_BASE_ADDR_3;
                        'd1: O_ddr_user_addr <= IMAGE_BASE_ADDR_0;
                        'd2: O_ddr_user_addr <= IMAGE_BASE_ADDR_1;
                        'd3: O_ddr_user_addr <= IMAGE_BASE_ADDR_2;
                    endcase
                end
            else if(O_ddr_user_wr_en)
                O_ddr_user_addr <= O_ddr_user_addr + 'd8;
            else    
                O_ddr_user_addr <= O_ddr_user_addr;
    end

    
endmodule
