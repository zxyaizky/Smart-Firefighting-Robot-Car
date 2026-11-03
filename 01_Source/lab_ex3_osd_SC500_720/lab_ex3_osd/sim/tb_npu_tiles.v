`timescale 1ns/1ps
module tb_npu_tiles;
    integer tmux_accepted = 0, tmux_committed = 0, tmux_total_rounds = 0;
    integer tmux_issues = 0, tmux_returns = 0;
    reg tmux_open = 0, tmux_early_commit = 0;
    reg [71:0] tmux_window;
    reg [1151:0] tmux_weights;
    reg [17:0] tmux_metadata;

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, frame = 0;
    reg desc_we = 0;
    reg [2:0] desc_word = 0;
    reg [31:0] desc_data = 0;
    reg preload = 0;
    reg [12:0] preload_addr = 0;
    reg [127:0] preload_data = 0;
    reg dma_ack = 0, dma_done = 0;
    wire dma_req;
    wire [16:0] dma_addr, bias_base;
    wire [15:0] dma_len;
    reg [143:0] weight_data = 0;
    reg weight_valid = 0, update_weights = 0;
    reg [9:0] weight_addr = 0;
    reg [31:0] bias_data = 0;
    reg bias_valid = 0, update_bias = 0;
    reg [4:0] bias_addr = 0;
    wire inference_done, tile_error, tile_done, tile_ready;
    wire output_valid;
    wire [127:0] output_data;
    wire [12:0] output_addr;
    integer width, height, cin_count, cout_count, kernel, padding, pool, shift;
    integer gaps, reset_mid, fd, dummy, i, j, c, oc, tap, local_c, local_o;
    integer cycles = 0, received = 0, tiles = 0, requests = 0;
    integer reset_phase = 0;
    integer tail_poison = 0;
    reg [1023:0] case_dir;
    reg [7:0] inputs [0:32767];
    reg [7:0] weights [0:65535];
    reg [31:0] biases [0:63];
    reg [31:0] descriptors [0:7];
    reg [71:0] low_weight, high_weight;

    npu_core_top #(.USE_DESC_RAM(1), .POOL_REORDER_IMPL(2)) dut (
        .clk(clk), .rst_n(rst_n),
        .i_frame_valid(frame), .i_lbp_valid(1'b0), .i_lbp_pixel(8'd0),
        .i_l0_input_preload_en(1'b1), .i_l0_input_packed_en(1'b1),
        .i_preload_wr_en(preload), .i_preload_target(1'b0),
        .i_preload_wr_addr(preload_addr), .i_preload_wr_mask(16'hffff),
        .i_preload_wr_data(preload_data), .i_skip_lbp_load(1'b1),
        .i_desc_we(desc_we), .i_desc_layer(5'd0), .i_desc_word(desc_word),
        .i_desc_wdata(desc_data), .i_layer_count(6'd1), .i_desc_mode(1'b1),
        .o_dma_req(dma_req), .o_dma_base_addr(dma_addr), .o_bias_base_addr(bias_base),
        .o_dma_length(dma_len), .i_dma_ack(dma_ack), .i_dma_done(dma_done),
        .weight_in_data(weight_data), .weight_in_valid(weight_valid),
        .weight_in_addr(weight_addr), .update_weights_en(update_weights),
        .bias_in_data(bias_data), .bias_in_valid(bias_valid),
        .bias_in_addr(bias_addr), .update_bias_en(update_bias),
        .o_inference_done(inference_done), .o_tile_error(tile_error),
        .o_tile_done(tile_done), .o_tile_ready(tile_ready),
        .o_dbg_npu_out_valid(output_valid), .o_dbg_npu_out_bus(output_data),
        .o_dbg_npu_write_addr(output_addr),
        .i_layer_dbg_sel(7'd0), .i_pool_scratch_base_addr(32'd0),
        .m_axi_arready(1'b0), .m_axi_rid(4'd0), .m_axi_rdata(32'd0),
        .m_axi_rresp(2'd0), .m_axi_rlast(1'b0), .m_axi_rvalid(1'b0),
        .m_axi_awready(1'b0), .m_axi_wready(1'b0), .m_axi_bid(4'd0),
        .m_axi_bresp(2'd0), .m_axi_bvalid(1'b0)
    );

    task configure;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                @(negedge clk);
                desc_we = 1;
                desc_word = i;
                desc_data = descriptors[i];
            end
            @(negedge clk); desc_we = 0;
            for (i = 0; i < (width*height*cin_count+15)/16; i = i + 1) begin
                @(negedge clk);
                preload = 1;
                preload_addr = i;
                for (j = 0; j < 16; j = j + 1)
                    preload_data[j*8 +: 8] = inputs[i*16+j];
            end
            @(negedge clk); preload = 0;
            repeat (8) @(negedge clk);
            frame = 1;
            @(negedge clk); frame = 0;
        end
    endtask

    initial begin
        dummy = $value$plusargs("DIR=%s", case_dir);
        dummy = $value$plusargs("W=%d", width);
        dummy = $value$plusargs("H=%d", height);
        dummy = $value$plusargs("CI=%d", cin_count);
        dummy = $value$plusargs("CO=%d", cout_count);
        dummy = $value$plusargs("K=%d", kernel);
        dummy = $value$plusargs("PAD=%d", padding);
        dummy = $value$plusargs("POOL=%d", pool);
        dummy = $value$plusargs("SHIFT=%d", shift);
        dummy = $value$plusargs("GAPS=%d", gaps);
        dummy = $value$plusargs("RESET=%d", reset_mid);
        dummy = $value$plusargs("TAIL_POISON=%d", tail_poison);
        $readmemh({case_dir, "/input.hex"}, inputs);
        $readmemh({case_dir, "/weight.hex"}, weights);
        $readmemh({case_dir, "/bias.hex"}, biases);
        $readmemh({case_dir, "/desc.hex"}, descriptors);
        fd = $fopen({case_dir, "/observed.txt"}, "w");
        repeat (8) @(negedge clk);
        rst_n = 1;
        configure;
        if (reset_mid != 0) begin
            // Abort in round 3 after earlier Cin partial sums have been written.
            wait (dut.u_bcu.r_cin_idx == 3 && dut.u_conv_engine.u_pe_array.issue_reg &&
                  dut.u_conv_engine.u_pe_array.round_reg == 3);
            @(negedge clk); rst_n = 0;
            repeat (8) @(negedge clk);
            rst_n = 1;
            $fdisplay(fd, "RESET");
            received = 0; tiles = 0; requests = 0;
            reset_phase = 1;
            configure;
        end
        wait (inference_done);
        repeat (32) @(negedge clk);
        if (tmux_open || tmux_early_commit ||
            tmux_accepted != tmux_committed || tmux_accepted == 0) begin
            $fdisplay(fd, "FAIL TMUX unfinished window"); $finish;
        end
        $display("TMUX_PASS windows=%0d rounds=%0d commits=%0d", tmux_accepted,
                 tmux_total_rounds, tmux_committed);
        $fdisplay(fd, "PASS %0d %0d %0d", received, tiles, requests);
        $display("RTL_PASS outputs=%0d tiles=%0d DMA=%0d cycles=%0d", received, tiles, requests, cycles);
        $fclose(fd);
        $finish;
    end

    // DMA environment: honor the real sequencer request, load both physical pages
    // through the public ports, then signal completion only after page flips settle.
    initial begin
        forever begin
            @(negedge clk);
            if (rst_n && dma_req) begin
                c = dut.w_cin_group_idx * 16;
                oc = dut.w_oc_group_idx * 16;
                requests = requests + 1;
                $fdisplay(fd, "D %0d %0d %0d %0d %0d %0d", oc/16,
                          dut.w_tile_y_base, c/16, dma_addr, bias_base, dma_len);
                dma_ack = 1; update_weights = 1; update_bias = 1;
                @(negedge clk); dma_ack = 0;
                for (local_c = 0; local_c < dut.w_cin_block_size; local_c = local_c + 1) begin
                    for (local_o = 0; local_o < 16; local_o = local_o + 2) begin
                        low_weight = 0; high_weight = 0;
                        for (tap = 0; tap < kernel*kernel; tap = tap + 1) begin
                            if (oc+local_o < cout_count)
                                low_weight[tap*8 +: 8] = weights[((oc+local_o)*cin_count+c+local_c)*9+tap];
                            else if (tail_poison != 0) low_weight[tap*8 +: 8] = 8'd127;
                            if (oc+local_o+1 < cout_count)
                                high_weight[tap*8 +: 8] = weights[((oc+local_o+1)*cin_count+c+local_c)*9+tap];
                            else if (tail_poison != 0) high_weight[tap*8 +: 8] = 8'd127;
                        end
                        weight_data = {high_weight, low_weight};
                        weight_valid = 1; weight_addr = local_c*16+local_o;
                        @(negedge clk);
                    end
                end
                weight_valid = 0;
                for (local_o = 0; local_o < 16; local_o = local_o + 1) begin
                    bias_valid = 1; bias_addr = local_o;
                    bias_data = oc+local_o < cout_count ? biases[oc+local_o] : 32'd0;
                    if (tail_poison != 0 && oc+local_o >= cout_count) bias_data = 32'd10000;
                    @(negedge clk);
                end
                bias_valid = 0; update_weights = 0; update_bias = 0;
                repeat (4) @(negedge clk);
                dma_done = 1;
                @(negedge clk); dma_done = 0;
            end
        end
    end

    // Throttle SRAM request issuance, never an already issued SRAM response.
    // This is environment stimulus on the BCU ready input, not a datapath replacement.
    always @(negedge clk) begin
        if (rst_n && gaps != 0 && (cycles % 11 < 4 || cycles % 97 > 83))
            force dut.u_bcu.i_npu_in_ready = 1'b0;
        else release dut.u_bcu.i_npu_in_ready;
    end

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (cycles > 2000000) begin
            $fdisplay(fd, "FAIL timeout state=%0d bcu=%h", dut.u_sequencer.state, dut.w_bcu_dbg0);
            $display("FAIL timeout"); $finish;
        end
        if (rst_n && tile_error) begin
            $fdisplay(fd, "FAIL tile_error acc=%b bcu=%b reorder=%b", dut.w_tile_acc_error,
                      dut.w_tile_bcu_error, dut.o_pool_reorder_error);
            $display("FAIL tile_error"); $finish;
        end
        if (rst_n && output_valid) begin
            received = received + 1;
            $fdisplay(fd, "O %0d %0d %0d %0d %032h", dut.w_oc_group_idx,
                      dut.w_npu_out_x, dut.w_npu_out_y, output_addr, output_data);
        end
        if (rst_n && dut.u_conv_engine.pe_valid_bus[0])
            $fdisplay(fd, "P %0d %0d %0d %0128h", dut.w_oc_group_idx,
                dut.u_conv_engine.pe_x_bus[7:0], dut.u_conv_engine.pe_y_bus[7:0],
                dut.u_conv_engine.pe_sum_bus);
        if (rst_n && tile_done) begin
            tiles = tiles + 1;
            if (!dut.w_pipeline_idle || output_valid || !tile_ready) begin
                $fdisplay(fd, "FAIL premature tile done"); $finish;
            end
        end
        if (rst_n && dut.w_layer_done && !dut.w_pipeline_idle) begin
            $fdisplay(fd, "FAIL premature group done"); $finish;
        end
    end

    // Protocol monitor complements the independent full-image numerical reference.
    // Check every window through the real BCU, native FIFO and multiplexed PE.
    always @(posedge clk) begin
        if (!rst_n) begin
            tmux_accepted = 0; tmux_committed = 0; tmux_total_rounds = 0;
            tmux_issues = 0; tmux_returns = 0; tmux_open = 0;
            tmux_early_commit = 0;
        end else begin
            if (dut.u_conv_engine.lb_win_valid && !dut.u_conv_engine.pe_win_ready) begin
                $fdisplay(fd, "FAIL TMUX window overwritten under backpressure"); $finish;
            end
            if (dut.u_conv_engine.pe_busy && dut.w_pipeline_idle) begin
                $fdisplay(fd, "FAIL TMUX hidden busy at pipeline idle"); $finish;
            end
            if (dut.u_conv_engine.u_pe_array.issue_reg) begin
                if (!tmux_open || dut.u_conv_engine.u_pe_array.round_reg !== tmux_issues[2:0] ||
                    tmux_issues >= 8 ||
                    dut.u_conv_engine.u_pe_array.window_reg !== tmux_window ||
                    {dut.u_conv_engine.u_pe_array.x_reg, dut.u_conv_engine.u_pe_array.y_reg,
                     dut.u_conv_engine.u_pe_array.first_reg,
                     dut.u_conv_engine.u_pe_array.last_reg} !== tmux_metadata ||
                    dut.u_conv_engine.u_pe_array.PHYSICAL_MAC[0].selected_weight !==
                        tmux_weights[tmux_issues*144 +: 72] ||
                    dut.u_conv_engine.u_pe_array.PHYSICAL_MAC[1].selected_weight !==
                        tmux_weights[tmux_issues*144+72 +: 72]) begin
                    $fdisplay(fd, "FAIL TMUX round/window/weight selection"); $finish;
                end
                tmux_issues = tmux_issues + 1;
                tmux_total_rounds = tmux_total_rounds + 1;
            end
            if (|dut.u_conv_engine.u_pe_array.pair_valid) begin
                if (!tmux_open || dut.u_conv_engine.u_pe_array.pair_valid !== 2'b11)
                    begin $fdisplay(fd, "FAIL TMUX unpaired result"); $finish; end
                tmux_returns = tmux_returns + 1;
            end
            if (dut.u_conv_engine.u_pe_array.launch_pending &&
                dut.u_conv_engine.u_pe_array.final_pair_now) begin
                if (!tmux_open || tmux_early_commit ||
                    tmux_issues != dut.u_conv_engine.u_pe_array.round_limit_reg + 1 ||
                    tmux_returns != dut.u_conv_engine.u_pe_array.round_limit_reg + 1) begin
                    $fdisplay(fd, "FAIL TMUX early retirement"); $finish;
                end
                tmux_open = 0;
                tmux_early_commit = 1;
            end
            if (dut.u_conv_engine.u_pe_array.commit_reg) begin
                if (tmux_early_commit) begin
                    tmux_early_commit = 0;
                end else begin
                    if (!tmux_open ||
                        tmux_issues != dut.u_conv_engine.u_pe_array.round_limit_reg + 1 ||
                        tmux_returns != dut.u_conv_engine.u_pe_array.round_limit_reg + 1) begin
                        $fdisplay(fd, "FAIL TMUX commit without configured rounds"); $finish;
                    end
                    tmux_open = 0;
                end
                tmux_committed = tmux_committed + 1;
            end
            // The previous window may commit on the same edge as the queued
            // next window launches.  Retire the old transaction first.
            if (dut.u_conv_engine.u_pe_array.accept_direct ||
                dut.u_conv_engine.u_pe_array.launch_pending) begin
                if (tmux_open) begin
                    $fdisplay(fd, "FAIL TMUX overlapping windows"); $finish;
                end
                tmux_open = 1;
                tmux_accepted = tmux_accepted + 1;
                tmux_issues = 0; tmux_returns = 0;
                tmux_window = dut.u_conv_engine.u_pe_array.launch_pending
                    ? dut.u_conv_engine.u_pe_array.pending_window_reg
                    : dut.u_conv_engine.lb_win_flat;
                tmux_weights = dut.u_conv_engine.wb_weights_bus;
                tmux_metadata = dut.u_conv_engine.u_pe_array.launch_pending
                    ? {dut.u_conv_engine.u_pe_array.pending_x_reg,
                       dut.u_conv_engine.u_pe_array.pending_y_reg,
                       dut.u_conv_engine.u_pe_array.pending_first_reg,
                       dut.u_conv_engine.u_pe_array.pending_last_reg}
                    : {dut.u_conv_engine.lb_x, dut.u_conv_engine.lb_y,
                       dut.u_conv_engine.is_first_cin_reg,
                       dut.u_conv_engine.is_last_cin_reg};
            end
            if (|dut.u_conv_engine.pe_valid_bus) begin
                if (dut.u_conv_engine.pe_valid_bus !== 16'hffff) begin
                    $fdisplay(fd, "FAIL TMUX non-atomic logical output"); $finish;
                end
            end
        end
    end

    // Independently check actual SRAM contents one clock after each write.
    genvar lane;
    generate
        for (lane = 0; lane < 16; lane = lane + 1) begin : CHECK_SRAM
            reg [12:0] address;
            reg [7:0] value;
            always @(posedge clk) begin
                if (rst_n && output_valid) begin
                    address = output_addr;
                    value = output_data[lane*8 +: 8];
                    #1;
                    if (dut.u_pong_array.gen_sram_bank[lane].mem[address] !== value) begin
                        $fdisplay(fd, "FAIL SRAM lane=%0d addr=%0d", lane, address); $finish;
                    end
                end
            end
        end
    endgenerate
endmodule
