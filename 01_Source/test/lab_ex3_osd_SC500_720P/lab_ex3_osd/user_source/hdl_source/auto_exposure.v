    // Frame-based automatic exposure controller for the SC500 RAW10 stream.
// Four RAW10 pixels arrive in every valid clock. One group out of every
// SAMPLE_INTERVAL groups is accumulated to reduce resource usage.
module auto_exposure #(
    parameter [7:0]  TARGET_LEVEL       = 8'd110,
    parameter [7:0]  TARGET_HYSTERESIS  = 8'd8,
    parameter [15:0] EXPOSURE_MIN       = 16'd32,
    parameter [15:0] EXPOSURE_MAX       = 16'd1990,
    parameter [15:0] EXPOSURE_INIT      = 16'd1990,
    parameter [15:0] GAIN_MIN           = 16'd16,
    parameter [15:0] GAIN_MAX           = 16'd143,
    // 112 maps to the sensor's original 16'h1f20 gain setting.
    parameter [15:0] GAIN_INIT          = 16'd112,
    parameter integer SAMPLE_LOG2       = 4
) (
    input  wire        I_pix_clk,
    input  wire        I_cfg_clk,
    input  wire        I_rst_n,
    input  wire        I_enable,
    input  wire        I_frame_start,
    input  wire        I_pixel_valid,
    input  wire [39:0] I_pixel_data,
    input  wire        I_cam_cfg_done,
    input  wire        I_ae_cfg_done,
    output reg         O_ae_req,
    output reg  [15:0] O_ae,
    output reg  [15:0] O_ag
);

        localparam [7:0] LEVEL_LOW  = TARGET_LEVEL - TARGET_HYSTERESIS;
        localparam [7:0] LEVEL_HIGH = TARGET_LEVEL + TARGET_HYSTERESIS;

        wire [7:0] pixel0 = I_pixel_data[ 9: 2];
        wire [7:0] pixel1 = I_pixel_data[19:12];
        wire [7:0] pixel2 = I_pixel_data[29:22];
        wire [7:0] pixel3 = I_pixel_data[39:32];
        wire [9:0] sample_value = pixel0 + pixel1 + pixel2 + pixel3;

        reg [SAMPLE_LOG2-1:0] sample_div;
        reg [23:0] frame_sum;
        reg [15:0] frame_samples;
        reg [23:0] frame_sum_hold;
        reg [15:0] frame_samples_hold;
        reg        frame_toggle;

    // Pixel-clock domain statistics. Held values remain unchanged for a full
    // frame, so the configuration domain can sample the bus after the toggle.
    always @(posedge I_pix_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            sample_div         <= {SAMPLE_LOG2{1'b0}};
            frame_sum          <= 24'd0;
            frame_samples      <= 16'd0;
            frame_sum_hold     <= 24'd0;
            frame_samples_hold <= 16'd0;
            frame_toggle       <= 1'b0;
        end else if (I_frame_start) begin
            frame_sum_hold     <= frame_sum;
            frame_samples_hold <= frame_samples;
            frame_toggle       <= ~frame_toggle;
            sample_div         <= {SAMPLE_LOG2{1'b0}};
            frame_sum          <= 24'd0;
            frame_samples      <= 16'd0;
        end else if (I_pixel_valid) begin
            sample_div <= sample_div + 1'b1;
            if (sample_div == {SAMPLE_LOG2{1'b0}}) begin
                frame_sum      <= frame_sum + sample_value;
                frame_samples  <= frame_samples + 1'b1;
            end
        end
    end
    
        reg [2:0]  toggle_sync;
        reg [23:0] sum_sync_0;
        reg [23:0] sum_sync_1;
        reg [15:0] samples_sync_0;
        reg [15:0] samples_sync_1;
        reg        update_pending;
        reg [15:0] desired_ae;
        reg [15:0] desired_ag;
        reg        enable_d;
        reg        restore_pending;

        wire new_frame_stats = toggle_sync[2] ^ toggle_sync[1];
        wire [25:0] low_limit  = samples_sync_1 * (LEVEL_LOW  * 4);
        wire [25:0] high_limit = samples_sync_1 * (LEVEL_HIGH * 4);
        wire        image_dark   = {2'b00, sum_sync_1} < low_limit;
        wire        image_bright = {2'b00, sum_sync_1} > high_limit;

    function [15:0] exposure_up;
        input [15:0] value;
        begin
            if (value >= EXPOSURE_MAX - 16'd32)
                exposure_up = EXPOSURE_MAX;
            else
                exposure_up = value + 16'd32;
        end
    endfunction

    function [15:0] exposure_down;
        input [15:0] value;
        begin
            if (value <= EXPOSURE_MIN + 16'd32)
                exposure_down = EXPOSURE_MIN;
            else
                exposure_down = value - 16'd32;
        end
    endfunction

    // Configuration-clock domain control loop and SC500 I2C request handshake.
    always @(posedge I_cfg_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            toggle_sync     <= 3'b000;
            sum_sync_0      <= 24'd0;
            sum_sync_1      <= 24'd0;
            samples_sync_0  <= 16'd0;
            samples_sync_1  <= 16'd0;
            desired_ae      <= EXPOSURE_INIT;
            desired_ag      <= GAIN_INIT;
            O_ae            <= EXPOSURE_INIT;
            O_ag            <= GAIN_INIT;
            O_ae_req        <= 1'b0;
            update_pending  <= 1'b1;
            enable_d        <= 1'b0;
            restore_pending <= 1'b0;
        end else begin
            toggle_sync     <= {toggle_sync[1:0], frame_toggle};
            sum_sync_0      <= frame_sum_hold;
            sum_sync_1      <= sum_sync_0;
            samples_sync_0  <= frame_samples_hold;
            samples_sync_1  <= samples_sync_0;
            O_ae_req        <= 1'b0;
            enable_d        <= I_enable;

            // Stop the automatic loop while disabled.
            if (!I_enable)
                update_pending <= 1'b0;

            // On the ON-to-OFF transition, restore the fixed sensor defaults
            // used before automatic exposure was enabled.  The request remains
            // pending until the camera configuration interface is idle.
            if (enable_d && !I_enable) begin
                desired_ae      <= EXPOSURE_INIT;
                desired_ag      <= GAIN_INIT;
                restore_pending <= 1'b1;
            end

            // Ignore the empty statistic generated by the first frame-start.
            if (I_enable && new_frame_stats && (samples_sync_1 >= 16'd256)) begin
                if (image_dark) begin
                    if (desired_ae < EXPOSURE_MAX) begin
                        desired_ae <= exposure_up(desired_ae);
                        update_pending <= 1'b1;
                    end else if (desired_ag < GAIN_MAX) begin
                        desired_ag <= desired_ag + 1'b1;
                        update_pending <= 1'b1;
                    end
                end else if (image_bright) begin
                    if (desired_ag > GAIN_MIN) begin
                        desired_ag <= desired_ag - 1'b1;
                        update_pending <= 1'b1;
                    end else if (desired_ae > EXPOSURE_MIN) begin
                        desired_ae <= exposure_down(desired_ae);
                        update_pending <= 1'b1;
                    end
                end
            end

            if (restore_pending && I_cam_cfg_done && I_ae_cfg_done) begin
                O_ae            <= EXPOSURE_INIT;
                O_ag            <= GAIN_INIT;
                O_ae_req        <= 1'b1;
                restore_pending <= 1'b0;
            end else if (I_enable && update_pending && I_cam_cfg_done && I_ae_cfg_done) begin
                O_ae           <= desired_ae;
                O_ag           <= desired_ag;
                O_ae_req       <= 1'b1;
                update_pending <= 1'b0;
            end
        end
    end

endmodule
