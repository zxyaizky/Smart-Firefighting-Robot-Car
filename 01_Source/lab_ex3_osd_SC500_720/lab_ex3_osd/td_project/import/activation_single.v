module activation_single #(
    parameter ACC_WIDTH = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire[1:0]             cfg_activation_type,
    input  wire signed [ACC_WIDTH-1:0] in_sum,
    input  wire                   in_valid,
    output reg  signed[ACC_WIDTH-1:0] out_act,
    output reg                    out_valid
);
    // Exact integer activation: ((s+3)*43) >>> 8. A signed ACC_WIDTH+7
    // intermediate covers INT32 extrema; the former 33-bit shift/add wrapped.
    wire signed [ACC_WIDTH+6:0] extended_sum = {{7{in_sum[ACC_WIDTH-1]}}, in_sum};
    wire signed [ACC_WIDTH+6:0] plus_three = extended_sum + 3;
    wire signed [ACC_WIDTH+6:0] scaled = (plus_three <<< 5) +
        (plus_three <<< 3) + (plus_three <<< 1) + plus_three;
    wire signed [ACC_WIDTH+6:0] shifted_activation = scaled >>> 8;
    wire signed [ACC_WIDTH-1:0] hardsig_val = shifted_activation[ACC_WIDTH-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_act   <= 0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= in_valid; 
            if (in_valid) begin
                if (cfg_activation_type == 2'b01) begin // HardSigmoid
                    out_act <= hardsig_val;
                end else if (cfg_activation_type == 2'b10) begin // identity
                    out_act <= in_sum;
                end else begin                          // ReLU (Default)
                    out_act <= (in_sum < 0) ? 0 : in_sum;
                end
            end
        end
    end
endmodule