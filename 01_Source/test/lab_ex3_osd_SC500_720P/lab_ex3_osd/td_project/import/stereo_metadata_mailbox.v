// -----------------------------------------------------------------------------
// File   : stereo_metadata_mailbox.v
// Author : Codex
// Date   : 2026-10-02
// Description: One-entry bundled-data CDC with a request/acknowledgment handshake.
// Change Log: 2026-10-02 v1.0 Stage 2 display-page metadata transport.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none
module stereo_metadata_mailbox #
(
    // Number of stable metadata bits per transfer.
    parameter DATA_WIDTH = 34
)
(
    input  wire                  clk_source,
    input  wire                  rst_source,
    input  wire                  clk_dest,
    input  wire                  rst_dest,
    input  wire                  send_i,
    input  wire [DATA_WIDTH-1:0] data_i,
    output wire                  ready_o,
    output wire                  overflow_o,
    output wire                  event_o,
    output wire [DATA_WIDTH-1:0] data_o
);
    reg [DATA_WIDTH-1:0] held_reg = {DATA_WIDTH{1'b0}};
    reg request_reg = 1'b0;
    reg acknowledge_reg = 1'b0;
    (* async_reg = "true" *) reg [1:0] acknowledge_sync_reg = 2'b00;
    (* async_reg = "true" *) reg [1:0] request_sync_reg = 2'b00;
    reg [DATA_WIDTH-1:0] data_reg = {DATA_WIDTH{1'b0}};
    reg event_reg = 1'b0;
    reg overflow_reg = 1'b0;
    wire ready;
    assign ready = request_reg == acknowledge_sync_reg[1];
    assign ready_o = ready;
    assign overflow_o = overflow_reg;
    assign data_o = data_reg;
    assign event_o = event_reg;
    // CDC: held_reg remains stable from request until returned acknowledgment.
    always @(posedge clk_source) begin
        acknowledge_sync_reg <= {acknowledge_sync_reg[0], acknowledge_reg};
        overflow_reg <= send_i && !ready;
        if (send_i && ready) begin
            held_reg <= data_i;
            request_reg <= !request_reg;
        end
        if (rst_source) begin
            held_reg <= {DATA_WIDTH{1'b0}};
            request_reg <= 1'b0;
            acknowledge_sync_reg <= 2'b00;
            overflow_reg <= 1'b0;
        end
    end
    always @(posedge clk_dest) begin
        request_sync_reg <= {request_sync_reg[0], request_reg};
        event_reg <= 1'b0;
        if (request_sync_reg[1] != acknowledge_reg) begin
            data_reg <= held_reg;
            event_reg <= 1'b1;
            acknowledge_reg <= request_sync_reg[1];
        end
        if (rst_dest) begin
            request_sync_reg <= 2'b00;
            acknowledge_reg <= 1'b0;
            data_reg <= {DATA_WIDTH{1'b0}};
            event_reg <= 1'b0;
        end
    end
endmodule
`resetall
