// -----------------------------------------------------------------------------
// weight_sdram_dma
// -----------------------------------------------------------------------------
// SDRAM-backed replacement for weight_rom_dma / axi_weight_dma.
//
// The sequencer and buffer-facing contracts are intentionally identical to
// axi_weight_dma.  The memory-side contract follows Step 20.0 §7.1:
//   * req_valid/req_ready submits one absolute halfword-addressed read command;
//   * rd_valid/rd_data returns one 16-bit halfword per valid cycle;
//   * v1 issues one outstanding request of exactly two halfwords per 32-bit
//     parameter word, in little-endian order {high16, low16}.
//
// This module owns no SDRAM controller timing.  sdram_top_mm must provide the
// CDC, arbitration and burst-boundary ownership specified by the interface.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module weight_sdram_dma #(
    // v2 default is 17 parameter-word bits. ADDR_W remains as a compatibility
    // alias for older unit benches; production code sets PARAM_ADDR_W.
    // Bank 3 permits at most 21 word-address bits (8 MiB total).
    parameter integer PARAM_ADDR_W = 17,
    parameter integer ADDR_W = PARAM_ADDR_W,
    parameter [23:0] PARAM_BASE_16 = 24'hc0_0000
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Sequencer request: offsets are PARAM_ADDR_W/ADDR_W parameter-word indices.
    input  wire                  i_dma_req,
    input  wire [ADDR_W-1:0]     i_dma_base_addr,
    input  wire [ADDR_W-1:0]     i_bias_base_addr,
    input  wire [15:0]           i_dma_length,
    input  wire [1:0]            i_kernel_size,
    output reg                   o_dma_ack,
    output reg                   o_dma_done,

    // weight_buffer write protocol
    output reg  [143:0]          o_weight_data,
    output reg                   o_weight_valid,
    output reg  [9:0]            o_weight_addr,
    output reg                   o_update_weights_en,

    // bias_buffer write protocol
    output reg  [31:0]           o_bias_data,
    output reg                   o_bias_valid,
    output reg  [4:0]            o_bias_addr,
    output reg                   o_update_bias_en,

    // sdram_top_mm NPU read master, all sampled in clk/I_npu_rd_clk domain.
    output wire                  o_sdram_rd_req_valid,
    input  wire                  i_sdram_rd_req_ready,
    output wire [23:0]           o_sdram_rd_addr,
    output wire [15:0]           o_sdram_rd_len_halfwords,
    input  wire [15:0]           i_sdram_rd_data,
    input  wire                  i_sdram_rd_valid,

    output wire [3:0]            o_dbg_state,
    output wire [15:0]           o_dbg_words_left,
    output wire [4:0]            o_dbg_bias_count
);

    generate
        if ((PARAM_ADDR_W < 17) || (PARAM_ADDR_W > 21) ||
            (ADDR_W != PARAM_ADDR_W)) begin : g_invalid_param_addr_w
            initial begin
                $error("weight_sdram_dma requires PARAM_ADDR_W 17..21 and ADDR_W match");
                $finish;
            end
        end
    endgenerate

    localparam ST_IDLE       = 4'd0;
    localparam ST_ACK        = 4'd1;
    localparam ST_W_REQ      = 4'd2;
    localparam ST_W_READ     = 4'd3;
    localparam ST_W_CONSUME  = 4'd4;
    localparam ST_W_DRAIN    = 4'd5;
    localparam ST_W_COMMIT   = 4'd6;
    localparam ST_B_REQ      = 4'd7;
    localparam ST_B_READ     = 4'd8;
    localparam ST_B_COMMIT   = 4'd9;
    localparam ST_DONE       = 4'd10;

    reg [3:0]  state, next_state;
    reg [23:0] r_sdram_addr;
    reg [15:0] r_words_left;
    reg        r_halfword_seen;
    reg [15:0] r_low_halfword;
    reg [31:0] r_word_buf;
    reg [1:0]  r_byte_in_word;
    reg [4:0]  r_bias_cnt;
    reg [3:0]  r_k2_locked;

    // 144-bit weight entry assembler, kept cycle-compatible with axi_weight_dma.
    reg [4:0]  r_cin_local;
    reg [3:0]  r_oc_pair;
    reg        r_half;
    reg [3:0]  r_byte_in_half;
    reg [71:0] r_even_buf;
    reg [71:0] r_odd_buf;

    reg [143:0] r_pending_data;
    reg         r_pending_valid;
    reg [9:0]   r_pending_addr;

    assign o_dbg_state      = state;
    assign o_dbg_words_left = r_words_left;
    assign o_dbg_bias_count = r_bias_cnt;

    wire [23:0] w_weight_start_addr =
        PARAM_BASE_16 + ({{(24-ADDR_W){1'b0}}, i_dma_base_addr} << 1);
    wire [23:0] w_bias_start_addr =
        PARAM_BASE_16 + ({{(24-ADDR_W){1'b0}}, i_bias_base_addr} << 1);

    wire w_req_fire = o_sdram_rd_req_valid && i_sdram_rd_req_ready;
    wire w_word_byte_done = (r_byte_in_word == 2'd3);
    wire w_more_words = (r_words_left != 16'd0);
    wire [7:0] w_cur_byte = r_word_buf[r_byte_in_word*8 +: 8];
    wire w_pair_last_byte = (r_half == 1'b1) &&
                            (r_byte_in_half == r_k2_locked - 4'd1);

    wire [3:0] w_k2_decode = (i_kernel_size == 2'b10) ? 4'd9 :
                              (i_kernel_size == 2'b01) ? 4'd4 : 4'd1;

    assign o_sdram_rd_req_valid = (state == ST_W_REQ) || (state == ST_B_REQ);
    assign o_sdram_rd_addr = r_sdram_addr;
    assign o_sdram_rd_len_halfwords = 16'd2;

    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE:      if (i_dma_req) next_state = ST_ACK;
            ST_ACK:       if (i_dma_length == 16'd0) next_state = ST_W_DRAIN;
                          else                        next_state = ST_W_REQ;
            ST_W_REQ:     if (w_req_fire) next_state = ST_W_READ;
            ST_W_READ:    if (i_sdram_rd_valid && r_halfword_seen)
                                                  next_state = ST_W_CONSUME;
            ST_W_CONSUME: if (w_word_byte_done) begin
                              if (w_more_words) next_state = ST_W_REQ;
                              else              next_state = ST_W_DRAIN;
                          end
            ST_W_DRAIN:                         next_state = ST_W_COMMIT;
            ST_W_COMMIT:                        next_state = ST_B_REQ;
            ST_B_REQ:     if (w_req_fire) next_state = ST_B_READ;
            ST_B_READ:    if (i_sdram_rd_valid && r_halfword_seen) begin
                              if (r_bias_cnt == 5'd15) next_state = ST_B_COMMIT;
                              else                     next_state = ST_B_REQ;
                          end
            ST_B_COMMIT:                        next_state = ST_DONE;
            ST_DONE:                            next_state = ST_IDLE;
            default:                            next_state = ST_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= ST_IDLE;
        else
            state <= next_state;
    end

    // Memory command address and two-halfword -> one-word assembly.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_sdram_addr    <= 24'd0;
            r_words_left    <= 16'd0;
            r_halfword_seen <= 1'b0;
            r_low_halfword  <= 16'd0;
            r_word_buf      <= 32'd0;
            r_byte_in_word  <= 2'd0;
            r_bias_cnt      <= 5'd0;
            r_k2_locked     <= 4'd1;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (i_dma_req) begin
                        r_sdram_addr    <= w_weight_start_addr;
                        r_words_left    <= i_dma_length;
                        r_halfword_seen <= 1'b0;
                        r_k2_locked     <= w_k2_decode;
                    end
                end
                ST_W_REQ, ST_B_REQ: begin
                    if (w_req_fire) begin
                        r_sdram_addr    <= r_sdram_addr + 24'd2;
                        r_halfword_seen <= 1'b0;
                    end
                end
                ST_W_READ: begin
                    if (i_sdram_rd_valid) begin
                        if (!r_halfword_seen) begin
                            r_low_halfword  <= i_sdram_rd_data;
                            r_halfword_seen <= 1'b1;
                        end else begin
                            r_word_buf      <= {i_sdram_rd_data, r_low_halfword};
                            r_byte_in_word  <= 2'd0;
                            r_halfword_seen <= 1'b0;
                            if (r_words_left != 16'd0)
                                r_words_left <= r_words_left - 16'd1;
                        end
                    end
                end
                ST_W_CONSUME: begin
                    if (!w_word_byte_done)
                        r_byte_in_word <= r_byte_in_word + 2'd1;
                end
                ST_W_COMMIT: begin
                    r_sdram_addr <= w_bias_start_addr;
                    r_bias_cnt   <= 5'd0;
                end
                ST_B_READ: begin
                    if (i_sdram_rd_valid) begin
                        if (!r_halfword_seen) begin
                            r_low_halfword  <= i_sdram_rd_data;
                            r_halfword_seen <= 1'b1;
                        end else begin
                            r_halfword_seen <= 1'b0;
                            r_bias_cnt      <= r_bias_cnt + 5'd1;
                        end
                    end
                end
                default: ;
            endcase
        end
    end

    // Weight byte stream -> paired 72-bit entries.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_cin_local    <= 5'd0;
            r_oc_pair      <= 4'd0;
            r_half         <= 1'b0;
            r_byte_in_half <= 4'd0;
            r_even_buf     <= 72'd0;
            r_odd_buf      <= 72'd0;
        end else if (state == ST_IDLE && i_dma_req) begin
            r_cin_local    <= 5'd0;
            r_oc_pair      <= 4'd0;
            r_half         <= 1'b0;
            r_byte_in_half <= 4'd0;
            r_even_buf     <= 72'd0;
            r_odd_buf      <= 72'd0;
        end else if (state == ST_W_CONSUME) begin
            if (r_half == 1'b0)
                r_even_buf[r_byte_in_half*8 +: 8] <= w_cur_byte;
            else
                r_odd_buf[r_byte_in_half*8 +: 8] <= w_cur_byte;

            if (r_byte_in_half == r_k2_locked - 4'd1) begin
                r_byte_in_half <= 4'd0;
                if (r_half == 1'b0) begin
                    r_half <= 1'b1;
                end else begin
                    r_half     <= 1'b0;
                    r_even_buf <= 72'd0;
                    r_odd_buf  <= 72'd0;
                    if (r_oc_pair == 4'd14) begin
                        r_oc_pair   <= 4'd0;
                        r_cin_local <= r_cin_local + 5'd1;
                    end else begin
                        r_oc_pair <= r_oc_pair + 4'd2;
                    end
                end
            end else begin
                r_byte_in_half <= r_byte_in_half + 4'd1;
            end
        end
    end

    wire [71:0] w_odd_final = r_odd_buf |
                             ({64'd0, w_cur_byte} << (r_byte_in_half * 8));
    wire [9:0] w_pair_addr = {2'd0, r_cin_local[3:0], r_oc_pair[3:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_pending_data  <= 144'd0;
            r_pending_valid <= 1'b0;
            r_pending_addr  <= 10'd0;
        end else begin
            r_pending_valid <= 1'b0;
            if (state == ST_W_CONSUME && w_pair_last_byte) begin
                r_pending_data  <= {w_odd_final, r_even_buf};
                r_pending_valid <= 1'b1;
                r_pending_addr  <= w_pair_addr;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_weight_data  <= 144'd0;
            o_weight_valid <= 1'b0;
            o_weight_addr  <= 10'd0;
        end else begin
            o_weight_data  <= r_pending_data;
            o_weight_valid <= r_pending_valid;
            o_weight_addr  <= r_pending_addr;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_dma_ack <= 1'b0;
        else        o_dma_ack <= (state == ST_ACK);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_dma_done <= 1'b0;
        else        o_dma_done <= (state == ST_DONE);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_update_weights_en <= 1'b0;
        else begin
            if (state == ST_IDLE && i_dma_req)
                o_update_weights_en <= 1'b1;
            else if (state == ST_W_COMMIT)
                o_update_weights_en <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_bias_data  <= 32'd0;
            o_bias_valid <= 1'b0;
            o_bias_addr  <= 5'd0;
        end else begin
            o_bias_valid <= 1'b0;
            if (state == ST_B_READ && i_sdram_rd_valid && r_halfword_seen) begin
                o_bias_data  <= {i_sdram_rd_data, r_low_halfword};
                o_bias_valid <= 1'b1;
                o_bias_addr  <= r_bias_cnt;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_update_bias_en <= 1'b0;
        else begin
            if (state == ST_W_COMMIT)
                o_update_bias_en <= 1'b1;
            else if (state == ST_B_COMMIT)
                o_update_bias_en <= 1'b0;
        end
    end

endmodule
