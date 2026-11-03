// -----------------------------------------------------------------------------
// File   : npu_u33_mcu_bridge.v
// Author : Codex
// Date   : 2026-09-12
// Description: Accept the PH1P35 hard-MCU AHB copy stream and feed the existing
//              128-bit DDR parameter loader across the AHB/DDR clock boundary.
//              The MCU copies the U33 XIP window to sequential AHB addresses.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

module npu_u33_mcu_bridge #(
    parameter [23:0] PARAM_SIZE_BYTES = 24'd327680,
    parameter [31:0] PARAM_CRC32 = 32'he27c4b4d,
    parameter integer FIFO_ADDR_WIDTH = 3
) (
    input  wire         clk_ahb,
    input  wire         rst_ahb,
    input  wire [1:0]   i_htrans,
    input  wire         i_hwrite,
    input  wire [30:0]  i_haddr,
    input  wire [2:0]   i_hsize,
    input  wire [31:0]  i_hwdata,
    output wire [31:0]  o_hrdata,
    output wire [1:0]   o_hresp,
    output wire         o_hready,

    input  wire         clk_ddr,
    input  wire         rst_ddr,
    output wire         o_load_begin_valid,
    input  wire         i_load_begin_ready,
    output wire [23:0]  o_load_size_bytes,
    output wire [31:0]  o_load_crc32,
    output wire         o_load_valid,
    input  wire         i_load_ready,
    output wire [127:0] o_load_data,
    output wire         o_load_last,
    output wire         o_done,
    output wire         o_error
);

    localparam integer FIFO_DEPTH = 1 << FIFO_ADDR_WIDTH;
    localparam integer FIFO_PTR_WIDTH = FIFO_ADDR_WIDTH + 1;
    localparam [18:0] LAST_WORD_ADDR = PARAM_SIZE_BYTES - 24'd4;
    localparam [15:0] BLOCK_COUNT = PARAM_SIZE_BYTES >> 4;

    reg [127:0] fifo_mem [0:FIFO_DEPTH-1];

    reg [FIFO_PTR_WIDTH-1:0] wr_bin_q;
    reg [FIFO_PTR_WIDTH-1:0] wr_gray_q;
    reg [FIFO_PTR_WIDTH-1:0] rd_gray_ahb_meta_q;
    reg [FIFO_PTR_WIDTH-1:0] rd_gray_ahb_sync_q;
    reg [127:0] pack_q;
    reg [18:0] expected_addr_q;
    reg data_phase_q;
    reg data_write_q;
    reg [18:0] data_addr_q;
    reg [2:0] data_size_q;
    reg ingress_done_q;
    reg ahb_error_q;

    reg [FIFO_PTR_WIDTH-1:0] rd_bin_q;
    reg [FIFO_PTR_WIDTH-1:0] rd_gray_q;
    reg [FIFO_PTR_WIDTH-1:0] wr_gray_ddr_meta_q;
    reg [FIFO_PTR_WIDTH-1:0] wr_gray_ddr_sync_q;
    reg begin_done_q;
    reg [15:0] blocks_sent_q;
    reg done_q;
    reg ahb_error_ddr_meta_q;
    reg ahb_error_ddr_sync_q;

    wire [FIFO_PTR_WIDTH-1:0] wr_bin_next;
    wire [FIFO_PTR_WIDTH-1:0] wr_gray_next;
    wire [FIFO_PTR_WIDTH-1:0] rd_bin_next;
    wire [FIFO_PTR_WIDTH-1:0] rd_gray_next;
    wire fifo_full;
    wire fifo_empty;
    wire valid_data_phase;
    wire final_word_phase;
    wire accept_data_phase;
    wire push_block;
    wire pop_block;

    assign wr_bin_next = wr_bin_q + {{FIFO_PTR_WIDTH-1{1'b0}}, 1'b1};
    assign wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    assign rd_bin_next = rd_bin_q + {{FIFO_PTR_WIDTH-1{1'b0}}, 1'b1};
    assign rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    assign fifo_full = wr_gray_next ==
        {~rd_gray_ahb_sync_q[FIFO_PTR_WIDTH-1:FIFO_PTR_WIDTH-2],
         rd_gray_ahb_sync_q[FIFO_PTR_WIDTH-3:0]};
    assign fifo_empty = rd_gray_q == wr_gray_ddr_sync_q;

    assign valid_data_phase = data_phase_q && data_write_q &&
        data_size_q == 3'b010 && data_addr_q[1:0] == 2'b00 &&
        data_addr_q == expected_addr_q && !ingress_done_q;
    assign final_word_phase = valid_data_phase && data_addr_q[3:2] == 2'b11;
    assign accept_data_phase = !data_phase_q || !final_word_phase || !fifo_full;
    assign o_hready = accept_data_phase;
    assign push_block = data_phase_q && o_hready && final_word_phase;

    assign o_hrdata = 32'd0;
    assign o_hresp = 2'b00;

    assign o_load_begin_valid = !begin_done_q;
    assign o_load_size_bytes = PARAM_SIZE_BYTES;
    assign o_load_crc32 = PARAM_CRC32;
    assign o_load_valid = begin_done_q && !fifo_empty;
    assign o_load_data = fifo_mem[rd_bin_q[FIFO_ADDR_WIDTH-1:0]];
    assign o_load_last = o_load_valid && blocks_sent_q == BLOCK_COUNT - 16'd1;
    assign pop_block = o_load_valid && i_load_ready;
    assign o_done = done_q;
    assign o_error = ahb_error_ddr_sync_q;

    always @(posedge clk_ahb) begin
        if (rst_ahb) begin
            wr_bin_q <= {FIFO_PTR_WIDTH{1'b0}};
            wr_gray_q <= {FIFO_PTR_WIDTH{1'b0}};
            rd_gray_ahb_meta_q <= {FIFO_PTR_WIDTH{1'b0}};
            rd_gray_ahb_sync_q <= {FIFO_PTR_WIDTH{1'b0}};
            pack_q <= 128'd0;
            expected_addr_q <= 19'd0;
            data_phase_q <= 1'b0;
            data_write_q <= 1'b0;
            data_addr_q <= 19'd0;
            data_size_q <= 3'd0;
            ingress_done_q <= 1'b0;
            ahb_error_q <= 1'b0;
        end else begin
            rd_gray_ahb_meta_q <= rd_gray_q;
            rd_gray_ahb_sync_q <= rd_gray_ahb_meta_q;

            if (data_phase_q && o_hready) begin
                if (!valid_data_phase) begin
                    ahb_error_q <= 1'b1;
                end else begin
                    case (data_addr_q[3:2])
                        2'd0: pack_q[31:0] <= i_hwdata;
                        2'd1: pack_q[63:32] <= i_hwdata;
                        2'd2: pack_q[95:64] <= i_hwdata;
                        default: pack_q[127:96] <= i_hwdata;
                    endcase
                    expected_addr_q <= expected_addr_q + 19'd4;
                    if (data_addr_q == LAST_WORD_ADDR)
                        ingress_done_q <= 1'b1;
                end
            end

            if (push_block) begin
                fifo_mem[wr_bin_q[FIFO_ADDR_WIDTH-1:0]] <=
                    {i_hwdata, pack_q[95:0]};
                wr_bin_q <= wr_bin_next;
                wr_gray_q <= wr_gray_next;
            end

            if (o_hready) begin
                data_phase_q <= i_htrans[1];
                if (i_htrans[1]) begin
                    data_write_q <= i_hwrite;
                    data_addr_q <= i_haddr[18:0];
                    data_size_q <= i_hsize;
                end
            end
        end
    end

    always @(posedge clk_ddr) begin
        if (rst_ddr) begin
            rd_bin_q <= {FIFO_PTR_WIDTH{1'b0}};
            rd_gray_q <= {FIFO_PTR_WIDTH{1'b0}};
            wr_gray_ddr_meta_q <= {FIFO_PTR_WIDTH{1'b0}};
            wr_gray_ddr_sync_q <= {FIFO_PTR_WIDTH{1'b0}};
            begin_done_q <= 1'b0;
            blocks_sent_q <= 16'd0;
            done_q <= 1'b0;
            ahb_error_ddr_meta_q <= 1'b0;
            ahb_error_ddr_sync_q <= 1'b0;
        end else begin
            wr_gray_ddr_meta_q <= wr_gray_q;
            wr_gray_ddr_sync_q <= wr_gray_ddr_meta_q;
            ahb_error_ddr_meta_q <= ahb_error_q;
            ahb_error_ddr_sync_q <= ahb_error_ddr_meta_q;

            if (!begin_done_q && i_load_begin_ready)
                begin_done_q <= 1'b1;

            if (pop_block) begin
                rd_bin_q <= rd_bin_next;
                rd_gray_q <= rd_gray_next;
                blocks_sent_q <= blocks_sent_q + 16'd1;
                if (o_load_last)
                    done_q <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
