// File: stereo_gray_frame_buffer.v
// Author: Codex
// Date: 2026-10-02
// Description: Two independently committed Gray8 banks, synchronous random read.
// Change Log: 2026-10-02 Codex v1.0 Stereo stage 5 frame storage.
`resetall
`timescale 1ns / 1ps
`default_nettype none

module stereo_gray_frame_buffer #(
    parameter META_WIDTH = 33
) (
    input  wire clk,
    input  wire rst,
    input  wire frame_start_i,
    input  wire pixel_valid_i,
    input  wire [7:0] gray_i,
    input  wire [7:0] x_i,
    input  wire [6:0] y_i,
    input  wire frame_end_i,
    input  wire frame_abort_i,
    input  wire [META_WIDTH-1:0] metadata_i,
    input  wire [1:0] bank_lock_i,
    input  wire [1:0] bank_release_i,
    input  wire [1:0] bank_discard_i,
    output wire [1:0] bank_valid_o,
    output wire [2*META_WIDTH-1:0] bank_metadata_o,
    output wire writing_o,
    output wire write_bank_o,
    input  wire rd_en_i,
    input  wire rd_bank_i,
    input  wire [13:0] rd_addr_i,
    output wire rd_valid_o,
    output wire [7:0] rd_data_o,
    output wire [31:0] committed_count_o,
    output wire [31:0] drop_count_o,
    output wire [31:0] busy_drop_count_o
);
    // One-hot control. Committed/locked state is carried separately per bank.
    localparam [2:0] WRITE_IDLE = 3'b001, WRITE_ACTIVE = 3'b010, WRITE_DROP = 3'b100;
    reg [2:0] state_reg = WRITE_IDLE, state_next;
    reg bank_reg = 1'b0, bank_next;
    reg [13:0] count_reg = 14'd0, count_next;
    reg [7:0] x_reg = 8'd0, x_next;
    reg [6:0] y_reg = 7'd0, y_next;
    reg [1:0] valid_reg = 2'd0, valid_next;
    reg [2*META_WIDTH-1:0] metadata_reg = {2*META_WIDTH{1'b0}}, metadata_next;
    reg [31:0] committed_reg = 32'd0, committed_next;
    reg [31:0] drop_reg = 32'd0, drop_next;
    reg [31:0] busy_drop_reg = 32'd0, busy_drop_next;
    reg mem_wr_en;
    reg mem_wr_bank;
    reg [13:0] mem_wr_addr;
    reg rd_bank_reg = 1'b0;
    reg rd_valid_reg = 1'b0;
    wire [1:0] free_bank;
    wire rd_allowed;
    wire [7:0] bank_data [0:1];

    // Never reclaim a committed bank in the writer. Only the controller frees it.
    // A release on this edge becomes available on the following edge.
    assign free_bank = ~valid_reg & ~bank_lock_i;
    assign rd_allowed = rd_en_i && rd_addr_i < 14'd14400 && valid_reg[rd_bank_i];
    assign bank_valid_o = valid_reg;
    assign bank_metadata_o = metadata_reg;
    assign writing_o = state_reg == WRITE_ACTIVE;
    assign write_bank_o = bank_reg;
    assign rd_valid_o = rd_valid_reg;
    assign rd_data_o = bank_data[rd_bank_reg];
    assign committed_count_o = committed_reg;
    assign drop_count_o = drop_reg;
    assign busy_drop_count_o = busy_drop_reg;

    always @* begin
        state_next = state_reg;
        bank_next = bank_reg;
        count_next = count_reg;
        x_next = x_reg;
        y_next = y_reg;
        valid_next = valid_reg & ~(bank_release_i | bank_discard_i);
        metadata_next = metadata_reg;
        committed_next = committed_reg;
        drop_next = drop_reg + {31'd0, bank_discard_i[0]} +
                    {31'd0, bank_discard_i[1]};
        busy_drop_next = busy_drop_reg;
        mem_wr_en = 1'b0;
        mem_wr_bank = bank_reg;
        mem_wr_addr = count_reg;

        // Abort and overlapping START discard the active frame, with no commit.
        if (state_reg == WRITE_ACTIVE && (frame_abort_i || frame_start_i)) begin
            state_next = WRITE_DROP;
            drop_next = drop_next + 32'd1;
        end else if (frame_start_i && state_reg != WRITE_ACTIVE) begin
            count_next = 14'd0;
            x_next = 8'd0;
            y_next = 7'd0;
            if (frame_abort_i || free_bank == 2'd0) begin
                state_next = WRITE_DROP;
                drop_next = drop_next + 32'd1;
                if (!frame_abort_i && free_bank == 2'd0)
                    busy_drop_next = busy_drop_reg + 32'd1;
            end else begin
                state_next = WRITE_ACTIVE;
                bank_next = !free_bank[0];
                metadata_next[bank_next*META_WIDTH +: META_WIDTH] = metadata_i;
            end
        end else if (state_reg == WRITE_DROP && (frame_abort_i || frame_end_i)) begin
            state_next = WRITE_IDLE;
        end

        // START+first pixel and END+last pixel are both legal.
        if (state_next == WRITE_ACTIVE) begin
            if (pixel_valid_i) begin
                if (count_next >= 14'd14400 || x_i != x_next || y_i != y_next) begin
                    state_next = WRITE_DROP;
                    drop_next = drop_next + 32'd1;
                end else begin
                    mem_wr_en = 1'b1;
                    mem_wr_bank = bank_next;
                    mem_wr_addr = count_next;
                    count_next = count_next + 14'd1;
                    if (x_next == 8'd159) begin
                        x_next = 8'd0;
                        y_next = y_next + 7'd1;
                    end else begin
                        x_next = x_next + 8'd1;
                    end
                end
            end
            if (frame_end_i) begin
                if (state_next == WRITE_ACTIVE && count_next == 14'd14400) begin
                    valid_next[bank_next] = 1'b1;
                    committed_next = committed_reg + 32'd1;
                end else if (state_next == WRITE_ACTIVE) begin
                    drop_next = drop_next + 32'd1;
                end
                state_next = WRITE_IDLE;
            end
        end
    end

    always @(posedge clk) begin
        state_reg <= state_next;
        bank_reg <= bank_next;
        count_reg <= count_next;
        x_reg <= x_next;
        y_reg <= y_next;
        valid_reg <= valid_next;
        metadata_reg <= metadata_next;
        committed_reg <= committed_next;
        drop_reg <= drop_next;
        busy_drop_reg <= busy_drop_next;
        rd_bank_reg <= rd_bank_i;
        rd_valid_reg <= rd_allowed;
        if (rst) begin
            state_reg <= WRITE_IDLE;
            bank_reg <= 1'b0;
            count_reg <= 14'd0;
            x_reg <= 8'd0;
            y_reg <= 7'd0;
            valid_reg <= 2'd0;
            metadata_reg <= {2*META_WIDTH{1'b0}};
            committed_reg <= 32'd0;
            drop_reg <= 32'd0;
            busy_drop_reg <= 32'd0;
            rd_bank_reg <= 1'b0;
            rd_valid_reg <= 1'b0;
        end
    end

    // Same gated SDP template/attributes as fm_bank_array. No memory reset.
    // Power-of-two depth avoids an over-wide index defeating RAM inference.
    // Only addresses 0..14399 are reachable; 1984 bytes per bank are unused.
    generate
        genvar bank;
        for (bank = 0; bank < 2; bank = bank + 1) begin : gray_bank
            (* syn_ramstyle = "block_ram", ram_style = "block" *)
            reg [7:0] mem[(2**14)-1:0];
            reg [7:0] data_reg;
            always @(posedge clk) begin
                if (!rst && mem_wr_en && mem_wr_bank == bank)
                    mem[mem_wr_addr] <= gray_i;
            end
            always @(posedge clk) begin
                if (!rst && rd_allowed && rd_bank_i == bank)
                    data_reg <= mem[rd_addr_i];
            end
            assign bank_data[bank] = data_reg;
        end
    endgenerate
endmodule
`resetall
