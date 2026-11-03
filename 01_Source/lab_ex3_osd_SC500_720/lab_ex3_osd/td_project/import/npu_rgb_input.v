// Change Log: 2026-10-02 Codex v2.0 Stereo stage 2 sync/source/bbox metadata.
// 1280x720 center sampler and video-to-NPU clock crossing.
`resetall
`timescale 1ns/1ps
`default_nettype none
module npu_rgb_input (
    input wire clk_video,input wire clk_npu,input wire rst_n,
    input wire i_sof,input wire i_valid,input wire [23:0] i_rgb,
    input wire i_npu_busy,output wire o_frame_valid,
    output wire o_byte_valid,output wire [7:0] o_byte,
    input wire [32:0] i_frame_metadata, output wire [32:0] o_frame_metadata,
    output wire o_capture_busy
);
    // Token FIFO replaces the old 14,400-pixel frame RAM. Tokens cross clocks
    // while PING itself holds the complete 57,600-byte CHW inference frame.
    localparam [1:0] TOK_START=2'b00,TOK_SAMPLE=2'b01,TOK_END=2'b10,
                     TOK_START_SAMPLE=2'b11;
    localparam integer FIFO_AW=8;
    reg [25:0] token_mem [0:255]; /* fehdl force_ram=1, ram_style="dram" */
    reg [FIFO_AW:0] wr_bin,wr_gray,rd_bin,rd_gray;
    (* async_reg="true" *) reg [FIFO_AW:0] rd_gray_v1,rd_gray_v2;
    (* async_reg="true" *) reg [FIFO_AW:0] wr_gray_n1,wr_gray_n2;
    (* async_reg="true" *) reg [1:0] busy_sync;
    reg [1:0] video_reset_sync,npu_reset_sync;
    wire [FIFO_AW:0] wr_bin_next=wr_bin+1'b1;
    wire [FIFO_AW:0] wr_gray_next=(wr_bin_next>>1)^wr_bin_next;
    wire fifo_full=(wr_gray_next==
        {~rd_gray_v2[FIFO_AW:FIFO_AW-1],rd_gray_v2[FIFO_AW-2:0]});
    wire fifo_empty=(rd_gray==wr_gray_n2);
    wire [25:0] fifo_head=token_mem[rd_bin[FIFO_AW-1:0]];

    reg [32:0] metadata_held_reg = 33'd0;
    reg [32:0] metadata_output_reg = 33'd0;
    reg metadata_request_reg = 1'b0;
    reg metadata_ack_reg = 1'b0;
    (* async_reg="true" *) reg [1:0] metadata_ack_sync_reg = 2'b00;
    wire metadata_ready;
    wire metadata_start_read;
    assign metadata_ready = metadata_request_reg == metadata_ack_sync_reg[1];
    assign o_frame_metadata = metadata_output_reg;
    reg capture_reg;
    reg [10:0] x_reg;
    reg [9:0] y_reg;
    reg [7:0] dx_reg,dy_reg;
    reg [13:0] sample_count_reg;
    // Match the training/Python nearest-neighbour phase exactly: the selected
    // source coordinates are 0,8,...,1272 and 0,8,...,712.  The old +4 center
    // phase fed a different image to an otherwise bit-exact integer network.
    wire [10:0] target_x={dx_reg,3'b000};
    wire [10:0] target_y={dy_reg,3'b000};
    wire start_accept=i_sof && (!busy_sync[1] || capture_reg) && !fifo_full && metadata_ready;
    wire start_sample=start_accept && i_valid;
    // These two names are retained for hierarchy-based verification.
    wire sample_write=start_sample ||
                      (capture_reg && i_valid && dx_reg<160 && dy_reg<90 &&
                       x_reg==target_x && y_reg==target_y);
    wire [13:0] sample_addr=sample_count_reg;
    reg fifo_wr_en;
    reg [25:0] fifo_wr_data;

    always @(*) begin
        fifo_wr_en=1'b0;
        fifo_wr_data=26'd0;
        if(start_accept) begin
            fifo_wr_en=1'b1;
            fifo_wr_data=i_valid ? {TOK_START_SAMPLE,i_rgb} : {TOK_START,24'd0};
        end else if(sample_write && !fifo_full) begin
            fifo_wr_en=1'b1;
            fifo_wr_data={TOK_SAMPLE,i_rgb};
        end else if(capture_reg && i_valid && x_reg==1279 && y_reg==719 &&
                    sample_count_reg==14400 && !fifo_full) begin
            fifo_wr_en=1'b1;
            fifo_wr_data={TOK_END,24'd0};
        end
    end

    always @(posedge clk_video or negedge rst_n) begin
        if(!rst_n) begin
            video_reset_sync<=0; rd_gray_v1<=0; rd_gray_v2<=0;
            busy_sync<=2'b11;
        end else begin
            video_reset_sync<={video_reset_sync[0],1'b1};
            rd_gray_v1<=rd_gray;
            rd_gray_v2<=rd_gray_v1;
            busy_sync<={busy_sync[0],i_npu_busy};
        end
    end
    always @(posedge clk_video or negedge rst_n) begin
        if(!rst_n) begin wr_bin<=0; wr_gray<=0; end
        else if(!video_reset_sync[1]) begin wr_bin<=0; wr_gray<=0; end
        else if(fifo_wr_en) begin
            token_mem[wr_bin[FIFO_AW-1:0]]<=fifo_wr_data;
            wr_bin<=wr_bin_next;
            wr_gray<=wr_gray_next;
        end
    end
    always @(posedge clk_video or negedge rst_n) begin
        if(!rst_n) begin
            capture_reg<=0; x_reg<=0; y_reg<=0; dx_reg<=0; dy_reg<=0;
            sample_count_reg<=0;
        end else if(video_reset_sync[1]) begin
            if(i_sof) begin
                // A new SOF may replace this module's own incomplete capture.
                // Once capture_reg has cleared, a high busy_sync means PING is
                // owned by inference and the complete new source frame is skipped.
                capture_reg<=start_accept;
                // SOF may coincide with selected pixel (0,0).  TOK_START_SAMPLE
                // preserves it while the counters advance to the next source pixel.
                x_reg<=i_valid ? 11'd1 : 11'd0;
                y_reg<=0;
                dx_reg<=i_valid ? 8'd1 : 8'd0;
                dy_reg<=0;
                sample_count_reg<=i_valid ? 14'd1 : 14'd0;
            end else if(capture_reg && i_valid) begin
                if(fifo_full) capture_reg<=0;
                if(sample_write && !fifo_full) begin
                    sample_count_reg<=sample_count_reg+1'b1;
                    dx_reg<=dx_reg+1'b1;
                end
                if(x_reg==1279) begin
                    x_reg<=0; dx_reg<=0; y_reg<=y_reg+1'b1;
                    if(y_reg==target_y && dy_reg<90) dy_reg<=dy_reg+1'b1;
                    if(y_reg==719) capture_reg<=0;
                end else x_reg<=x_reg+1'b1;
            end
        end
    end

    always @(posedge clk_npu or negedge rst_n) begin
        if(!rst_n) begin
            npu_reset_sync<=0; wr_gray_n1<=0; wr_gray_n2<=0;
        end else begin
            npu_reset_sync<={npu_reset_sync[0],1'b1};
            wr_gray_n1<=wr_gray;
            wr_gray_n2<=wr_gray_n1;
        end
    end

    localparam [2:0] N_IDLE=0,N_CLEAR=1,N_STREAM=2,N_RESTART=3,N_END=4;
    reg [2:0] nstate;
    reg [12:0] clear_count;
    reg [1:0] emit_phase;
    reg [23:0] rgb_reg;
    reg [14:0] n_sample_count;
    reg frame_reg,valid_reg,last_sample_pending_reg,end_pending_reg;
    reg restart_sample_reg;
    reg [7:0] byte_reg;
    wire [FIFO_AW:0] rd_bin_next=rd_bin+1'b1;
    wire [FIFO_AW:0] rd_gray_next=(rd_bin_next>>1)^rd_bin_next;
    assign o_frame_valid=frame_reg;
    assign o_byte_valid=valid_reg;
    assign o_byte=byte_reg;
    assign o_capture_busy=capture_reg || frame_reg;
    assign metadata_start_read = !fifo_empty &&
        (fifo_head[25:24] == TOK_START || fifo_head[25:24] == TOK_START_SAMPLE) &&
        (nstate == N_IDLE || (nstate == N_STREAM && emit_phase == 0));
    // CDC: one held metadata word belongs to exactly one START token. A new
    // START cannot be admitted before the old START is consumed and acknowledged.
    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            metadata_held_reg <= 33'd0;
            metadata_request_reg <= 1'b0;
            metadata_ack_sync_reg <= 2'b00;
        end else begin
            metadata_ack_sync_reg <= {metadata_ack_sync_reg[0], metadata_ack_reg};
            if (start_accept) begin
                metadata_held_reg <= i_frame_metadata;
                metadata_request_reg <= !metadata_request_reg;
            end
        end
    end
    always @(posedge clk_npu or negedge rst_n) begin
        if (!rst_n) begin
            metadata_output_reg <= 33'd0;
            metadata_ack_reg <= 1'b0;
        end else if (metadata_start_read) begin
            metadata_output_reg <= metadata_held_reg;
            metadata_ack_reg <= !metadata_ack_reg;
        end
    end

    always @(posedge clk_npu or negedge rst_n) begin
        if(!rst_n) begin
            rd_bin<=0; rd_gray<=0; nstate<=N_IDLE; clear_count<=0;
            emit_phase<=0; rgb_reg<=0; n_sample_count<=0;
            frame_reg<=0; valid_reg<=0; byte_reg<=0;
            last_sample_pending_reg<=0; end_pending_reg<=0;
            restart_sample_reg<=0;
        end else if(!npu_reset_sync[1]) begin
            rd_bin<=0; rd_gray<=0; nstate<=N_IDLE; clear_count<=0;
            emit_phase<=0; n_sample_count<=0; frame_reg<=0; valid_reg<=0;
            last_sample_pending_reg<=0; end_pending_reg<=0;
            restart_sample_reg<=0;
        end else begin
            valid_reg<=0;
            case(nstate)
                N_IDLE: begin
                    frame_reg<=0; emit_phase<=0;
                    last_sample_pending_reg<=0; end_pending_reg<=0;
                    if(!fifo_empty) begin
                        rd_bin<=rd_bin_next; rd_gray<=rd_gray_next;
                        if((fifo_head[25:24]==TOK_START ||
                            fifo_head[25:24]==TOK_START_SAMPLE) && !i_npu_busy) begin
                            frame_reg<=1; clear_count<=13'd3601;
                            if(fifo_head[25:24]==TOK_START_SAMPLE) begin
                                rgb_reg<=fifo_head[23:0];
                                n_sample_count<=15'd1;
                                emit_phase<=2'd3;
                            end else begin
                                n_sample_count<=0;
                                emit_phase<=0;
                            end
                            nstate<=N_CLEAR;
                        end
                    end
                end
                N_CLEAR: begin
                    if(clear_count==0) nstate<=N_STREAM;
                    else clear_count<=clear_count-1'b1;
                end
                N_STREAM: begin
                    if(emit_phase==3) begin
                        valid_reg<=1; byte_reg<=rgb_reg[23:16]; emit_phase<=1;
                    end else if(emit_phase==1) begin
                        valid_reg<=1; byte_reg<=rgb_reg[15:8]; emit_phase<=2;
                    end else if(emit_phase==2) begin
                        valid_reg<=1; byte_reg<=rgb_reg[7:0]; emit_phase<=0;
                        if(end_pending_reg) begin
                            nstate<=N_END;
                            last_sample_pending_reg<=0;
                            end_pending_reg<=0;
                        end
                    end else if(!fifo_empty) begin
                        rd_bin<=rd_bin_next; rd_gray<=rd_gray_next;
                        case(fifo_head[25:24])
                            TOK_SAMPLE: begin
                                rgb_reg<=fifo_head[23:0];
                                if(n_sample_count==14399) begin
                                    // Hold the last sample until the real source
                                    // EOF token proves that the frame completed.
                                    last_sample_pending_reg<=1;
                                end else begin
                                    valid_reg<=1;
                                    byte_reg<=fifo_head[23:16]; emit_phase<=1;
                                end
                                n_sample_count<=n_sample_count+1'b1;
                            end
                            TOK_START: begin
                                frame_reg<=0; nstate<=N_RESTART;
                                n_sample_count<=0;
                                restart_sample_reg<=0;
                                last_sample_pending_reg<=0;
                                end_pending_reg<=0;
                            end
                            TOK_START_SAMPLE: begin
                                frame_reg<=0; nstate<=N_RESTART;
                                rgb_reg<=fifo_head[23:0];
                                n_sample_count<=15'd1;
                                restart_sample_reg<=1;
                                last_sample_pending_reg<=0;
                                end_pending_reg<=0;
                            end
                            TOK_END: begin
                                if(last_sample_pending_reg &&
                                   n_sample_count==14400) begin
                                    valid_reg<=1;
                                    byte_reg<=rgb_reg[23:16];
                                    emit_phase<=1;
                                    end_pending_reg<=1;
                                end else begin
                                    frame_reg<=0; nstate<=N_IDLE;
                                    last_sample_pending_reg<=0;
                                    end_pending_reg<=0;
                                end
                            end
                            default: begin frame_reg<=0; nstate<=N_IDLE; end
                        endcase
                    end
                end
                N_RESTART: begin
                    frame_reg<=1; clear_count<=13'd3601;
                    emit_phase<=restart_sample_reg ? 2'd3 : 2'd0;
                    restart_sample_reg<=0; last_sample_pending_reg<=0;
                    end_pending_reg<=0; nstate<=N_CLEAR;
                end
                N_END: begin
                    frame_reg<=0; nstate<=N_IDLE;
                end
                default: nstate<=N_IDLE;
            endcase
        end
    end
endmodule
`resetall
