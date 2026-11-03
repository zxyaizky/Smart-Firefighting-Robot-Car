// Change Log: 2026-10-17 Codex v3.1 Passive FIFO count for DDR read reservations.
// Change Log: 2026-10-02 Codex v3.0 Atomic display-page metadata and video errors.



module video_out (
    input wire        I_rst_n,

    input wire        I_sys_clk,
    input wire        I_processed_frame_vsync,
    input wire        I_ddr_clk,
    output wire       O_video_out_rd_busy,  
    input wire        I_video_in_wr_busy,   
    input wire[1:0]   I_video_out_rp,
    input wire[15:0]  I_capture_frame_id,
    input wire[15:0]  I_video_out_frame_id,
    input wire        I_video_out_frame_valid,
    input wire        I_video_out_sync_valid,
    input wire [15:0] I_video_out_sync_id,
    input wire        I_left_write_frame_start,
    input wire [1:0]  I_left_write_page,
    output wire       O_left_video_frame_valid,
    output wire [15:0] O_left_video_source_frame_id,
    output wire       O_left_video_sync_valid,
    output wire [15:0] O_left_video_sync_id,
    output wire       O_left_video_error,
    output reg[7:0]   O_latency_frames,
    output reg[19:0]  O_latency_10us_bcd,
    output reg[23:0]  O_processed_fps_bcd,
    output wire       O_ddr_user_rd_en,
    output wire[24:0] O_ddr_user_addr,
    // Passive DDR-clock FIFO occupancy for the shared-bus reservation guard.
    output wire[8:0]  O_ddr_fifo_used,
    input wire        I_ddr_user_ready,
    input wire        I_ddr_user_rd_valid,
    input wire[127:0] I_ddr_user_rd_data,
    // Includes reads queued in MC and native DDR, not only issued native reads.
    input wire[9:0]   I_ddr_reads_outstanding,

    input wire        I_dsi_clk,
    input wire        I_video_vsync,
    input wire        I_video_rd_en,  
    output reg[23:0]  O_vdieo_data
);

    reg         S_fifo_rst;     
    reg[7:0]    S_fifo_rst_cnt;
    wire[8:0]   S_fifo_wr_num;       
    wire        S_fifo_rd_en;        
    wire[127:0] S_fifo_rd_data;      
    reg         S_video_vsync_1d;
    reg         S_video_vsync_2d;
    reg         S_video_vsync_3d;
    wire        S_video_frame_start;   
    wire        S_ddr_rd_trig;       
    reg         S_ddr_rd_valid;      
    reg[9:0]    S_ddr_rd_cnt;        
    reg[3:0]    S_fifo_rd_cnt;       
    reg         S_video_rd_en_1d;
    reg[3:0]    S_fifo_rd_cnt_1d;     
    reg[127:0]  S_fifo_rd_data_1d;    
    wire        S_fifo_emtpy;     
    reg[24:0]   S_ddr_addr;
    wire[15:0]  S_latency_difference;
    reg[15:0]   S_display_frame_id_ddr;
    reg         S_display_frame_valid_ddr;
    reg         S_display_event_toggle_ddr;

    reg[8:0]    S_10us_divider;
    reg[31:0]   S_time_10us;
    reg[15:0]   S_capture_id_meta;
    reg[15:0]   S_capture_id_sync;
    reg[15:0]   S_capture_id_stable;
    reg[15:0]   S_capture_id_seen;
    reg[15:0]   S_display_id_meta;
    reg[15:0]   S_display_id_sync;
    reg[15:0]   S_display_id_stable;
    reg         S_display_valid_meta;
    reg         S_display_valid_sync;
    reg         S_display_event_meta;
    reg         S_display_event_sync;
    reg         S_display_event_sync_d;
    reg         S_display_event_seen;
    reg[31:0]   S_capture_time_10us[0:15];
    reg[15:0]   S_capture_time_id[0:15];
    reg[15:0]   S_capture_time_valid;
    wire[3:0]   S_display_time_index;
    wire[31:0]  S_latency_10us_difference;
    reg         S_processed_vsync_meta;
    reg         S_processed_vsync_sync;
    reg         S_processed_vsync_sync_d;
    wire        S_processed_frame_start;
    reg[23:0]   S_last_processed_time_10us;
    reg         S_last_processed_time_valid;
    reg[26:0]   S_fps_dividend;
    reg[23:0]   S_fps_divisor;
    reg[26:0]   S_fps_quotient;
    reg[24:0]   S_fps_remainder;
    reg[5:0]    S_fps_divide_count;
    reg         S_fps_divide_busy;
    wire[24:0]  S_fps_remainder_shift;
    wire        S_fps_divide_bit;
    wire[26:0]  S_fps_quotient_next;

    reg[16:0]   S_latency_bin_work;
    reg[19:0]   S_latency_bcd_work;
    reg[19:0]   S_latency_bcd_adjusted;
    reg[4:0]    S_latency_bcd_count;
    reg         S_latency_bcd_busy;
    wire[19:0]  S_latency_bcd_next;

    reg[19:0]   S_fps_bin_work;
    reg[23:0]   S_fps_bcd_work;
    reg[23:0]   S_fps_bcd_adjusted;
    reg[4:0]    S_fps_bcd_count;
    reg         S_fps_bcd_busy;
    wire[23:0]  S_fps_bcd_next;
    wire[23:0]  S_processed_period_10us;



    wire [33:0] S_left_metadata_received;
    wire S_left_metadata_event;
    reg [32:0] S_left_metadata_reg = 33'd0;
    reg S_left_metadata_valid_reg = 1'b0;
    reg S_left_vsync_d_reg = 1'b1;
    reg [1:0] S_left_display_page_reg = 2'd0;
    reg S_left_read_error_ddr = 1'b0;
    (* async_reg = "true" *) reg [1:0] S_left_read_error_sync = 2'b00;
    reg [1:0] S_left_underflow_pipe = 2'b00;
    wire S_left_fifo_full;
    assign O_left_video_frame_valid = S_left_metadata_valid_reg;
    assign O_left_video_source_frame_id = S_left_metadata_reg[15:0];
    assign O_left_video_sync_valid = S_left_metadata_valid_reg && S_left_metadata_reg[32];
    assign O_left_video_sync_id = S_left_metadata_reg[31:16];
    assign O_left_video_error = S_left_read_error_sync[1] || S_left_underflow_pipe[1];
    // CDC: sample exactly the page whose base address is selected below.
    // Request/ack keeps the complete held metadata word stable across clocks.
    stereo_metadata_mailbox #(.DATA_WIDTH(34)) stereo_metadata_mailbox_inst (
        .clk_source (I_ddr_clk), .rst_source (~I_rst_n),
        .clk_dest (I_dsi_clk), .rst_dest (~I_rst_n),
        .send_i (S_video_frame_start),
        .data_i ({I_video_out_frame_valid, I_video_out_sync_valid,
                  I_video_out_sync_id, I_video_out_frame_id}),
        .ready_o (), .overflow_o (),
        .event_o (S_left_metadata_event), .data_o (S_left_metadata_received)
    );
    always @(posedge I_ddr_clk) begin
        if (S_video_frame_start) begin
            S_left_display_page_reg <= I_video_out_rp;
            S_left_read_error_ddr <= I_left_write_frame_start &&
                                    I_left_write_page == I_video_out_rp;
        end else if ((I_left_write_frame_start &&
                     I_left_write_page == S_left_display_page_reg) ||
                     (I_ddr_user_rd_valid && S_left_fifo_full)) begin
            // The RAW write boundary precedes payload writes to this page.
            // Reject an overwritten read page or overflowing output FIFO.
            S_left_read_error_ddr <= 1'b1;
        end
        if (!I_rst_n) begin
            S_left_display_page_reg <= 2'd0;
            S_left_read_error_ddr <= 1'b0;
        end
    end
    always @(posedge I_dsi_clk) begin
        S_left_vsync_d_reg <= I_video_vsync;
        S_left_read_error_sync <= {S_left_read_error_sync[0], S_left_read_error_ddr};
        S_left_underflow_pipe <= {S_left_underflow_pipe[0],
                                  S_fifo_rd_en && S_fifo_emtpy};
        if (S_left_metadata_event) begin
            S_left_metadata_reg <= S_left_metadata_received[32:0];
            S_left_metadata_valid_reg <= S_left_metadata_received[33];
        end
        if (!I_video_vsync && S_left_vsync_d_reg) S_left_metadata_valid_reg <= 1'b0;
        if (!I_rst_n) begin
            S_left_vsync_d_reg <= 1'b1;
            S_left_metadata_reg <= 33'd0;
            S_left_metadata_valid_reg <= 1'b0;
            S_left_read_error_sync <= 2'b00;
            S_left_underflow_pipe <= 2'b00;
        end
    end

    localparam IMAGE_BASE_ADDR_0 = 25'd0;
    localparam IMAGE_BASE_ADDR_1 = 25'h0200000;
    localparam IMAGE_BASE_ADDR_2 = 25'h0400000;
    localparam IMAGE_BASE_ADDR_3 = 25'h0600000;

    assign S_display_time_index = S_display_id_stable[3:0];
    assign S_latency_10us_difference = S_time_10us -
                                       S_capture_time_10us[S_display_time_index];
    assign S_fps_remainder_shift = {S_fps_remainder[23:0], S_fps_dividend[26]};
    assign S_fps_divide_bit = (S_fps_remainder_shift >= {1'b0, S_fps_divisor});
    assign S_fps_quotient_next = {S_fps_quotient[25:0], S_fps_divide_bit};
    assign S_processed_frame_start = S_processed_vsync_sync &&
                                     !S_processed_vsync_sync_d;
    assign S_latency_bcd_next = {S_latency_bcd_adjusted[18:0],
                                 S_latency_bin_work[16]};
    assign S_fps_bcd_next = {S_fps_bcd_adjusted[22:0],
                             S_fps_bin_work[19]};
    assign S_processed_period_10us = S_time_10us[23:0] -
                                     S_last_processed_time_10us;

    // One double-dabble step per clock.  The former fully unrolled conversion
    // produced the same digits in one cycle but consumed many LUTs.
    always @(*) begin
        S_latency_bcd_adjusted = S_latency_bcd_work;
        if(S_latency_bcd_work[3:0] >= 4'd5)
            S_latency_bcd_adjusted[3:0] = S_latency_bcd_work[3:0] + 4'd3;
        if(S_latency_bcd_work[7:4] >= 4'd5)
            S_latency_bcd_adjusted[7:4] = S_latency_bcd_work[7:4] + 4'd3;
        if(S_latency_bcd_work[11:8] >= 4'd5)
            S_latency_bcd_adjusted[11:8] = S_latency_bcd_work[11:8] + 4'd3;
        if(S_latency_bcd_work[15:12] >= 4'd5)
            S_latency_bcd_adjusted[15:12] = S_latency_bcd_work[15:12] + 4'd3;
        if(S_latency_bcd_work[19:16] >= 4'd5)
            S_latency_bcd_adjusted[19:16] = S_latency_bcd_work[19:16] + 4'd3;
    end

    always @(*) begin
        S_fps_bcd_adjusted = S_fps_bcd_work;
        if(S_fps_bcd_work[3:0] >= 4'd5)
            S_fps_bcd_adjusted[3:0] = S_fps_bcd_work[3:0] + 4'd3;
        if(S_fps_bcd_work[7:4] >= 4'd5)
            S_fps_bcd_adjusted[7:4] = S_fps_bcd_work[7:4] + 4'd3;
        if(S_fps_bcd_work[11:8] >= 4'd5)
            S_fps_bcd_adjusted[11:8] = S_fps_bcd_work[11:8] + 4'd3;
        if(S_fps_bcd_work[15:12] >= 4'd5)
            S_fps_bcd_adjusted[15:12] = S_fps_bcd_work[15:12] + 4'd3;
        if(S_fps_bcd_work[19:16] >= 4'd5)
            S_fps_bcd_adjusted[19:16] = S_fps_bcd_work[19:16] + 4'd3;
        if(S_fps_bcd_work[23:20] >= 4'd5)
            S_fps_bcd_adjusted[23:20] = S_fps_bcd_work[23:20] + 4'd3;
    end


    always @(posedge I_ddr_clk) begin
        S_video_vsync_1d <= I_video_vsync;
        S_video_vsync_2d <=S_video_vsync_1d;
        S_video_vsync_3d <= S_video_vsync_2d;
    end

    assign S_video_frame_start = ~S_video_vsync_3d & S_video_vsync_2d;
    assign S_latency_difference = I_capture_frame_id - I_video_out_frame_id;

    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            O_latency_frames <= 8'd0;
            S_display_frame_id_ddr       <= 16'd0;
            S_display_frame_valid_ddr    <= 1'b0;
            S_display_event_toggle_ddr   <= 1'b0;
        end
        else if(S_video_frame_start) begin
            S_display_frame_id_ddr       <= I_video_out_frame_id;
            S_display_frame_valid_ddr    <= I_video_out_frame_valid;
            S_display_event_toggle_ddr   <= ~S_display_event_toggle_ddr;
            if(!I_video_out_frame_valid)
                O_latency_frames <= 8'd0;
            else if(|S_latency_difference[15:8])
                O_latency_frames <= 8'hff;
            else
                O_latency_frames <= S_latency_difference[7:0];
        end
    end

    // The project system clock is constrained to 50 MHz. Dividing by 500
    // creates a 10 us timestamp with 0.01 ms display resolution.
    always @(posedge I_sys_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_10us_divider <= 9'd0;
            S_time_10us    <= 32'd0;
        end
        else begin
            if(S_10us_divider == 9'd499) begin
                S_10us_divider <= 9'd0;
                S_time_10us    <= S_time_10us + 32'd1;
            end
            else begin
                S_10us_divider <= S_10us_divider + 9'd1;
            end
        end
    end

    // Synchronize frame identities and the display-frame event to 50 MHz.
    // The extra stable stage prevents a transient mixed value on the buses.
    always @(posedge I_sys_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_capture_id_meta       <= 16'd0;
            S_capture_id_sync       <= 16'd0;
            S_capture_id_stable     <= 16'd0;
            S_display_id_meta       <= 16'd0;
            S_display_id_sync       <= 16'd0;
            S_display_id_stable     <= 16'd0;
            S_display_valid_meta    <= 1'b0;
            S_display_valid_sync    <= 1'b0;
            S_display_event_meta    <= 1'b0;
            S_display_event_sync    <= 1'b0;
            S_display_event_sync_d  <= 1'b0;
            S_processed_vsync_meta  <= 1'b0;
            S_processed_vsync_sync  <= 1'b0;
            S_processed_vsync_sync_d <= 1'b0;
        end
        else begin
            S_capture_id_meta       <= I_capture_frame_id;
            S_capture_id_sync       <= S_capture_id_meta;
            S_capture_id_stable     <= S_capture_id_sync;
            S_display_id_meta       <= S_display_frame_id_ddr;
            S_display_id_sync       <= S_display_id_meta;
            S_display_id_stable     <= S_display_id_sync;
            S_display_valid_meta    <= S_display_frame_valid_ddr;
            S_display_valid_sync    <= S_display_valid_meta;
            S_display_event_meta    <= S_display_event_toggle_ddr;
            S_display_event_sync    <= S_display_event_meta;
            S_display_event_sync_d  <= S_display_event_sync;
            S_processed_vsync_meta  <= I_processed_frame_vsync;
            S_processed_vsync_sync  <= S_processed_vsync_meta;
            S_processed_vsync_sync_d <= S_processed_vsync_sync;
        end
    end

    // Timestamp every captured frame. At each display frame, look up the
    // timestamp of the DDR page actually selected for output and calculate
    // its age. Sixteen entries safely cover the four-page frame buffer.
    always @(posedge I_sys_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_capture_id_seen     <= 16'd0;
            S_display_event_seen  <= 1'b0;
            S_capture_time_valid  <= 16'd0;
            O_latency_10us_bcd    <= 20'd0;
            O_processed_fps_bcd   <= 24'd0;
            S_last_processed_time_10us <= 24'd0;
            S_last_processed_time_valid <= 1'b0;
            S_fps_dividend        <= 27'd0;
            S_fps_divisor         <= 24'd1;
            S_fps_quotient        <= 27'd0;
            S_fps_remainder       <= 25'd0;
            S_fps_divide_count    <= 6'd0;
            S_fps_divide_busy     <= 1'b0;
            S_latency_bin_work    <= 17'd0;
            S_latency_bcd_work    <= 20'd0;
            S_latency_bcd_count   <= 5'd0;
            S_latency_bcd_busy    <= 1'b0;
            S_fps_bin_work        <= 20'd0;
            S_fps_bcd_work        <= 24'd0;
            S_fps_bcd_count       <= 5'd0;
            S_fps_bcd_busy        <= 1'b0;
        end
        else begin
            if((S_capture_id_sync == S_capture_id_stable) &&
               (S_capture_id_stable != S_capture_id_seen)) begin
                S_capture_id_seen <= S_capture_id_stable;
                S_capture_time_10us[S_capture_id_stable[3:0]] <= S_time_10us;
                S_capture_time_id[S_capture_id_stable[3:0]]   <= S_capture_id_stable;
                S_capture_time_valid[S_capture_id_stable[3:0]] <= 1'b1;
            end

            // Measure the selected mode in the existing 10 us timebase.
            // FPS x 1000 = 100,000,000 / frame_period_in_10us_ticks.
            if(S_processed_frame_start) begin
                if(S_last_processed_time_valid &&
                   (S_processed_period_10us != 24'd0)) begin
                    S_fps_dividend     <= 27'd100000000;
                    S_fps_divisor      <= S_processed_period_10us;
                    S_fps_quotient     <= 27'd0;
                    S_fps_remainder    <= 25'd0;
                    S_fps_divide_count <= 6'd27;
                    S_fps_divide_busy  <= 1'b1;
                end
                S_last_processed_time_10us <= S_time_10us[23:0];
                S_last_processed_time_valid <= 1'b1;
            end

            if(S_fps_divide_busy) begin
                S_fps_dividend <= {S_fps_dividend[25:0], 1'b0};
                S_fps_quotient <= S_fps_quotient_next;
                if(S_fps_divide_bit)
                    S_fps_remainder <= S_fps_remainder_shift - {1'b0, S_fps_divisor};
                else
                    S_fps_remainder <= S_fps_remainder_shift;

                S_fps_divide_count <= S_fps_divide_count - 6'd1;
                if(S_fps_divide_count == 6'd1) begin
                    S_fps_divide_busy <= 1'b0;
                    if(S_fps_quotient_next > 27'd999999) begin
                        O_processed_fps_bcd <= 24'h999999;
                        S_fps_bcd_busy <= 1'b0;
                    end
                    else begin
                        S_fps_bin_work  <= S_fps_quotient_next[19:0];
                        S_fps_bcd_work  <= 24'd0;
                        S_fps_bcd_count <= 5'd20;
                        S_fps_bcd_busy  <= 1'b1;
                    end
                end
            end

            if(S_fps_bcd_busy) begin
                S_fps_bin_work <= {S_fps_bin_work[18:0], 1'b0};
                S_fps_bcd_work <= S_fps_bcd_next;
                S_fps_bcd_count <= S_fps_bcd_count - 5'd1;
                if(S_fps_bcd_count == 5'd1) begin
                    O_processed_fps_bcd <= S_fps_bcd_next;
                    S_fps_bcd_busy <= 1'b0;
                end
            end

            if(S_display_event_sync_d != S_display_event_seen) begin
                S_display_event_seen <= S_display_event_sync_d;
                if(S_display_valid_sync &&
                   S_capture_time_valid[S_display_time_index] &&
                    (S_capture_time_id[S_display_time_index] == S_display_id_stable)) begin
                    if(S_latency_10us_difference > 32'd99999) begin
                        O_latency_10us_bcd <= 20'h99999;
                        S_latency_bcd_busy <= 1'b0;
                    end
                    else begin
                        S_latency_bin_work  <= S_latency_10us_difference[16:0];
                        S_latency_bcd_work  <= 20'd0;
                        S_latency_bcd_count <= 5'd17;
                        S_latency_bcd_busy  <= 1'b1;
                    end
                end
                else begin
                    O_latency_10us_bcd <= 20'd0;
                    S_latency_bcd_busy <= 1'b0;
                end
            end

            if(S_latency_bcd_busy) begin
                S_latency_bin_work <= {S_latency_bin_work[15:0], 1'b0};
                S_latency_bcd_work <= S_latency_bcd_next;
                S_latency_bcd_count <= S_latency_bcd_count - 5'd1;
                if(S_latency_bcd_count == 5'd1) begin
                    O_latency_10us_bcd <= S_latency_bcd_next;
                    S_latency_bcd_busy <= 1'b0;
                end
            end
        end
    end


    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            S_fifo_rst <= 1'b0;
        else
            if(S_video_frame_start)
                S_fifo_rst <= 1'b1;
            // Old responses must drain while the pixel FIFO is held empty.
            else if(S_fifo_rst_cnt == 'd10 && I_ddr_reads_outstanding == 10'd0)
                S_fifo_rst <= 1'b0;
            else
                S_fifo_rst <= S_fifo_rst;
    end


    always @(posedge I_ddr_clk) begin
        if(S_fifo_rst && S_fifo_rst_cnt != 'd10)
            S_fifo_rst_cnt <= S_fifo_rst_cnt + 'd1;
        else if(!S_fifo_rst)
            S_fifo_rst_cnt <= 'd0;
    end

    /*
        这里需要注意fifo的剩余空间一定要大于将要写入的长度，因为ddr读出的时候会有至少40个时钟周期的延时，
        例如每次从ddr读出240个长度的数据，那么fifo的剩余空间最少要设为280，否则会引起fifo写满丢失数据。
    */
    assign S_ddr_rd_trig = (('d511 - S_fifo_wr_num) >= 'd300) &&
                           // Reserve the whole 240-beat burst in the 480-slot window.
                           (({2'b00, S_fifo_wr_num} + {1'b0, I_ddr_reads_outstanding}) <= 11'd240) &&
                           (!I_video_in_wr_busy) && (!S_ddr_rd_valid) &&
                           (!S_fifo_rst) && I_rst_n;

    /*
        fifo的深度是512，实际的深度是510，因此需要注意每次读出的长度避免为256，否则连续两次写入会引起fifo写满，丢失数据
    */
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            S_ddr_rd_valid <= 1'b0;
        else if(S_video_frame_start || S_fifo_rst)
            S_ddr_rd_valid <= 1'b0;
        else
			if(O_ddr_user_rd_en && S_ddr_rd_cnt == 'd239)
                S_ddr_rd_valid <= 1'b0;
            else if(S_ddr_rd_trig)
                S_ddr_rd_valid <= 1'b1;
            else
                S_ddr_rd_valid <= S_ddr_rd_valid;
    end

    assign O_ddr_user_rd_en = S_ddr_rd_valid & I_ddr_user_ready &
                             !S_video_frame_start & !S_fifo_rst & I_rst_n;

    always @(posedge I_ddr_clk) begin
        if(S_video_frame_start || S_fifo_rst || !I_rst_n)
            S_ddr_rd_cnt <= 'd0;
        else if(S_ddr_rd_valid)
            begin
                if(O_ddr_user_rd_en)
                    S_ddr_rd_cnt <= S_ddr_rd_cnt + 'd1;
                else
                    S_ddr_rd_cnt <= S_ddr_rd_cnt;
            end
        else    
            S_ddr_rd_cnt <= 'd0;
    end


    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            S_ddr_addr <= 'd0;
        else
            if(S_video_frame_start)
                begin
                    case(I_video_out_rp)
                        'd0: S_ddr_addr <= IMAGE_BASE_ADDR_0;
                        'd1: S_ddr_addr <= IMAGE_BASE_ADDR_1;
                        'd2: S_ddr_addr <= IMAGE_BASE_ADDR_2;
                        'd3: S_ddr_addr <= IMAGE_BASE_ADDR_3;
                    endcase
                end
            else if(O_ddr_user_rd_en)
                S_ddr_addr <= S_ddr_addr + 'd8;
            else    
                S_ddr_addr <= S_ddr_addr;
    end

    assign O_ddr_user_addr = S_ddr_addr;
    assign O_video_out_rd_busy = S_ddr_rd_trig | S_ddr_rd_valid;
    assign O_ddr_fifo_used = S_fifo_wr_num;


    w128_d512_fifo U_w128_d512_fifo(
        .rst        ( S_fifo_rst          ),   

        .clkw       ( I_ddr_clk           ),     
        .we         ( I_ddr_user_rd_valid ),
        .di         ( I_ddr_user_rd_data  ),
        .wrusedw    ( S_fifo_wr_num       ),
        .afull      (),
        .full_flag  ( S_left_fifo_full ),
 
        .clkr       ( I_dsi_clk           ),
        .re         ( S_fifo_rd_en        ), 
        .dout       ( S_fifo_rd_data      ),  
        .rdusedw    (), 
        .valid      (),  
        .empty_flag ( S_fifo_emtpy        ),
        .aempty     ()
    );


   always @(posedge I_dsi_clk) begin
       if(I_video_rd_en)
           S_fifo_rd_cnt <= S_fifo_rd_cnt + 'd1;
       else
           S_fifo_rd_cnt <= 'd0;
   end

   assign S_fifo_rd_en = I_video_rd_en && (S_fifo_rd_cnt == 'd0)  ? 1'b1 :
                         I_video_rd_en && (S_fifo_rd_cnt == 'd5)  ? 1'b1 :
                         I_video_rd_en && (S_fifo_rd_cnt == 'd10) ? 1'b1 : 1'b0;

   always @(posedge I_dsi_clk) begin
       S_video_rd_en_1d  <= I_video_rd_en;
       S_fifo_rd_cnt_1d  <= S_fifo_rd_cnt;
       S_fifo_rd_data_1d <= S_fifo_rd_data;
   end

   always @(posedge I_dsi_clk) begin
       if(S_video_rd_en_1d)
           begin
               case(S_fifo_rd_cnt_1d)
                   'd0: O_vdieo_data  <= S_fifo_rd_data[127:104];
                   'd1: O_vdieo_data  <= S_fifo_rd_data[103:80];
                   'd2: O_vdieo_data  <= S_fifo_rd_data[79:56];
                   'd3: O_vdieo_data  <= S_fifo_rd_data[55:32];
                   'd4: O_vdieo_data  <= S_fifo_rd_data[31:8];
                   'd5: O_vdieo_data  <= {S_fifo_rd_data_1d[7:0],S_fifo_rd_data[127:112]};
                   'd6: O_vdieo_data  <= S_fifo_rd_data[111:88];
                   'd7: O_vdieo_data  <= S_fifo_rd_data[87:64];
                   'd8: O_vdieo_data  <= S_fifo_rd_data[63:40];
                   'd9: O_vdieo_data  <= S_fifo_rd_data[39:16];
                   'd10: O_vdieo_data <= {S_fifo_rd_data_1d[15:0],S_fifo_rd_data[127:120]};
                   'd11: O_vdieo_data <= S_fifo_rd_data[119:96];
                   'd12: O_vdieo_data <= S_fifo_rd_data[95:72];
                   'd13: O_vdieo_data <= S_fifo_rd_data[71:48];
                   'd14: O_vdieo_data <= S_fifo_rd_data[47:24];
                   'd15: O_vdieo_data <= S_fifo_rd_data[23:0];
               endcase
           end
       else
           O_vdieo_data <= 'd0;
   end

    
endmodule
