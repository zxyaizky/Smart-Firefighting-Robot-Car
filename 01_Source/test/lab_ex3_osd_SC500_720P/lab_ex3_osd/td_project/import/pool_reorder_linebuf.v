// -----------------------------------------------------------------------------
// File   : pool_reorder_linebuf.v
// Author : OpenAI Codex (integration changes)
// Date   : 2026-09-07
// -----------------------------------------------------------------------------
// Description:
//   Bound raster reorder lifetime to a tile while retaining global coordinates.
// Change Log:
//   2026-09-07  Codex  v2.0  Integrate and simulate two-row partial-sum tiling.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns/1ps
`default_nettype none

`timescale 1ns/1ps

// Small tagged-row raster reorder.  The normal row-level-flush path arrives
// in raster order and uses the direct bypass; the row RAM absorbs bounded
// coordinate lead without requiring a full-frame allocation.
module pool_reorder_linebuf #(
    parameter BUS_WIDTH = 128,
    parameter MAX_WIDTH = 160,
    parameter ROW_BANKS = 3
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 i_clear,
    input  wire                 i_enable,
    input  wire [7:0]           i_width,
    input  wire [7:0]           i_height,
    input  wire [7:0]           i_tile_y_base,
    input  wire [7:0]           i_tile_rows,
    input  wire                 i_in_valid,
    input  wire [BUS_WIDTH-1:0] i_in_data,
    input  wire [7:0]           i_in_x,
    input  wire [7:0]           i_in_y,
    output wire                 o_input_ready,
    output reg  [BUS_WIDTH-1:0] o_out_data,
    output reg                  o_out_valid,
    output wire                 o_busy,
    output reg                  o_error,
    output reg  [7:0]           o_out_x,
    output reg  [7:0]           o_out_y,
    output reg  [7:0]           o_max_live_rows
);
    localparam ROW_MEM_DEPTH = ROW_BANKS * MAX_WIDTH;

    (* ramstyle = "M4K" *)
    reg [BUS_WIDTH-1:0] row_mem [0:ROW_MEM_DEPTH-1];
    reg [MAX_WIDTH-1:0] row_seen [0:ROW_BANKS-1];
    reg [7:0] row_tag [0:ROW_BANKS-1];
    reg row_active [0:ROW_BANKS-1];

    reg frame_active;
    reg [7:0] r_width;
    reg [7:0] r_height;
    reg [7:0] out_x;
    reg [7:0] out_y;
    reg [15:0] input_count;
    reg [15:0] output_count;
    reg [15:0] r_total;
    reg [BUS_WIDTH-1:0] row_mem_q;
    reg [BUS_WIDTH-1:0] direct_data_q;
    reg issue_pending;
    reg issue_was_stored;
    reg [7:0] issue_x;
    reg [7:0] issue_y;

    integer k;
    reg match_found;
    reg free_found;
    reg expected_found;
    reg [1:0] match_bank;
    reg [1:0] free_bank;
    reg [1:0] expected_bank;
    reg [7:0] active_rows;

    wire [7:0] use_width = frame_active ? r_width : i_width;
    wire [7:0] use_height = frame_active ? r_height : i_height;
    wire input_is_expected = (i_in_x == out_x) && (i_in_y == out_y);
    wire coord_valid = (use_width != 0) && (use_height != 0) &&
                       (use_width <= MAX_WIDTH) &&
                       (i_in_x < use_width) && (i_in_y < use_height) &&
                       (i_in_y >= i_tile_y_base) &&
                       ({1'b0, i_in_y} < {1'b0, i_tile_y_base} + {1'b0, i_tile_rows});
    wire stored_issue = frame_active && expected_found;
    wire can_direct = input_is_expected && !stored_issue;

    function [15:0] row_base;
        input [1:0] bank;
        begin
            case (bank)
                2'd0: row_base = 16'd0;
                2'd1: row_base = MAX_WIDTH;
                2'd2: row_base = MAX_WIDTH * 2;
                default: row_base = 16'd0;
            endcase
        end
    endfunction

    always @(*) begin
        match_found = 1'b0;
        free_found = 1'b0;
        expected_found = 1'b0;
        match_bank = 0;
        free_bank = 0;
        expected_bank = 0;
        active_rows = 0;
        for (k = 0; k < ROW_BANKS; k = k + 1) begin
            if (row_active[k]) begin
                active_rows = active_rows + 1'b1;
                if (!match_found && row_tag[k] == i_in_y) begin
                    match_found = 1'b1;
                    match_bank = k[1:0];
                end
                if (!expected_found && row_tag[k] == out_y && row_seen[k][out_x]) begin
                    expected_found = 1'b1;
                    expected_bank = k[1:0];
                end
            end else if (!free_found) begin
                free_found = 1'b1;
                free_bank = k[1:0];
            end
        end
    end

    // i_in_x/i_in_y are meaningful only with i_in_valid.  In particular they
    // retain the previous layer's final coordinate while a new layer is just
    // starting.  Applying coord_valid during that idle interval feeds a false
    // backpressure all the way to the BCU and prevents the first pixel of the
    // new layer from ever entering the pipeline.
    assign o_input_ready = !i_enable || !i_in_valid ? 1'b1 :
                           (!frame_active ? coord_valid :
                            (input_count < r_total &&
                             coord_valid && (can_direct || match_found || free_found)));
    wire in_fire = i_enable && i_in_valid && o_input_ready;
    wire direct_issue = in_fire && can_direct;
    wire output_issue = stored_issue || direct_issue;
    wire [15:0] total_count = {8'd0, use_width} * {8'd0, i_tile_rows};
    wire output_is_last = output_issue && (output_count + 16'd1 == total_count);

    wire [15:0] stored_addr = row_base(expected_bank) + out_x;
    wire [1:0] write_bank = match_found ? match_bank : free_bank;
    wire [15:0] write_addr = row_base(write_bank) + i_in_x;
    wire store_input = in_fire && !direct_issue;

    assign o_busy = i_enable &&
                    (frame_active || issue_pending || o_out_valid ||
                     (active_rows != 0));

    // Keep the RAM in a clock-only process.  In particular, do not put its
    // read port in the asynchronously-reset control process below: eLinx then
    // treats the read as asynchronous and expands the entire array into LCs.
    // row_mem_q is the registered (one-cycle) RAM output.
    always @(posedge clk) begin
        if (store_input)
            row_mem[write_addr] <= i_in_data;
        if (stored_issue)
            row_mem_q <= row_mem[stored_addr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_active <= 1'b0;
            r_width <= 0;
            r_height <= 0;
            out_x <= 0;
            out_y <= 0;
            input_count <= 0;
            output_count <= 0;
            r_total <= 0;
            o_out_data <= 0;
            o_out_valid <= 1'b0;
            o_out_x <= 0;
            o_out_y <= 0;
            o_error <= 1'b0;
            o_max_live_rows <= 0;
            direct_data_q <= 0;
            issue_pending <= 1'b0;
            issue_was_stored <= 1'b0;
            issue_x <= 0;
            issue_y <= 0;
            for (k = 0; k < ROW_BANKS; k = k + 1) begin
                row_active[k] <= 1'b0;
                row_tag[k] <= 0;
                row_seen[k] <= 0;
            end
        end else if (i_clear || !i_enable) begin
            frame_active <= 1'b0;
            r_width <= 0;
            r_height <= 0;
            out_x <= 0;
            out_y <= i_tile_y_base;
            input_count <= 0;
            output_count <= 0;
            r_total <= 0;
            o_out_valid <= 1'b0;
            o_out_x <= 0;
            o_out_y <= i_tile_y_base;
            o_error <= 1'b0;
            o_max_live_rows <= 0;
            issue_pending <= 1'b0;
            issue_was_stored <= 1'b0;
            for (k = 0; k < ROW_BANKS; k = k + 1) begin
                row_active[k] <= 1'b0;
                row_seen[k] <= 0;
            end
        end else begin
            // Align both the RAM and direct-bypass paths to the synchronous
            // RAM latency, so their externally visible ordering is identical.
            o_out_valid <= issue_pending;
            if (issue_pending) begin
                o_out_data <= issue_was_stored ? row_mem_q : direct_data_q;
                o_out_x <= issue_x;
                o_out_y <= issue_y;
            end
            issue_pending <= output_issue;
            if (output_issue) begin
                issue_was_stored <= stored_issue;
                direct_data_q <= i_in_data;
                issue_x <= out_x;
                issue_y <= out_y;
            end
            if (active_rows > o_max_live_rows)
                o_max_live_rows <= active_rows;

            if (i_in_valid && !o_input_ready)
                o_error <= 1'b1;
            if (i_in_valid && (!coord_valid || (frame_active && i_in_y < out_y)))
                o_error <= 1'b1;

            if (in_fire) begin
                if (!frame_active) begin
                    frame_active <= 1'b1;
                    r_width <= i_width;
                    r_height <= i_height;
                    r_total <= {8'd0, i_width} * {8'd0, i_tile_rows};
                end
                input_count <= input_count + 1'b1;
            end

            if (store_input) begin
                if (match_found && row_seen[match_bank][i_in_x])
                    o_error <= 1'b1;
                if (match_found) begin
                    row_seen[match_bank][i_in_x] <= 1'b1;
                end else if (free_found) begin
                    row_active[free_bank] <= 1'b1;
                    row_tag[free_bank] <= i_in_y;
                    row_seen[free_bank] <=
                        ({{(MAX_WIDTH-1){1'b0}}, 1'b1} << i_in_x);
                end else begin
                    o_error <= 1'b1;
                end
            end

            if (stored_issue) begin
                row_seen[expected_bank][out_x] <= 1'b0;
                if (out_x == r_width - 1'b1) begin
                    row_active[expected_bank] <= 1'b0;
                    row_seen[expected_bank] <= 0;
                end
            end

            if (output_issue) begin
                output_count <= output_count + 1'b1;
                if (out_x == use_width - 1'b1) begin
                    out_x <= 0;
                    out_y <= out_y + 1'b1;
                end else begin
                    out_x <= out_x + 1'b1;
                end
            end

            if (output_is_last) begin
                frame_active <= 1'b0;
                input_count <= 0;
                output_count <= 0;
                r_total <= 0;
                out_x <= 0;
                out_y <= 0;
                for (k = 0; k < ROW_BANKS; k = k + 1) begin
                    row_active[k] <= 1'b0;
                    row_seen[k] <= 0;
                end
            end
        end
    end
endmodule

`resetall
