// -----------------------------------------------------------------------------
// lbp_to_ping_packer
// -----------------------------------------------------------------------------
// Packs the serial RGB CHW byte stream into the cross-bank layout consumed by
// BCU layer-0 packed-preload mode:
//   byte p = c*19200+y*160+x -> address p[15:4], bank/lane p[3:0].
// Historical i_lbp_* port names now carry raw R, then G, then B bytes.
// Frame admission is latched at frame-valid rising, including a coincident byte.
// A rejected frame stays rejected even if enable rises in its middle.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module lbp_to_ping_packer #(
    parameter FRAME_PIXELS = 3 * 160 * 120
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         i_enable,
    input  wire         i_frame_valid,
    input  wire         i_lbp_valid,
    input  wire [7:0]   i_lbp_pixel,

    output reg          o_preload_wr_en,
    output reg  [12:0]  o_preload_wr_addr,
    output reg  [15:0]  o_preload_wr_mask,
    output reg  [127:0] o_preload_wr_data,
    output reg          o_preload_done,

    output wire [15:0]  o_dbg_pixel_count,
    output wire         o_loading,
    output wire         o_dbg_final_write_pending
);
    reg [15:0] r_pixel_count;
    reg [127:0] r_pack_data;
    reg r_final_write_pending;
    reg r_frame_d;
    reg r_accept;

    assign o_dbg_pixel_count        = r_pixel_count;
    assign o_dbg_final_write_pending = r_final_write_pending;
    assign o_loading = r_accept || r_final_write_pending || o_preload_done;

    wire [3:0] w_lane = r_pixel_count[3:0];
    wire w_accept = r_frame_d ? r_accept : i_enable;
    wire [127:0] w_pack_with_current =
        r_pack_data | ({120'd0, i_lbp_pixel} << (w_lane * 8));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_pixel_count       <= 16'd0;
            r_frame_d           <= 1'b0;
            r_accept            <= 1'b0;
            r_pack_data         <= 128'd0;
            r_final_write_pending <= 1'b0;
            o_preload_wr_en     <= 1'b0;
            o_preload_wr_addr   <= 13'd0;
            o_preload_wr_mask   <= 16'd0;
            o_preload_wr_data   <= 128'd0;
            o_preload_done      <= 1'b0;
        end else begin
            r_frame_d <= i_frame_valid;
            if (i_frame_valid && !r_frame_d) r_accept <= i_enable;
            o_preload_wr_en <= 1'b0;
            o_preload_done  <= 1'b0;

            // Complete the final registered bank write before honoring the
            // low frame-valid re-arm.  npu_preproc deasserts frame_valid on
            // the same edge as its final LBP pixel; on the following cycle
            // this pending completion must win or preload_done is lost.
            if (r_final_write_pending) begin
                // The previous cycle presented the final write to fm_bank_array.
                r_final_write_pending <= 1'b0;
                o_preload_done        <= 1'b1;
                r_accept              <= 1'b0;
            end else if (!i_frame_valid) begin
                // A low frame-valid re-arms the packer for the next source frame.
                r_pixel_count         <= 16'd0;
                r_accept              <= 1'b0;
                r_pack_data           <= 128'd0;
                r_final_write_pending <= 1'b0;
            end else if (w_accept && i_lbp_valid && (r_pixel_count < FRAME_PIXELS)) begin
                if (w_lane == 4'd15 || r_pixel_count == FRAME_PIXELS - 1) begin
                    o_preload_wr_en   <= 1'b1;
                    o_preload_wr_addr <= {1'b0, r_pixel_count[15:4]};
                    o_preload_wr_mask <= 16'hffff >> (4'd15 - w_lane);
                    o_preload_wr_data <= w_pack_with_current;
                    r_pack_data       <= 128'd0;
                    r_pixel_count     <= r_pixel_count + 16'd1;
                    if (r_pixel_count == FRAME_PIXELS - 1)
                        r_final_write_pending <= 1'b1;
                end else begin
                    r_pack_data   <= w_pack_with_current;
                    r_pixel_count <= r_pixel_count + 16'd1;
                end
            end
        end
    end
endmodule
