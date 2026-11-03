// A9 selects one of six arm servos; B9 moves it by 5 degrees per press.
// Each joint reverses direction at its configured absolute angle limit.
`resetall
`timescale 1ns / 1ps
`default_nettype none

module servo_pwm6_buttons #(
    parameter integer CLK_HZ = 50000000,
    parameter integer DEBOUNCE_MS = 20
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable_i,
    input  wire [1:0]  button_n,
    output wire [71:0] pulse_us_o,
    output reg  [2:0]  selected_o
);
    localparam integer DEBOUNCE_CYCLES = (CLK_HZ / 1000) * DEBOUNCE_MS;
    localparam integer COUNT_W = (DEBOUNCE_CYCLES <= 2) ? 1 : $clog2(DEBOUNCE_CYCLES);
    localparam [COUNT_W-1:0] LAST = DEBOUNCE_CYCLES[COUNT_W-1:0] - 1'b1;

    // Angles are stored in units of five degrees. Servo 0 is nominally 270
    // degrees over 500..2500 us; servos 1..5 are nominally 180 degrees.
    // Limits: 0=0..270, 1/2/3/5=0..180, 4=fixed 90 degrees.
    function [5:0] min_step;
        input [2:0] channel;
        begin
            min_step = (channel == 3'd4) ? 6'd18 : 6'd0;
        end
    endfunction

    function [5:0] max_step;
        input [2:0] channel;
        begin
            case (channel)
                3'd0: max_step = 6'd54;
                3'd4: max_step = 6'd18;
                3'd5: max_step = 6'd36; // 180-degree gripper limit.
                default: max_step = 6'd36;
            endcase
        end
    endfunction

    // Constant lookup avoids a runtime divider and rounds to the nearest us.
    function [11:0] pulse_for_step;
        input integer channel;
        input [5:0] angle_step;
        begin
            if (channel == 0) begin
                case (angle_step)
                6'd0: pulse_for_step = 12'd500;
                6'd1: pulse_for_step = 12'd537;
                6'd2: pulse_for_step = 12'd574;
                6'd3: pulse_for_step = 12'd611;
                6'd4: pulse_for_step = 12'd648;
                6'd5: pulse_for_step = 12'd685;
                6'd6: pulse_for_step = 12'd722;
                6'd7: pulse_for_step = 12'd759;
                6'd8: pulse_for_step = 12'd796;
                6'd9: pulse_for_step = 12'd833;
                6'd10: pulse_for_step = 12'd870;
                6'd11: pulse_for_step = 12'd907;
                6'd12: pulse_for_step = 12'd944;
                6'd13: pulse_for_step = 12'd981;
                6'd14: pulse_for_step = 12'd1019;
                6'd15: pulse_for_step = 12'd1056;
                6'd16: pulse_for_step = 12'd1093;
                6'd17: pulse_for_step = 12'd1130;
                6'd18: pulse_for_step = 12'd1167;
                6'd19: pulse_for_step = 12'd1204;
                6'd20: pulse_for_step = 12'd1241;
                6'd21: pulse_for_step = 12'd1278;
                6'd22: pulse_for_step = 12'd1315;
                6'd23: pulse_for_step = 12'd1352;
                6'd24: pulse_for_step = 12'd1389;
                6'd25: pulse_for_step = 12'd1426;
                6'd26: pulse_for_step = 12'd1463;
                6'd27: pulse_for_step = 12'd1500;
                6'd28: pulse_for_step = 12'd1537;
                6'd29: pulse_for_step = 12'd1574;
                6'd30: pulse_for_step = 12'd1611;
                6'd31: pulse_for_step = 12'd1648;
                6'd32: pulse_for_step = 12'd1685;
                6'd33: pulse_for_step = 12'd1722;
                6'd34: pulse_for_step = 12'd1759;
                6'd35: pulse_for_step = 12'd1796;
                6'd36: pulse_for_step = 12'd1833;
                6'd37: pulse_for_step = 12'd1870;
                6'd38: pulse_for_step = 12'd1907;
                6'd39: pulse_for_step = 12'd1944;
                6'd40: pulse_for_step = 12'd1981;
                6'd41: pulse_for_step = 12'd2019;
                6'd42: pulse_for_step = 12'd2056;
                6'd43: pulse_for_step = 12'd2093;
                6'd44: pulse_for_step = 12'd2130;
                6'd45: pulse_for_step = 12'd2167;
                6'd46: pulse_for_step = 12'd2204;
                6'd47: pulse_for_step = 12'd2241;
                6'd48: pulse_for_step = 12'd2278;
                6'd49: pulse_for_step = 12'd2315;
                6'd50: pulse_for_step = 12'd2352;
                6'd51: pulse_for_step = 12'd2389;
                6'd52: pulse_for_step = 12'd2426;
                6'd53: pulse_for_step = 12'd2463;
                6'd54: pulse_for_step = 12'd2500;
                    default: pulse_for_step = 12'd1500;
                endcase
            end else begin
                case (angle_step)
                6'd0: pulse_for_step = 12'd500;
                6'd1: pulse_for_step = 12'd556;
                6'd2: pulse_for_step = 12'd611;
                6'd3: pulse_for_step = 12'd667;
                6'd4: pulse_for_step = 12'd722;
                6'd5: pulse_for_step = 12'd778;
                6'd6: pulse_for_step = 12'd833;
                6'd7: pulse_for_step = 12'd889;
                6'd8: pulse_for_step = 12'd944;
                6'd9: pulse_for_step = 12'd1000;
                6'd10: pulse_for_step = 12'd1056;
                6'd11: pulse_for_step = 12'd1111;
                6'd12: pulse_for_step = 12'd1167;
                6'd13: pulse_for_step = 12'd1222;
                6'd14: pulse_for_step = 12'd1278;
                6'd15: pulse_for_step = 12'd1333;
                6'd16: pulse_for_step = 12'd1389;
                6'd17: pulse_for_step = 12'd1444;
                6'd18: pulse_for_step = 12'd1500;
                6'd19: pulse_for_step = 12'd1556;
                6'd20: pulse_for_step = 12'd1611;
                6'd21: pulse_for_step = 12'd1667;
                6'd22: pulse_for_step = 12'd1722;
                6'd23: pulse_for_step = 12'd1778;
                6'd24: pulse_for_step = 12'd1833;
                6'd25: pulse_for_step = 12'd1889;
                6'd26: pulse_for_step = 12'd1944;
                6'd27: pulse_for_step = 12'd2000;
                6'd28: pulse_for_step = 12'd2056;
                6'd29: pulse_for_step = 12'd2111;
                6'd30: pulse_for_step = 12'd2167;
                6'd31: pulse_for_step = 12'd2222;
                6'd32: pulse_for_step = 12'd2278;
                6'd33: pulse_for_step = 12'd2333;
                6'd34: pulse_for_step = 12'd2389;
                6'd35: pulse_for_step = 12'd2444;
                6'd36: pulse_for_step = 12'd2500;
                    default: pulse_for_step = 12'd1500;
                endcase
            end
        end
    endfunction

    (* async_reg = "true" *) reg [1:0] sync_1, sync_2;
    reg [1:0] stable_n;
    reg rearmed;
    reg [COUNT_W-1:0] count_select, count_value;
    reg [5:0] angle_step [0:5];
    reg direction_up [0:5];
    wire select_press = enable_i && rearmed && stable_n[0] && !sync_2[0] && count_select == LAST;
    wire value_press  = enable_i && rearmed && stable_n[1] && !sync_2[1] && count_value == LAST;
    integer i;

    genvar channel;
    generate for (channel = 0; channel < 6; channel = channel + 1) begin: g_value
        assign pulse_us_o[channel*12 +: 12] =
            pulse_for_step(channel, angle_step[channel]);
    end endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_1 <= 2'b11;
            sync_2 <= 2'b11;
            stable_n <= 2'b11;
            rearmed <= 1'b1;
            count_select <= {COUNT_W{1'b0}};
            count_value <= {COUNT_W{1'b0}};
            selected_o <= 3'd0;
            for (i = 0; i < 6; i = i + 1) begin
                angle_step[i] <= (i == 0) ? 6'd27 :
                                 (i == 1 || i == 4) ? 6'd18 :
                                 (i == 3) ? 6'd36 : 6'd0;
                direction_up[i] <= (i != 3);
            end
        end else begin
            if (!enable_i) rearmed <= 1'b0;
            else if (&stable_n && &sync_2) rearmed <= 1'b1;
            sync_1 <= button_n;
            sync_2 <= sync_1;

            if (sync_2[0] == stable_n[0])
                count_select <= {COUNT_W{1'b0}};
            else if (count_select == LAST) begin
                stable_n[0] <= sync_2[0];
                count_select <= {COUNT_W{1'b0}};
            end else
                count_select <= count_select + 1'b1;

            if (sync_2[1] == stable_n[1])
                count_value <= {COUNT_W{1'b0}};
            else if (count_value == LAST) begin
                stable_n[1] <= sync_2[1];
                count_value <= {COUNT_W{1'b0}};
            end else
                count_value <= count_value + 1'b1;

            if (select_press)
                selected_o <= (selected_o == 3'd5) ? 3'd0 : selected_o + 1'b1;
            if (value_press && min_step(selected_o) != max_step(selected_o)) begin
                if (angle_step[selected_o] >= max_step(selected_o)) begin
                    angle_step[selected_o] <= angle_step[selected_o] - 1'b1;
                    direction_up[selected_o] <= 1'b0;
                end else if (angle_step[selected_o] <= min_step(selected_o)) begin
                    angle_step[selected_o] <= angle_step[selected_o] + 1'b1;
                    direction_up[selected_o] <= 1'b1;
                end else if (direction_up[selected_o])
                    angle_step[selected_o] <= angle_step[selected_o] + 1'b1;
                else
                    angle_step[selected_o] <= angle_step[selected_o] - 1'b1;
            end
        end
    end
endmodule

`resetall
