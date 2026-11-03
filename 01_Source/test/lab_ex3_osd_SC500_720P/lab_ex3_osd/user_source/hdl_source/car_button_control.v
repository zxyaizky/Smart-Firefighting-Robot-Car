`timescale 1ns/1ps
// Two active-low inputs directly command forward/backward motion.
// Releasing both or pressing both sends coast stop.
module car_button_control #(
    parameter integer CLK_HZ = 50000000,
    parameter integer DEBOUNCE_MS = 20
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       forward_n,
    input  wire       backward_n,
    input  wire       cmd_ready,
    output reg  [2:0] cmd_code,
    output reg        cmd_valid
);
    function integer clog2;
        input integer value;
        begin
            value = value - 1;
            for (clog2 = 0; value > 0; clog2 = clog2 + 1)
                value = value >> 1;
        end
    endfunction

    localparam integer DEBOUNCE_CYCLES = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam integer CNT_W = (DEBOUNCE_CYCLES < 2) ? 1 : clog2(DEBOUNCE_CYCLES);
    localparam [CNT_W-1:0] LAST_COUNT = DEBOUNCE_CYCLES[CNT_W-1:0] - 1'b1;

    reg [1:0] sync_1, sync_2, stable_n;
    reg [CNT_W-1:0] debounce_count [0:1];
    reg [2:0] last_cmd;
    wire [1:0] button_n = {backward_n, forward_n};
    wire [2:0] desired_cmd = !stable_n[0] && stable_n[1] ? 3'd1 :
                             stable_n[0] && !stable_n[1] ? 3'd2 : 3'd0;
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_1 <= 2'b11;
            sync_2 <= 2'b11;
            stable_n <= 2'b11;
            debounce_count[0] <= {CNT_W{1'b0}};
            debounce_count[1] <= {CNT_W{1'b0}};
            last_cmd <= 3'd0;
            cmd_code <= 3'd0;
            cmd_valid <= 1'b0;
        end else begin
            sync_1 <= button_n;
            sync_2 <= sync_1;
            for (i = 0; i < 2; i = i + 1) begin
                if (sync_2[i] == stable_n[i]) begin
                    debounce_count[i] <= {CNT_W{1'b0}};
                end else if (debounce_count[i] == LAST_COUNT) begin
                    stable_n[i] <= sync_2[i];
                    debounce_count[i] <= {CNT_W{1'b0}};
                end else begin
                    debounce_count[i] <= debounce_count[i] + 1'b1;
                end
            end

            if (cmd_valid && cmd_ready)
                cmd_valid <= 1'b0;
            if (desired_cmd != last_cmd) begin
                last_cmd <= desired_cmd;
                cmd_code <= desired_cmd;
                cmd_valid <= 1'b1;
            end
        end
    end
endmodule
