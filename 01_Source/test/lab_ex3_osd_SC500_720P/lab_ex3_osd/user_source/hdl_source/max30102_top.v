// -----------------------------------------------------------------------------
// File   : max30102_top.v
// Author : Codex
// Date   : 2026-09-28
// -----------------------------------------------------------------------------
// Description:
//   Autonomous MAX30102 subsystem with one shared I2C master. Initialization
//   and ID check run once; the sampler starts only after both succeed.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-09-28  Codex  v1.0  Integrate the verified acquisition and PPG modules
// -----------------------------------------------------------------------------

`resetall
`timescale 1ns / 1ps
`default_nettype none

module max30102_top #(
    parameter integer CLK_HZ = 24000000,
    parameter integer I2C_HZ = 100000,
    parameter integer POWER_WAIT_CYCLES = CLK_HZ / 100,
    parameter integer RESET_POLL_CYCLES = CLK_HZ / 1000,
    parameter integer SAMPLER_POLL_INTERVAL_MS = 2
)(
    input  wire        clk,
    input  wire        rst_n,
    output wire        max30102_scl,
    inout  wire        max30102_sda,
    output wire [7:0]  part_id,
    output wire        device_ok,
    output wire [17:0] red_raw,
    output wire [17:0] ir_raw,
    output wire        sample_valid,
    output wire        finger_present,
    output wire        signal_good,
    output wire [8:0]  heart_rate_bpm,
    output wire        heart_rate_valid,
    output wire [7:0]  spo2,
    output wire        spo2_valid,
    output wire [31:0] ratio_r,
    output wire        init_done,
    output wire        system_ready,
    output wire        error,
    output wire        init_error_dbg,
    output wire        id_error_dbg,
    output wire        sampler_error_dbg,
    output wire        fifo_overflow_dbg
);
    localparam [2:0] SYS_POWER_WAIT = 3'd0;
    localparam [2:0] SYS_INIT       = 3'd1;
    localparam [2:0] SYS_ID_CHECK   = 3'd2;
    localparam [2:0] SYS_RUN        = 3'd3;
    localparam [2:0] SYS_ERROR      = 3'd4;

    reg [2:0] state_reg;
    reg init_start_reg;
    reg id_start_reg;
    wire run_rst_n;
    wire init_busy;
    wire id_done;
    wire i2c_busy;
    wire i2c_done;
    wire i2c_ack_error;
    wire [7:0] i2c_rd_data;
    wire i2c_rd_valid;
    wire i2c_rd_last;
    wire init_i2c_start;
    wire init_i2c_rw;
    wire [6:0] init_i2c_dev_addr;
    wire [7:0] init_i2c_reg_addr;
    wire [7:0] init_i2c_wr_data;
    wire [7:0] init_i2c_read_len;
    wire id_i2c_start;
    wire id_i2c_rw;
    wire [6:0] id_i2c_dev_addr;
    wire [7:0] id_i2c_reg_addr;
    wire [7:0] id_i2c_wr_data;
    wire [7:0] id_i2c_read_len;
    wire sampler_i2c_start;
    wire sampler_i2c_rw;
    wire [6:0] sampler_i2c_dev_addr;
    wire [7:0] sampler_i2c_reg_addr;
    wire [7:0] sampler_i2c_wr_data;
    wire [7:0] sampler_i2c_read_len;
    wire master_start;
    wire master_rw;
    wire [6:0] master_dev_addr;
    wire [7:0] master_reg_addr;
    wire [7:0] master_wr_data;
    wire [7:0] master_read_len;
    wire signed [18:0] red_filtered;
    wire signed [18:0] ir_filtered;
    wire ppg_valid;

    assign run_rst_n = rst_n && (state_reg == SYS_RUN);
    assign system_ready = (state_reg == SYS_RUN) && init_done && device_ok;
    assign error = (state_reg == SYS_ERROR) || init_error_dbg ||
                   id_error_dbg || sampler_error_dbg;

    // State selection is the sole driver of every master command input.
    assign master_start = (state_reg == SYS_INIT) ? init_i2c_start :
                          (state_reg == SYS_ID_CHECK) ? id_i2c_start :
                          (state_reg == SYS_RUN) ? sampler_i2c_start : 1'b0;
    assign master_rw = (state_reg == SYS_INIT) ? init_i2c_rw :
                       (state_reg == SYS_ID_CHECK) ? id_i2c_rw :
                       sampler_i2c_rw;
    assign master_dev_addr = (state_reg == SYS_INIT) ? init_i2c_dev_addr :
                             (state_reg == SYS_ID_CHECK) ? id_i2c_dev_addr :
                             sampler_i2c_dev_addr;
    assign master_reg_addr = (state_reg == SYS_INIT) ? init_i2c_reg_addr :
                             (state_reg == SYS_ID_CHECK) ? id_i2c_reg_addr :
                             sampler_i2c_reg_addr;
    assign master_wr_data = (state_reg == SYS_INIT) ? init_i2c_wr_data :
                            (state_reg == SYS_ID_CHECK) ? id_i2c_wr_data :
                            sampler_i2c_wr_data;
    assign master_read_len = (state_reg == SYS_INIT) ? init_i2c_read_len :
                             (state_reg == SYS_ID_CHECK) ? id_i2c_read_len :
                             sampler_i2c_read_len;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg <= SYS_POWER_WAIT;
            init_start_reg <= 1'b0;
            id_start_reg <= 1'b0;
        end else begin
            init_start_reg <= 1'b0;
            id_start_reg <= 1'b0;
            case (state_reg)
                SYS_POWER_WAIT: begin
                    init_start_reg <= 1'b1;
                    state_reg <= SYS_INIT;
                end
                SYS_INIT: begin
                    if (init_error_dbg) begin
                        state_reg <= SYS_ERROR;
                    end else if (init_done && !init_busy && !i2c_busy) begin
                        id_start_reg <= 1'b1;
                        state_reg <= SYS_ID_CHECK;
                    end
                end
                SYS_ID_CHECK: begin
                    if (id_done) begin
                        if (id_error_dbg || !device_ok || part_id != 8'h15)
                            state_reg <= SYS_ERROR;
                        else
                            state_reg <= SYS_RUN;
                    end
                end
                SYS_RUN: state_reg <= SYS_RUN;
                SYS_ERROR: state_reg <= SYS_ERROR;
                default: state_reg <= SYS_ERROR;
            endcase
        end
    end

    i2c_master #(
        .CLK_HZ (CLK_HZ),
        .I2C_HZ (I2C_HZ)
    ) master_inst (
        .i_clk       (clk),
        .i_rst_n     (rst_n),
        .i_start     (master_start),
        .i_rw        (master_rw),
        .i_dev_addr  (master_dev_addr),
        .i_reg_addr  (master_reg_addr),
        .i_wr_data   (master_wr_data),
        .i_read_len  (master_read_len),
        .o_rd_data   (i2c_rd_data),
        .o_rd_valid  (i2c_rd_valid),
        .o_rd_last   (i2c_rd_last),
        .o_busy      (i2c_busy),
        .o_done      (i2c_done),
        .o_ack_error (i2c_ack_error),
        .io_sda      (max30102_sda),
        .o_scl       (max30102_scl)
    );

    max30102_init #(
        .CLK_HZ            (CLK_HZ),
        .POWER_WAIT_CYCLES (POWER_WAIT_CYCLES),
        .RESET_POLL_CYCLES (RESET_POLL_CYCLES)
    ) init_inst (
        .i_clk           (clk),
        .i_rst_n         (rst_n),
        .i_start         (init_start_reg),
        .o_init_busy     (init_busy),
        .o_init_done     (init_done),
        .o_init_error    (init_error_dbg),
        .o_i2c_start     (init_i2c_start),
        .o_i2c_rw        (init_i2c_rw),
        .o_i2c_dev_addr  (init_i2c_dev_addr),
        .o_i2c_reg_addr  (init_i2c_reg_addr),
        .o_i2c_wr_data   (init_i2c_wr_data),
        .o_i2c_read_len  (init_i2c_read_len),
        .i_i2c_busy      (i2c_busy),
        .i_i2c_done      (i2c_done),
        .i_i2c_ack_error (i2c_ack_error),
        .i_i2c_rd_data   (i2c_rd_data),
        .i_i2c_rd_valid  (i2c_rd_valid),
        .i_i2c_rd_last   (i2c_rd_last)
    );

    max30102_id_check id_inst (
        .i_clk           (clk),
        .i_rst_n         (rst_n),
        .i_start         (id_start_reg),
        .part_id         (part_id),
        .check_done      (id_done),
        .device_ok       (device_ok),
        .check_error     (id_error_dbg),
        .o_i2c_start     (id_i2c_start),
        .o_i2c_rw        (id_i2c_rw),
        .o_i2c_dev_addr  (id_i2c_dev_addr),
        .o_i2c_reg_addr  (id_i2c_reg_addr),
        .o_i2c_wr_data   (id_i2c_wr_data),
        .o_i2c_read_len  (id_i2c_read_len),
        .i_i2c_busy      (i2c_busy),
        .i_i2c_done      (i2c_done),
        .i_i2c_ack_error (i2c_ack_error),
        .i_i2c_rd_data   (i2c_rd_data),
        .i_i2c_rd_valid  (i2c_rd_valid),
        .i_i2c_rd_last   (i2c_rd_last)
    );

    // Intermediate diagnostics not exported by this subsystem interface.
    /* verilator lint_off PINCONNECTEMPTY */
    max30102_sampler #(
        .CLK_HZ           (CLK_HZ),
        .POLL_INTERVAL_MS (SAMPLER_POLL_INTERVAL_MS)
    ) sampler_inst (
        .i_clk           (clk),
        .i_rst_n         (run_rst_n),
        .red_raw         (red_raw),
        .ir_raw          (ir_raw),
        .sample_valid    (sample_valid),
        .sample_count    (),
        .error           (sampler_error_dbg),
        .fifo_overflow   (fifo_overflow_dbg),
        .fifo_wr_ptr     (),
        .fifo_rd_ptr     (),
        .ovf_counter     (),
        .available_samples (),
        .data_available  (),
        .status_valid    (),
        .o_i2c_start     (sampler_i2c_start),
        .o_i2c_rw        (sampler_i2c_rw),
        .o_i2c_dev_addr  (sampler_i2c_dev_addr),
        .o_i2c_reg_addr  (sampler_i2c_reg_addr),
        .o_i2c_wr_data   (sampler_i2c_wr_data),
        .o_i2c_read_len  (sampler_i2c_read_len),
        .i_i2c_busy      (i2c_busy),
        .i_i2c_done      (i2c_done),
        .i_i2c_ack_error (i2c_ack_error),
        .i_i2c_rd_data   (i2c_rd_data),
        .i_i2c_rd_valid  (i2c_rd_valid),
        .i_i2c_rd_last   (i2c_rd_last)
    );

    max30102_ppg_preprocess preprocess_inst (
        .clk             (clk),
        .rst_n           (run_rst_n),
        .red_raw         (red_raw),
        .ir_raw          (ir_raw),
        .sample_valid    (sample_valid),
        .red_dc          (),
        .ir_dc           (),
        .red_ac          (),
        .ir_ac           (),
        .red_filtered    (red_filtered),
        .ir_filtered     (ir_filtered),
        .ppg_valid       (ppg_valid),
        .finger_present  (finger_present),
        .amplitude_good  (),
        .ir_p2p          (),
        .saturation_detect (),
        .signal_good     (signal_good)
    );

    heart_rate_calc heart_rate_inst (
        .clk              (clk),
        .rst_n            (run_rst_n),
        .ir_filtered      (ir_filtered),
        .ppg_valid        (ppg_valid),
        .finger_present   (finger_present),
        .signal_good      (signal_good),
        .heart_rate_bpm   (heart_rate_bpm),
        .heart_rate_valid (heart_rate_valid),
        .peak_detected    (),
        .peak_interval    (),
        .candidate_peak   (),
        .refractory_active ()
    );

    spo2_calc spo2_inst (
        .clk           (clk),
        .rst_n         (run_rst_n),
        .red_raw       (red_raw),
        .ir_raw        (ir_raw),
        .red_filtered  (red_filtered),
        .ir_filtered   (ir_filtered),
        .ppg_valid     (ppg_valid),
        .finger_present (finger_present),
        .signal_good   (signal_good),
        .spo2          (spo2),
        .spo2_valid    (spo2_valid),
        .ratio_r       (ratio_r),
        .red_dc_window (),
        .ir_dc_window  (),
        .red_ac_window (),
        .ir_ac_window  ()
    );
    /* verilator lint_on PINCONNECTEMPTY */
endmodule

`resetall
