`resetall
`timescale 1ns/1ps
`default_nettype none
// Debounced E11 enable; ordinary travel has no obstacle detour FSM.
module car_auto_motion #(
    parameter integer CLK_HZ = 50000000,
    parameter integer DEBOUNCE_MS = 20
) (
    input wire clk, rst_n, switch_n_i, hold_i, cmd_ready_i,
    output reg [2:0] cmd_code_o,
    output reg cmd_valid_o,
    output wire enabled_o
);
    localparam integer DEBOUNCE_CYCLES = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam integer COUNT_W = DEBOUNCE_CYCLES <= 2 ? 1 : $clog2(DEBOUNCE_CYCLES);
    (* async_reg = "true" *) reg switch_sync1, switch_sync2;
    reg stable_n;
    reg [COUNT_W-1:0] count;
    wire [2:0] desired = enabled_o && !hold_i ? 3'd1 : 3'd0;
    assign enabled_o = !stable_n && !switch_sync2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            switch_sync1 <= 1'b1; switch_sync2 <= 1'b1; stable_n <= 1'b1; count <= 0;
            cmd_code_o <= 3'd0; cmd_valid_o <= 1'b1;
        end else begin
            switch_sync1 <= switch_n_i; switch_sync2 <= switch_sync1;
            if (switch_sync2 == stable_n) count <= 0;
            else if (count == DEBOUNCE_CYCLES - 1) begin stable_n <= switch_sync2; count <= 0; end
            else count <= count + 1'b1;
            if (cmd_code_o != desired) begin cmd_code_o <= desired; cmd_valid_o <= 1'b1; end
            else if (cmd_valid_o && cmd_ready_i) cmd_valid_o <= 1'b0;
        end
    end
endmodule
`resetall
