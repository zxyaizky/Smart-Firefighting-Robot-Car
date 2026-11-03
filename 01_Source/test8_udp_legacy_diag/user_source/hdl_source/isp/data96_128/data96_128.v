`timescale 1ns/1ps
`default_nettype none

module data_96bit_to_128bit (
    input  wire         I_clk,
    input  wire         I_rst_n,

    input  wire         I_96b_frame_start,
    input  wire         I_96b_valid,
    input  wire [95:0]  I_96b_data,

    output reg          O_128b_frame_start,
    output reg          O_128b_valid,
    output reg  [127:0] O_128b_data
);

    localparam [1:0] PHASE_0 = 2'd0;
    localparam [1:0] PHASE_1 = 2'd1;
    localparam [1:0] PHASE_2 = 2'd2;
    localparam [1:0] PHASE_3 = 2'd3;

    reg [95:0] previous_data_reg;
    reg [95:0] previous_data_next;
    reg [1:0]  phase_reg;
    reg [1:0]  phase_next;
    reg        frame_start_pending_reg;
    reg        frame_start_pending_next;
    reg        output_frame_start_next;
    reg        output_valid_next;
    reg [127:0] output_data_next;

    always @* begin
        previous_data_next       = previous_data_reg;
        phase_next               = phase_reg;
        frame_start_pending_next = frame_start_pending_reg;
        output_frame_start_next  = 1'b0;
        output_valid_next        = 1'b0;
        output_data_next         = 128'd0;

        // A frame marker realigns the byte stream. If it accompanies the
        // first valid beat, that beat becomes phase 0 and is retained.
        if (I_96b_frame_start) begin
            phase_next               = PHASE_0;
            frame_start_pending_next = 1'b1;

            if (I_96b_valid) begin
                previous_data_next = I_96b_data;
                phase_next         = PHASE_1;
            end
        end else if (I_96b_valid) begin
            previous_data_next = I_96b_data;

            case (phase_reg)
                PHASE_0: begin
                    phase_next = PHASE_1;
                end

                PHASE_1: begin
                    output_data_next  = {
                        previous_data_reg, I_96b_data[95:64]
                    };
                    output_valid_next = 1'b1;
                    phase_next        = PHASE_2;
                end

                PHASE_2: begin
                    output_data_next  = {
                        previous_data_reg[63:0], I_96b_data[95:32]
                    };
                    output_valid_next = 1'b1;
                    phase_next        = PHASE_3;
                end

                PHASE_3: begin
                    output_data_next  = {
                        previous_data_reg[31:0], I_96b_data
                    };
                    output_valid_next = 1'b1;
                    phase_next        = PHASE_0;
                end

                default: begin
                    phase_next = PHASE_0;
                end
            endcase

            // Hold the marker until the first complete 128-bit word appears.
            if (output_valid_next && frame_start_pending_reg) begin
                output_frame_start_next  = 1'b1;
                frame_start_pending_next = 1'b0;
            end
        end
    end

    always @(posedge I_clk) begin
        if (!I_rst_n) begin
            previous_data_reg       <= 96'd0;
            phase_reg               <= PHASE_0;
            frame_start_pending_reg <= 1'b0;
            O_128b_frame_start      <= 1'b0;
            O_128b_valid            <= 1'b0;
            O_128b_data             <= 128'd0;
        end else begin
            previous_data_reg       <= previous_data_next;
            phase_reg               <= phase_next;
            frame_start_pending_reg <= frame_start_pending_next;
            O_128b_frame_start      <= output_frame_start_next;
            O_128b_valid            <= output_valid_next;
            O_128b_data             <= output_data_next;
        end
    end

endmodule

`default_nettype wire
