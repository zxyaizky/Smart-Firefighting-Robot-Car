// -----------------------------------------------------------------------------
// File   : ddr_video_cpu_arbiter.v
// Author : Codex
// Date   : 2026-10-17
// -----------------------------------------------------------------------------
// Description:
//   DDR-clock arbitration after the existing video request FIFO. Independent
//   native AW/W acceptance, bounded video priority, and exclusive CPU readback.
//   Native addresses count 16-bit words; mask bits set to one inhibit a byte.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-17  Codex  v1.0  Add ownership, range protection and fault quarantine.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

module ddr_video_cpu_arbiter #
(
    // Maximum completed video commands after accepting a CPU request.
    parameter integer MAX_VIDEO_GRANTS = 32,
    // Bound native video read requests not yet returned.
    parameter integer MAX_VIDEO_READS = 32,
    // CPU operation total deadline and video/drain stall deadline.
    parameter integer TIMEOUT_CYCLES = 8192,
    parameter integer WORD_RESPONSE = 0,
    // Paired word service holds this complete request through response acceptance.
    parameter integer HELD_WORD_REQUEST = 0
)
(
    input  wire         clk,
    input  wire         rst,
    input  wire         ddr_ready_i,
    input  wire         video_valid_i,
    input  wire         video_write_i,
    input  wire [24:0]  video_addr_i,
    input  wire [127:0] video_wdata_i,
    output wire         video_ready_o,
    output wire         video_rvalid_o,
    output wire [127:0] video_rdata_o,
    input  wire         req_valid_i,
    output wire         req_ready_o,
    input  wire         req_write_i,
    input  wire [24:0]  req_addr_i,
    input  wire [(HELD_WORD_REQUEST ? 32 : 128)-1:0] req_wdata_i,
    input  wire [(HELD_WORD_REQUEST ? 4 : 16)-1:0] req_mask_i,
    input  wire [1:0]   req_lane_i,
    output wire         rsp_valid_o,
    input  wire         rsp_ready_i,
    output wire [(WORD_RESPONSE ? 32 : 128)-1:0] rsp_rdata_o,
    output wire         rsp_error_o,
    input  wire [1:0]   rsp_lane_i,
    output wire         mc_en_o,
    output wire [24:0]  mc_addr_o,
    output wire [2:0]   mc_cmd_o,
    output wire [127:0] mc_wdata_o,
    output wire [15:0]  mc_mask_o,
    output wire         mc_wren_o,
    output wire         mc_wend_o,
    input  wire         mc_awready_i,
    input  wire         mc_arready_i,
    input  wire         mc_wready_i,
    input  wire         mc_rvalid_i,
    input  wire         mc_rlast_i,
    input  wire [127:0] mc_rdata_i,
    output wire         error_o,
    output wire         busy_o,
    output wire [1:0]   owner_o,
    output wire         read_done_o,
    output wire         write_done_o
);

    // Compact binary control: state is local to clk, never crosses domains.
    localparam [1:0] STATE_VIDEO = 2'd0, STATE_DRAIN = 2'd1,
                     STATE_CPU = 2'd2, STATE_FAULT = 2'd3;
    localparam [1:0] CPU_WRITE = 2'd0, CPU_READ_SEND = 2'd1,
                     CPU_READ_WAIT = 2'd2;
    localparam integer GRANT_WIDTH = $clog2(MAX_VIDEO_GRANTS + 1);
    localparam integer READ_WIDTH = $clog2(MAX_VIDEO_READS + 1);
    localparam integer TIME_WIDTH = (TIMEOUT_CYCLES > 1) ?
                                   $clog2(TIMEOUT_CYCLES + 1) : 1;
    localparam [GRANT_WIDTH-1:0] LAST_VIDEO_GRANT = MAX_VIDEO_GRANTS - 1;
    localparam [READ_WIDTH-1:0] READ_LIMIT = MAX_VIDEO_READS;
    localparam [TIME_WIDTH-1:0] LAST_TIMEOUT = TIMEOUT_CYCLES - 1;
    localparam [24:0] CPU_NATIVE_BASE = 25'h1000000;

    reg [1:0] state_reg = STATE_VIDEO, state_next;
    reg [1:0] cpu_phase_reg = CPU_READ_SEND, cpu_phase_next;
    reg ready_seen_reg = 1'b0, ready_seen_next;
    reg cpu_pending_reg = 1'b0, cpu_pending_next;
    wire cpu_write_reg;
    wire [24:0] cpu_addr_reg;
    wire [127:0] cpu_wdata_reg;
    wire [15:0] cpu_mask_reg;
    wire request_latch;
    generate
        if (HELD_WORD_REQUEST) begin : held_word_request
            // The service cannot replace its payload before our response is consumed.
            assign cpu_write_reg = req_write_i;
            assign cpu_addr_reg = req_addr_i;
            assign cpu_wdata_reg = {4{req_wdata_i}};
            genvar lane;
            for (lane=0; lane<4; lane=lane+1) begin : byte_mask
                assign cpu_mask_reg[lane*4 +: 4] = req_lane_i == lane ? req_mask_i : 4'hf;
            end
        end else begin : latched_line_request
            reg write_reg=1'b0;
            reg [24:0] addr_reg=25'd0;
            reg [127:0] wdata_reg=128'd0;
            reg [15:0] mask_reg=16'd0;
            assign cpu_write_reg=write_reg;
            assign cpu_addr_reg=addr_reg;
            assign cpu_wdata_reg=wdata_reg;
            assign cpu_mask_reg=mask_reg;
            always @(posedge clk) begin
                if (request_latch) begin
                    write_reg<=req_write_i;
                    addr_reg<=req_addr_i;
                    wdata_reg<=req_wdata_i;
                    mask_reg<=req_mask_i;
                end
                if (rst) begin
                    write_reg<=1'b0;
                    addr_reg<=25'd0;
                    wdata_reg<=128'd0;
                    mask_reg<=16'd0;
                end
            end
        end
    endgenerate
    reg write_address_done_reg = 1'b0, write_address_done_next;
    reg write_data_done_reg = 1'b0, write_data_done_next;
    reg invalid_video_read_reg = 1'b0, invalid_video_read_next;
    reg [GRANT_WIDTH-1:0] video_grants_reg = {GRANT_WIDTH{1'b0}}, video_grants_next;
    reg [READ_WIDTH-1:0] video_reads_reg = {READ_WIDTH{1'b0}}, video_reads_next;
    reg [TIME_WIDTH-1:0] timeout_count_reg = {TIME_WIDTH{1'b0}}, timeout_count_next;
    reg rsp_valid_reg = 1'b0, rsp_valid_next;
    reg [127:0] rsp_rdata_reg = 128'd0;
    reg rsp_data_zero_reg = 1'b1, rsp_data_zero_next;
    reg rsp_data_capture;
    reg rsp_error_reg = 1'b0, rsp_error_next;
    reg error_reg = 1'b0, error_next;
    reg read_done_reg = 1'b0, read_done_next;
    reg write_done_reg = 1'b0, write_done_next;

    // Output decode temporaries; no native VALID is conditional on native READY.
    reg video_ready_reg = 1'b0;
    reg video_rvalid_reg = 1'b0;
    reg [127:0] video_rdata_reg = 128'd0;
    reg mc_en_reg = 1'b0;
    reg [24:0] mc_addr_reg = 25'd0;
    reg [2:0] mc_cmd_reg = 3'd0;
    reg [127:0] mc_wdata_reg = 128'd0;
    reg [15:0] mc_mask_reg = 16'd0;
    reg mc_wren_reg = 1'b0;
    reg fault_reg = 1'b0;
    reg video_read_accept_reg = 1'b0;
    reg video_return_reg = 1'b0;
    reg video_progress_reg = 1'b0;

    wire video_address_valid;
    wire cpu_address_valid;
    wire request_accept;
    wire write_compare_match;
    wire [127:0] write_compare_mask;
    assign video_address_valid = video_addr_i < CPU_NATIVE_BASE && video_addr_i[2:0] == 3'd0;
    assign cpu_address_valid = req_addr_i >= CPU_NATIVE_BASE && req_addr_i[2:0] == 3'd0;
    assign req_ready_o = !rst && ddr_ready_i && state_reg != STATE_FAULT &&
                         !cpu_pending_reg && !rsp_valid_reg;
    assign request_accept = req_valid_i && req_ready_o;
    assign request_latch = request_accept && cpu_address_valid;
    assign video_ready_o = video_ready_reg;
    assign video_rvalid_o = video_rvalid_reg;
    assign video_rdata_o = video_rdata_reg;
    assign rsp_valid_o = rsp_valid_reg;
    function [31:0] line_word;
        input [127:0] line;
        input [1:0] lane;
        begin
            case (lane)
                2'd0: line_word = line[31:0];
                2'd1: line_word = line[63:32];
                2'd2: line_word = line[95:64];
                default: line_word = line[127:96];
            endcase
        end
    endfunction
    // Select beside the held line; only one word leaves this bank in main mode.
    generate
        if (WORD_RESPONSE) begin : word_response
            assign rsp_rdata_o = rsp_data_zero_reg ? 32'd0 : line_word(rsp_rdata_reg, rsp_lane_i);
        end else begin : line_response
            assign rsp_rdata_o = rsp_data_zero_reg ? 128'd0 : rsp_rdata_reg;
        end
    endgenerate
    assign rsp_error_o = rsp_error_reg;
    assign mc_en_o = mc_en_reg;
    assign mc_addr_o = mc_addr_reg;
    assign mc_cmd_o = mc_cmd_reg;
    assign mc_wdata_o = mc_wdata_reg;
    assign mc_mask_o = mc_mask_reg;
    assign mc_wren_o = mc_wren_reg;
    assign mc_wend_o = mc_wren_reg;
    assign error_o = error_reg;
    assign busy_o = cpu_pending_reg || rsp_valid_reg || state_reg != STATE_VIDEO;
    assign owner_o = state_reg;
    // These pulses indicate verified CPU completion, not video dequeues.
    assign read_done_o = read_done_reg;
    assign write_done_o = write_done_reg;
    generate
        genvar byte_index;
        for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1) begin : compare_bytes
            assign write_compare_mask[byte_index*8 +: 8] = {8{!cpu_mask_reg[byte_index]}};
        end
    endgenerate
    generate
        if (HELD_WORD_REQUEST) begin : word_compare
            wire [31:0] compare_mask = {{8{!req_mask_i[3]}}, {8{!req_mask_i[2]}},
                                       {8{!req_mask_i[1]}}, {8{!req_mask_i[0]}}};
            assign write_compare_match =
                ((line_word(mc_rdata_i, req_lane_i) ^ req_wdata_i) & compare_mask) == 32'd0;
        end else begin : line_compare
            assign write_compare_match =
                ((mc_rdata_i ^ cpu_wdata_reg) & write_compare_mask) == 128'd0;
        end
    endgenerate

    always @* begin
        state_next = state_reg;
        cpu_phase_next = cpu_phase_reg;
        ready_seen_next = ready_seen_reg || ddr_ready_i;
        cpu_pending_next = cpu_pending_reg;
        write_address_done_next = write_address_done_reg;
        write_data_done_next = write_data_done_reg;
        invalid_video_read_next = invalid_video_read_reg;
        video_grants_next = video_grants_reg;
        video_reads_next = video_reads_reg;
        timeout_count_next = timeout_count_reg;
        rsp_valid_next = rsp_valid_reg && !rsp_ready_i;
        rsp_data_zero_next = rsp_data_zero_reg;
        rsp_data_capture = 1'b0;
        rsp_error_next = rsp_error_reg;
        error_next = error_reg;
        read_done_next = 1'b0;
        write_done_next = 1'b0;
        video_ready_reg = 1'b0;
        video_rvalid_reg = 1'b0;
        video_rdata_reg = 128'd0;
        mc_en_reg = 1'b0;
        mc_addr_reg = 25'd0;
        mc_cmd_reg = 3'd0;
        mc_wdata_reg = 128'd0;
        mc_mask_reg = 16'd0;
        mc_wren_reg = 1'b0;
        fault_reg = 1'b0;
        video_read_accept_reg = 1'b0;
        video_return_reg = 1'b0;
        video_progress_reg = 1'b0;

        if (request_accept) begin
            video_grants_next = {GRANT_WIDTH{1'b0}};
            if (cpu_address_valid) begin
                cpu_pending_next = 1'b1;
            end else begin
                rsp_valid_next = 1'b1;
                rsp_error_next = 1'b1;
                rsp_data_zero_next = 1'b1;
                error_next = 1'b1;
            end
        end

        if (!rst && ddr_ready_i) begin
            case (state_reg)
                STATE_VIDEO: begin
                    if (video_valid_i) begin
                        if (!video_address_valid) begin
                            error_next = 1'b1;
                            if (video_write_i) begin
                                video_ready_reg = 1'b1;
                            end else begin
                                invalid_video_read_next = 1'b1;
                                timeout_count_next = {TIME_WIDTH{1'b0}};
                                state_next = STATE_DRAIN;
                            end
                        end else if (video_write_i) begin
                            mc_addr_reg = video_addr_i;
                            mc_wdata_reg = video_wdata_i;
                            mc_en_reg = !write_address_done_reg;
                            mc_wren_reg = !write_data_done_reg;
                            if (mc_en_reg && mc_awready_i) write_address_done_next = 1'b1;
                            if (mc_wren_reg && mc_wready_i) write_data_done_next = 1'b1;
                            video_ready_reg = write_address_done_next && write_data_done_next;
                        end else if (video_reads_reg < READ_LIMIT) begin
                            mc_addr_reg = video_addr_i;
                            mc_cmd_reg = 3'd1;
                            mc_en_reg = 1'b1;
                            video_ready_reg = mc_arready_i;
                            video_read_accept_reg = video_ready_reg;
                        end
                        if (video_ready_reg) begin
                            write_address_done_next = 1'b0;
                            write_data_done_next = 1'b0;
                            video_progress_reg = 1'b1;
                            if (cpu_pending_next) begin
                                if (video_grants_next >= LAST_VIDEO_GRANT) begin
                                    state_next = STATE_DRAIN;
                                    timeout_count_next = {TIME_WIDTH{1'b0}};
                                end else begin
                                    video_grants_next = video_grants_next +
                                                       {{(GRANT_WIDTH-1){1'b0}}, 1'b1};
                                end
                            end
                        end
                    end else if (cpu_pending_next) begin
                        state_next = STATE_DRAIN;
                        timeout_count_next = {TIME_WIDTH{1'b0}};
                    end
                end
                STATE_DRAIN: begin
                    if (video_reads_reg == {READ_WIDTH{1'b0}}) begin
                        if (invalid_video_read_reg) begin
                            // Earlier valid video reads have all returned: preserve order.
                            video_ready_reg = video_valid_i;
                            video_rvalid_reg = video_valid_i;
                            if (video_valid_i) invalid_video_read_next = 1'b0;
                        end
                        if (!invalid_video_read_reg || video_valid_i) begin
                            timeout_count_next = {TIME_WIDTH{1'b0}};
                            if (cpu_pending_reg) begin
                                state_next = STATE_CPU;
                                cpu_phase_next = cpu_write_reg ? CPU_WRITE : CPU_READ_SEND;
                                write_address_done_next = 1'b0;
                                write_data_done_next = 1'b0;
                            end else begin
                                state_next = STATE_VIDEO;
                            end
                        end
                    end
                end
                STATE_CPU: begin
                    mc_addr_reg = cpu_addr_reg;
                    mc_wdata_reg = cpu_wdata_reg;
                    mc_mask_reg = cpu_mask_reg;
                    case (cpu_phase_reg)
                        CPU_WRITE: begin
                            mc_en_reg = !write_address_done_reg;
                            mc_wren_reg = !write_data_done_reg;
                            if (mc_en_reg && mc_awready_i) write_address_done_next = 1'b1;
                            if (mc_wren_reg && mc_wready_i) write_data_done_next = 1'b1;
                            if (write_address_done_next && write_data_done_next) begin
                                cpu_phase_next = CPU_READ_SEND;
                                write_address_done_next = 1'b0;
                                write_data_done_next = 1'b0;
                            end
                        end
                        CPU_READ_SEND: begin
                            mc_cmd_reg = 3'd1;
                            mc_en_reg = 1'b1;
                            if (mc_arready_i) cpu_phase_next = CPU_READ_WAIT;
                        end
                        CPU_READ_WAIT: begin
                            if (mc_rvalid_i && mc_rlast_i) begin
                                if (!cpu_write_reg || write_compare_match) begin
                                    rsp_valid_next = 1'b1;
                                    rsp_error_next = 1'b0;
                                    rsp_data_capture = 1'b1;
                                    rsp_data_zero_next = 1'b0;
                                    cpu_pending_next = 1'b0;
                                    read_done_next = !cpu_write_reg;
                                    write_done_next = cpu_write_reg;
                                    state_next = STATE_VIDEO;
                                    timeout_count_next = {TIME_WIDTH{1'b0}};
                                    video_grants_next = {GRANT_WIDTH{1'b0}};
                                end else begin
                                    // AW/W acceptance is not a completion response. Retry
                                    // stale readback without extending the operation deadline.
                                    cpu_phase_next = CPU_READ_SEND;
                                end
                            end
                        end
                        default: fault_reg = 1'b1;
                    endcase
                end
                STATE_FAULT: begin
                    // Late native responses remain quarantined until a DDR-domain reset.
                end
                default: fault_reg = 1'b1;
            endcase

            if ((state_reg == STATE_VIDEO || state_reg == STATE_DRAIN) && mc_rvalid_i) begin
                if (video_reads_reg != {READ_WIDTH{1'b0}} && mc_rlast_i) begin
                    video_return_reg = 1'b1;
                    video_rvalid_reg = 1'b1;
                    video_rdata_reg = mc_rdata_i;
                end else begin
                    fault_reg = 1'b1;
                end
            end else if (state_reg == STATE_CPU && mc_rvalid_i) begin
                if (cpu_phase_reg != CPU_READ_WAIT || !mc_rlast_i) fault_reg = 1'b1;
            end

            case ({video_read_accept_reg, video_return_reg})
                2'b10: video_reads_next = video_reads_reg + {{(READ_WIDTH-1){1'b0}}, 1'b1};
                2'b01: video_reads_next = video_reads_reg - {{(READ_WIDTH-1){1'b0}}, 1'b1};
                default: video_reads_next = video_reads_reg;
            endcase

            // A CPU transaction has a total deadline including all readback retries.
            // Video's watchdog measures lack of native command/return progress.
            if (state_reg != STATE_FAULT && state_next == state_reg) begin
                if (state_reg == STATE_CPU || state_reg == STATE_DRAIN ||
                    video_reads_reg != {READ_WIDTH{1'b0}} ||
                    write_address_done_reg || write_data_done_reg ||
                    (video_valid_i && !video_ready_reg)) begin
                    if (state_reg == STATE_VIDEO &&
                        (video_progress_reg || video_return_reg)) begin
                        timeout_count_next = {TIME_WIDTH{1'b0}};
                    end else if (timeout_count_reg >= LAST_TIMEOUT) begin
                        fault_reg = 1'b1;
                    end else begin
                        timeout_count_next = timeout_count_reg +
                                             {{(TIME_WIDTH-1){1'b0}}, 1'b1};
                    end
                end else begin
                    timeout_count_next = {TIME_WIDTH{1'b0}};
                end
            end
        end

        // Initial DDR calibration is a normal wait. Loss after ready is a fault.
        if (!rst && ready_seen_reg && !ddr_ready_i) fault_reg = 1'b1;
        if (fault_reg) begin
            state_next = STATE_FAULT;
            error_next = 1'b1;
            video_ready_reg = 1'b0;
            video_rvalid_reg = 1'b0;
            // Keep a stalled native VALID through the deadline edge. The
            // registered FAULT state suppresses subsequent commands; reset
            // must flush anything accepted on this final edge as well.
            video_reads_next = {READ_WIDTH{1'b0}};
            write_address_done_next = 1'b0;
            write_data_done_next = 1'b0;
            if (cpu_pending_next) begin
                rsp_valid_next = 1'b1;
                rsp_data_zero_next = 1'b1;
                rsp_error_next = 1'b1;
                cpu_pending_next = 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        state_reg <= state_next;
        cpu_phase_reg <= cpu_phase_next;
        ready_seen_reg <= ready_seen_next;
        cpu_pending_reg <= cpu_pending_next;
        write_address_done_reg <= write_address_done_next;
        write_data_done_reg <= write_data_done_next;
        invalid_video_read_reg <= invalid_video_read_next;
        video_grants_reg <= video_grants_next;
        video_reads_reg <= video_reads_next;
        timeout_count_reg <= timeout_count_next;
        rsp_valid_reg <= rsp_valid_next;
        // Fault/reset clears the logical line using one tag, not 128 data flops.
        // Keep the last successful line for the word-service's four-lane cache.
        if (rsp_data_capture) rsp_rdata_reg <= mc_rdata_i;
        rsp_data_zero_reg <= rsp_data_zero_next;
        rsp_error_reg <= rsp_error_next;
        error_reg <= error_next;
        read_done_reg <= read_done_next;
        write_done_reg <= write_done_next;
        if (rst) begin
            state_reg <= STATE_VIDEO;
            cpu_phase_reg <= CPU_READ_SEND;
            ready_seen_reg <= 1'b0;
            cpu_pending_reg <= 1'b0;
            write_address_done_reg <= 1'b0;
            write_data_done_reg <= 1'b0;
            invalid_video_read_reg <= 1'b0;
            video_grants_reg <= {GRANT_WIDTH{1'b0}};
            video_reads_reg <= {READ_WIDTH{1'b0}};
            timeout_count_reg <= {TIME_WIDTH{1'b0}};
            rsp_valid_reg <= 1'b0;
            rsp_data_zero_reg <= 1'b1;
            rsp_error_reg <= 1'b0;
            error_reg <= 1'b0;
            read_done_reg <= 1'b0;
            write_done_reg <= 1'b0;
        end
    end
endmodule
`resetall
