`timescale 1ns/1ps
// Two-row PSUM building block. NOT a drop-in replacement for the original
// channel_accumulator: the upstream scheduler must finish ALL Cin of a tile
// before moving to the next tile. Coordinates are global convolution-output
// coordinates (before pooling), not input-window/halo coordinates.
module channel_accumulator #(
    parameter integer MAX_WIDTH = 160,
    parameter integer TILE_ROWS = 2
)(
    input  wire clk,
    input  wire rst_n,
    input  wire tile_start,
    output wire tile_ready,
    input  wire [7:0] cfg_width,
    input  wire [7:0] cfg_tile_y_base,
    input  wire [7:0] cfg_tile_rows,
    output wire mac_ready,
    input  wire signed [19:0] mac_data,
    input  wire mac_valid,
    input  wire [7:0] mac_x,
    input  wire [7:0] mac_y,
    input  wire is_first_cin,
    input  wire is_last_cin,
    output reg signed [31:0] final_sum,
    output reg final_valid,
    output reg [7:0] final_x,
    output reg [7:0] final_y,
    output reg tile_done,
    output reg protocol_error
);
    function integer clog2;
        input integer n;
        integer v;
        begin
            v = n - 1;
            clog2 = 0;
            while (v > 0) begin
                clog2 = clog2 + 1;
                v = v >> 1;
            end
            if (clog2 == 0) clog2 = 1;
        end
    endfunction
    localparam integer DEPTH = MAX_WIDTH * TILE_ROWS;
    localparam integer AW = clog2(DEPTH);
    (* syn_ramstyle = "block_ram", ram_style = "block" *)
    reg signed [31:0] psum_ram [0:DEPTH-1];
    reg signed [31:0] ram_q;

    reg active, input_closed;
    reg [7:0] width_r, base_r, rows_r;
    reg [15:0] pixel_count, last_input_count, result_count;
    reg valid_d1, first_d1, last_d1;
    reg [AW-1:0] addr_d1;
    reg signed [19:0] data_d1;
    reg [7:0] x_d1, y_d1;
    reg fwd_valid;
    reg [AW-1:0] fwd_addr;
    reg signed [31:0] fwd_data;

    wire [8:0] config_end_y = {1'b0,cfg_tile_y_base} + {1'b0,cfg_tile_rows};
    wire config_ok = cfg_width != 0 && cfg_width <= MAX_WIDTH &&
                     cfg_tile_rows != 0 && cfg_tile_rows <= TILE_ROWS &&
                     config_end_y <= 9'd256;
    wire [8:0] end_y = {1'b0,base_r} + {1'b0,rows_r};
    wire coord_ok = mac_x < width_r && mac_y >= base_r &&
                    {1'b0,mac_y} < end_y;
    wire [7:0] local_y = mac_y - base_r;
    wire [15:0] local_addr = local_y * width_r + mac_x;
    assign tile_ready = rst_n && !active && !valid_d1;
    assign mac_ready = rst_n && active && !input_closed;
    wire fire = mac_valid && mac_ready && coord_ok;
    wire [AW-1:0] read_addr = (fire && !(is_first_cin && is_last_cin))
                            ? local_addr[AW-1:0] : {AW{1'b0}};
    wire signed [31:0] mac_ext = {{12{data_d1[19]}},data_d1};
    wire signed [31:0] previous_sum =
        (fwd_valid && fwd_addr == addr_d1) ? fwd_data : ram_q;
    wire signed [31:0] updated_sum = first_d1 ? mac_ext : previous_sum + mac_ext;
    wire write_en = rst_n && valid_d1 && !last_d1;

    // Synchronous simple dual-port RAM; never reset/clear the RAM array.
    // First-Cin writes initialize each address before a later Cin uses it.
    always @(posedge clk) begin
        ram_q <= psum_ram[read_addr];
        if (write_en) psum_ram[addr_d1] <= updated_sum;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 0; input_closed <= 0;
            width_r <= 0; base_r <= 0; rows_r <= 0;
            pixel_count <= 0; last_input_count <= 0; result_count <= 0;
            valid_d1 <= 0; first_d1 <= 0; last_d1 <= 0;
            addr_d1 <= 0; data_d1 <= 0; x_d1 <= 0; y_d1 <= 0;
            fwd_valid <= 0; fwd_addr <= 0; fwd_data <= 0;
            final_sum <= 0; final_valid <= 0; final_x <= 0; final_y <= 0;
            tile_done <= 0; protocol_error <= 0;
        end else begin
            final_valid <= 0;
            tile_done <= 0;
            valid_d1 <= fire;
            fwd_valid <= write_en;
            if (write_en) begin
                fwd_addr <= addr_d1;
                fwd_data <= updated_sum;
            end
            if (tile_start) begin
                if (tile_ready && config_ok) begin
                    active <= 1;
                    input_closed <= 0;
                    width_r <= cfg_width;
                    base_r <= cfg_tile_y_base;
                    rows_r <= cfg_tile_rows;
                    pixel_count <= cfg_width * cfg_tile_rows;
                    last_input_count <= 0;
                    result_count <= 0;
                    fwd_valid <= 0;
                end else protocol_error <= 1;
            end
            // Diagnostic only: upstream must obey ready and valid coordinates.
            // This block does not verify full Cin ordering/unique coordinates.
            if (mac_valid && (!mac_ready || !coord_ok)) protocol_error <= 1;
            if (fire) begin
                addr_d1 <= local_addr[AW-1:0];
                data_d1 <= mac_data;
                x_d1 <= mac_x; y_d1 <= mac_y;
                first_d1 <= is_first_cin;
                last_d1 <= is_last_cin;
                if (is_last_cin) begin
                    last_input_count <= last_input_count + 1'b1;
                    if (last_input_count == pixel_count - 1'b1) input_closed <= 1;
                end
            end
            if (valid_d1 && last_d1) begin
                final_sum <= updated_sum;
                final_valid <= 1;
                final_x <= x_d1; final_y <= y_d1;
                result_count <= result_count + 1'b1;
                if (result_count == pixel_count - 1'b1) begin
                    active <= 0;
                    tile_done <= 1;
                end
            end
        end
    end
endmodule
