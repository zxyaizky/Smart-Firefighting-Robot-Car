`timescale 1ns/1ps
`default_nettype none

// Display-only horizontal impulse repair. Four pixel registers, no line RAM.
// Repair G only when a one/two-pixel green peak has consistent background
// samples two pixels away. Continuous green interiors and edges pass through.
// All timing signals have the same four-clock latency as the RGB payload.
// The first/last two active pixels of each line are deliberately unchanged.
module rgb_green_impulse_filter #(
    parameter [8:0] GREEN_MARGIN = 9'd32,
    parameter [8:0] SPIKE_THRESHOLD = 9'd48,
    parameter [7:0] BACKGROUND_TOLERANCE = 8'd32
)(
    input wire clk, rst_n,
    input wire [23:0] rgb_i,
    input wire de_i, vsync_i,
    output reg [23:0] rgb_o,
    output reg de_o, vsync_o
);
    reg [23:0] pixels [0:3];
    reg [3:0] de_history, vs_history;
    reg [2:0] green_history;
    reg [23:0] center_a, center_b;
    reg de_a, vs_a, de_b, vs_b;
    reg candidate_a;
    reg [8:0] threshold_a;
    reg [7:0] average_a;
    integer i;

    function green_peak;
        input [23:0] pixel;
        begin
            green_peak = {1'b0,pixel[15:8]} > {1'b0,pixel[23:16]} + GREEN_MARGIN &&
                         {1'b0,pixel[15:8]} > {1'b0,pixel[7:0]} + GREEN_MARGIN;
        end
    endfunction

    function close_channel;
        input [7:0] a,b;
        reg [8:0] difference;
        begin
            // A single modulo-512 subtraction covers both signs. Negative
            // differences occupy [512-tolerance,511]; handle zero explicitly.
            difference = {1'b0,a} - {1'b0,b};
            if (BACKGROUND_TOLERANCE == 0)
                close_channel = a == b;
            else
                close_channel = difference <= {1'b0,BACKGROUND_TOLERANCE} ||
                    difference >= (9'd0 - {1'b0,BACKGROUND_TOLERANCE});
        end
    endfunction

    wire [7:0] max_neighbor_g = pixels[3][15:8] > rgb_i[15:8] ?
                                pixels[3][15:8] : rgb_i[15:8];
    wire [8:0] neighbor_g_sum = {1'b0,pixels[3][15:8]} +
                               {1'b0,rgb_i[15:8]} + 9'd1;
    always @(posedge clk) begin
        pixels[0] <= rgb_i;
        for(i=1;i<4;i=i+1) pixels[i] <= pixels[i-1];
        de_history <= {de_history[2:0],de_i};
        vs_history <= {vs_history[2:0],vsync_i};
        // Classify each input once, then reuse the flag at three positions.
        green_history <= {green_history[1:0],green_peak(rgb_i)};

        center_a <= pixels[1];
        de_a <= de_history[1]; vs_a <= vs_history[1];
        threshold_a <= {1'b0,max_neighbor_g} + SPIKE_THRESHOLD;
        average_a <= neighbor_g_sum[8:1];
        candidate_a <= (&de_history) && de_i && !(|vs_history) && !vsync_i &&
            green_history[1] && !(green_history[0] && green_history[2]) &&
            close_channel(pixels[3][15:8],rgb_i[15:8]) &&
            close_channel(pixels[1][23:16],pixels[3][23:16]) &&
            close_channel(pixels[1][23:16],rgb_i[23:16]) &&
            close_channel(pixels[1][7:0],pixels[3][7:0]) &&
            close_channel(pixels[1][7:0],rgb_i[7:0]);

        // Commit the repaired G here, avoiding separate replacement/decision
        // registers. Retain the output stage and the original timing latency.
        center_b <= {center_a[23:16],
            (candidate_a && {1'b0,center_a[15:8]} > threshold_a) ? average_a : center_a[15:8],
            center_a[7:0]};
        de_b <= de_a; vs_b <= vs_a;

        rgb_o <= center_b;
        de_o <= de_b; vsync_o <= vs_b;
        if(!rst_n) begin
            for(i=0;i<4;i=i+1) pixels[i] <= 0;
            de_history <= 0; vs_history <= 0; green_history <= 0;
            center_a <= 0; center_b <= 0;
            de_a <= 0; vs_a <= 0; de_b <= 0; vs_b <= 0;
            candidate_a <= 0;
            threshold_a <= 0; average_a <= 0;
            rgb_o <= 0; de_o <= 0; vsync_o <= 0;
        end
    end
endmodule
`default_nettype wire
