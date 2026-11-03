// -----------------------------------------------------------------------------
// File   : ethernet_video_ddr_mux.v
// Author : Codex
// Date   : 2026-10-22
// Description:
//   Fair, stall-stable merge of local and Ethernet video DDR requests.
//   In-order read-owner tags keep both video return streams separate.
//   The existing downstream CPU/video arbiter still protects Linux memory.
// Change Log:
//   2026-10-22  Codex  v1.0  Add network video to existing video DDR port.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module ethernet_video_ddr_mux
(
    input  wire         clk,
    input  wire         rst,
    input  wire         local_valid_i,
    input  wire         local_write_i,
    input  wire [24:0]  local_addr_i,
    input  wire [127:0] local_data_i,
    output wire         local_ready_o,
    output wire         local_rvalid_o,
    input  wire         net_valid_i,
    input  wire         net_write_i,
    input  wire [24:0]  net_addr_i,
    input  wire [127:0] net_data_i,
    output wire         net_ready_o,
    output wire         net_rvalid_o,
    output wire         valid_o,
    output wire         write_o,
    output wire [24:0]  addr_o,
    output wire [127:0] data_o,
    input  wire         ready_i,
    input  wire         rvalid_i
);
    reg prefer_net_reg = 1'b0;
    reg locked_reg = 1'b0;
    reg locked_net_reg = 1'b0;
    reg [63:0] owners_reg = 64'd0;
    reg [5:0] write_ptr_reg = 6'd0;
    reg [5:0] read_ptr_reg = 6'd0;
    reg [6:0] count_reg = 7'd0;
    wire select_net;
    wire selected_valid;
    wire push;
    wire pop;
    wire bypass;
    assign select_net = locked_reg ? locked_net_reg :
        net_valid_i && (!local_valid_i || prefer_net_reg);
    assign selected_valid = select_net ? net_valid_i : local_valid_i;
    assign write_o = select_net ? net_write_i : local_write_i;
    assign addr_o = select_net ? net_addr_i : local_addr_i;
    assign data_o = select_net ? net_data_i : local_data_i;
    assign valid_o = selected_valid && (write_o || count_reg < 7'd64);
    assign local_ready_o = !select_net && valid_o && ready_i;
    assign net_ready_o = select_net && valid_o && ready_i;
    assign push = valid_o && ready_i && !write_o;
    assign pop = rvalid_i && count_reg != 7'd0;
    // The downstream range guard may acknowledge an invalid read immediately.
    assign bypass = rvalid_i && count_reg == 7'd0 && push;
    assign local_rvalid_o = (pop && !owners_reg[read_ptr_reg]) || (bypass && !select_net);
    assign net_rvalid_o = (pop && owners_reg[read_ptr_reg]) || (bypass && select_net);
    always @(posedge clk) begin
        if (valid_o && !ready_i) begin
            locked_reg <= 1'b1;
            locked_net_reg <= select_net;
        end
        if (valid_o && ready_i) begin
            locked_reg <= 1'b0;
            prefer_net_reg <= !select_net;
        end
        if (push && !bypass) begin
            owners_reg[write_ptr_reg] <= select_net;
            write_ptr_reg <= write_ptr_reg + 1'b1;
        end
        if (pop) read_ptr_reg <= read_ptr_reg + 1'b1;
        case ({push && !bypass, pop})
            2'b10: count_reg <= count_reg + 1'b1;
            2'b01: count_reg <= count_reg - 1'b1;
            default: count_reg <= count_reg;
        endcase
        if (rst) begin
            prefer_net_reg <= 1'b0;
            locked_reg <= 1'b0;
            locked_net_reg <= 1'b0;
            write_ptr_reg <= 6'd0;
            read_ptr_reg <= 6'd0;
            count_reg <= 7'd0;
        end
    end
endmodule
`resetall
