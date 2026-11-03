// -----------------------------------------------------------------------------
// File: npu_perf_profiler.v
// Description: Cycle-level latency profiling for one NPU inference, measured
//              from real RTL events only.  No value in this module is estimated
//              or derived from a model: every timestamp is a counter latch of an
//              event driven by the production datapath.
//
// Timeline:
//
//   T0  = a frame is admitted and PING preload begins   (i_frame_valid rise)
//   T1  = all 57600 input bytes committed to PING       (o_preload_done)
//   T2  = sequencer issues its first compute start      (first layer_start)
//   T3  = L0 complete   } the sequencer's per-LAYER completion
//   T4  = L1 complete   } (o_layer_done = w_complete_layer), NOT the per-
//   ...                 } iteration BCU handshake, which fires hundreds of
//   T14 = L11 complete  } times per frame and is therefore unusable here
//   T15 = reducer winner valid                          (o_inference_done)
//
// Derived intervals, all in NPU clocks:
//
//   input_cycles       = T1  - T0
//   start_wait_cycles  = T2  - T1
//   L<i>_cycles        = T(i+3) - T(i+2)      for i = 0..11
//   compute_cycles     = T14 - T2
//   reducer_cycles     = T15 - T14
//   total_cycles       = T15 - T0
//
// Parameter-fetch attribution:
//
//   param_request_count  weight-DMA transactions requested this frame
//   param_wait_cycles    cycles the DMA was active but DDR returned no data
//   param_valid_cycles   cycles DDR read data was valid
//
// Unit conversion is left to the readout side. At the current 100 MHz NPU
// clock (PLLF6F1D0P0_0: FIN 50 MHz, generated C0=100 MHz):
//
//   ms = cycles / 100000
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module npu_perf_profiler (
    input  wire        clk,
    input  wire        rst_n,

    // ---- milestone inputs (all tied to production datapath signals) ----
    input  wire        i_input_start,     // frame admitted, PING fill begins
    input  wire        i_input_done,      // PING fill committed
    input  wire        i_layer_start,     // sequencer per-iteration compute start
    input  wire        i_layer_done,      // TRUE per-layer completion
    input  wire        i_npu_done,        // inference done, winner valid

    // ---- attribution inputs ----
    input  wire        i_dma_active,      // weight DMA FSM not idle
    input  wire        i_param_req,       // weight DMA transaction request
    input  wire        i_param_rd_valid,  // DDR read data valid
    input  wire        i_busy,            // NPU busy (input_busy)

    // ---- readout mux ----
    input  wire [5:0]  i_stat_sel,
    output reg  [31:0] o_stat_data,

    // ---- convenience outputs kept for the board-side debug ports ----
    output wire [31:0] o_input_cycles,
    output wire [31:0] o_wait_cycles,
    output wire [31:0] o_compute_cycles,
    output wire [31:0] o_reducer_cycles,
    output wire [31:0] o_total_cycles,
    output wire [4:0]  o_layer_count,
    output wire [31:0] o_param_request_count,
    output wire [31:0] o_param_wait_cycles,
    output wire [31:0] o_param_valid_cycles,
    output wire [31:0] o_dma_active_cycles,
    output wire [31:0] o_busy_cycles,
    output wire        o_inference_active
);

    // T0..T15, stored as offsets from T0 so the readout needs no subtraction.
    reg [31:0] r_t [0:15];
    reg [31:0] r_t0;
    reg        r_have_t0;

    reg [4:0]  r_layer_cnt;      // number of true layer completions so far
    reg        r_input_done_seen;
    reg        r_npu_start_seen;
    reg        r_done_seen;

    reg [31:0] r_param_req_cnt;
    reg [31:0] r_param_wait;
    reg [31:0] r_param_valid;
    reg [31:0] r_dma_active;
    reg [31:0] r_busy;
    reg        r_param_req_d;

    // Free-running 32-bit timestamp.  Only differences between latches taken
    // inside the same frame are ever reported, so wrap-around is harmless as
    // long as no single phase exceeds 2^32 clocks (~43 s at 100 MHz).
    reg [31:0] r_now_free;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_t0 <= 32'd0;
            r_have_t0 <= 1'b0;
            r_layer_cnt <= 5'd0;
            r_input_done_seen <= 1'b0;
            r_npu_start_seen <= 1'b0;
            r_done_seen <= 1'b0;
            r_param_req_cnt <= 32'd0;
            r_param_wait <= 32'd0;
            r_param_valid <= 32'd0;
            r_dma_active <= 32'd0;
            r_busy <= 32'd0;
            r_param_req_d <= 1'b0;
            for (i = 0; i < 16; i = i + 1) r_t[i] <= 32'd0;
        end else begin
            r_param_req_d <= i_param_req;

            // ---- T0: frame admitted ----
            if (i_input_start) begin
                r_t0 <= r_now_free;
                r_have_t0 <= 1'b1;
                r_layer_cnt <= 5'd0;
                r_input_done_seen <= 1'b0;
                r_npu_start_seen <= 1'b0;
                r_done_seen <= 1'b0;
                r_param_req_cnt <= 32'd0;
                r_param_wait <= 32'd0;
                r_param_valid <= 32'd0;
                r_dma_active <= 32'd0;
                r_busy <= 32'd0;
                for (i = 0; i < 16; i = i + 1) r_t[i] <= 32'd0;
            end else if (r_have_t0) begin
                // ---- T1: input committed ----
                if (i_input_done && !r_input_done_seen) begin
                    r_input_done_seen <= 1'b1;
                    r_t[1] <= r_now_free - r_t0;
                end

                // ---- T2: first compute start ----
                if (i_layer_start && r_input_done_seen && !r_npu_start_seen) begin
                    r_npu_start_seen <= 1'b1;
                    r_t[2] <= r_now_free - r_t0;
                end

                // ---- T3..T14: true per-layer completions ----
                if (i_layer_done && r_npu_start_seen && r_layer_cnt < 5'd12) begin
                    r_t[r_layer_cnt + 5'd3] <= r_now_free - r_t0;
                    r_layer_cnt <= r_layer_cnt + 5'd1;
                end

                // ---- T15: inference done, winner valid ----
                if (i_npu_done && !r_done_seen) begin
                    r_done_seen <= 1'b1;
                    r_t[15] <= r_now_free - r_t0;
                end

                // ---- attribution accumulation ----
                if (i_dma_active) begin
                    r_dma_active <= r_dma_active + 32'd1;
                    if (i_param_rd_valid) r_param_valid <= r_param_valid + 32'd1;
                    else                  r_param_wait  <= r_param_wait  + 32'd1;
                end
                if (i_param_req && !r_param_req_d)
                    r_param_req_cnt <= r_param_req_cnt + 32'd1;
                if (i_busy)
                    r_busy <= r_busy + 32'd1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_now_free <= 32'd0;
        else        r_now_free <= r_now_free + 32'd1;
    end

    // -------------------------------------------------------------------------
    // Derived intervals
    // -------------------------------------------------------------------------
    wire [31:0] w_input   = r_t[1]  - r_t[0];
    wire [31:0] w_wait    = r_t[2]  - r_t[1];
    wire [31:0] w_compute = r_t[14] - r_t[2];
    wire [31:0] w_reducer = r_t[15] - r_t[14];
    wire [31:0] w_total   = r_t[15] - r_t[0];

    assign o_input_cycles        = w_input;
    assign o_wait_cycles         = w_wait;
    assign o_compute_cycles      = w_compute;
    assign o_reducer_cycles      = w_reducer;
    assign o_total_cycles        = w_total;
    assign o_layer_count         = r_layer_cnt;
    assign o_param_request_count = r_param_req_cnt;
    assign o_param_wait_cycles   = r_param_wait;
    assign o_param_valid_cycles  = r_param_valid;
    assign o_dma_active_cycles   = r_dma_active;
    assign o_busy_cycles         = r_busy;
    assign o_inference_active    = (r_have_t0 && !r_done_seen);

    // -------------------------------------------------------------------------
    // Readout mux.
    //   0..15  T0..T15 timestamps (offsets from T0)
    //   16     input_cycles       17 start_wait_cycles
    //   18..29 L0..L11 cycles
    //   30     compute_cycles     31 reducer_cycles    32 total_cycles
    //   33     busy_cycles        34 dma_active_cycles
    //   35     param_request_count
    //   36     param_wait_cycles  37 param_valid_cycles
    //   38     layer_count        39 frame_complete
    // -------------------------------------------------------------------------
    reg [31:0] w_layer_pick;
    // Selector 18..29 maps to layer 0..11, whose span is T(i+3) - T(i+2).
    wire [4:0] w_layer_idx = i_stat_sel[3:0] - 4'd2;
    always @(*) begin
        w_layer_pick = r_t[w_layer_idx + 5'd3] - r_t[w_layer_idx + 5'd2];
    end

    always @(*) begin
        case (i_stat_sel)
            6'd0:  o_stat_data = r_t[0];
            6'd1:  o_stat_data = r_t[1];
            6'd2:  o_stat_data = r_t[2];
            6'd3:  o_stat_data = r_t[3];
            6'd4:  o_stat_data = r_t[4];
            6'd5:  o_stat_data = r_t[5];
            6'd6:  o_stat_data = r_t[6];
            6'd7:  o_stat_data = r_t[7];
            6'd8:  o_stat_data = r_t[8];
            6'd9:  o_stat_data = r_t[9];
            6'd10: o_stat_data = r_t[10];
            6'd11: o_stat_data = r_t[11];
            6'd12: o_stat_data = r_t[12];
            6'd13: o_stat_data = r_t[13];
            6'd14: o_stat_data = r_t[14];
            6'd15: o_stat_data = r_t[15];
            6'd16: o_stat_data = w_input;
            6'd17: o_stat_data = w_wait;
            6'd18, 6'd19, 6'd20, 6'd21, 6'd22, 6'd23,
            6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29:
                   o_stat_data = w_layer_pick;
            6'd30: o_stat_data = w_compute;
            6'd31: o_stat_data = w_reducer;
            6'd32: o_stat_data = w_total;
            6'd33: o_stat_data = r_busy;
            6'd34: o_stat_data = r_dma_active;
            6'd35: o_stat_data = r_param_req_cnt;
            6'd36: o_stat_data = r_param_wait;
            6'd37: o_stat_data = r_param_valid;
            6'd38: o_stat_data = {27'd0, r_layer_cnt};
            6'd39: o_stat_data = {31'd0, r_done_seen};
            default: o_stat_data = 32'd0;
        endcase
    end

endmodule

`default_nettype wire
