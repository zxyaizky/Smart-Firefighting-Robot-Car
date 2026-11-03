

module data_96bit_to_128bit (
    input wire        I_clk,
    input wire        I_rst_n,
   
    input wire        I_96b_frame_start,
    input wire        I_96b_valid,
    input wire[95:0]  I_96b_data,
  
    output reg        O_128b_frame_start,
    output reg        O_128b_valid,
    output reg[127:0] O_128b_data
);



    reg [95:0] S_96b_data_1d;
    reg [1:0]  S_cnt;

    // Four valid 96-bit input words are repacked into three 128-bit words.
    // Invalid clocks are bubbles, not line/frame boundaries: preserve both
    // the saved data and packing phase across them.  A new frame explicitly
    // restarts the phase so no residual word can leak between frames.
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_96b_data_1d     <= 96'd0;
            S_cnt             <= 2'd0;
            O_128b_frame_start <= 1'b0;
            O_128b_valid       <= 1'b0;
            O_128b_data        <= 128'd0;
        end else begin
            O_128b_frame_start <= I_96b_frame_start;
            O_128b_valid       <= 1'b0;

            if (I_96b_frame_start) begin
                S_cnt <= I_96b_valid ? 2'd1 : 2'd0;
                if (I_96b_valid)
                    S_96b_data_1d <= I_96b_data;
            end else if (I_96b_valid) begin
                case (S_cnt)
                    2'd0: begin
                        S_96b_data_1d <= I_96b_data;
                        S_cnt         <= 2'd1;
                    end
                    2'd1: begin
                        O_128b_data    <= {S_96b_data_1d,
                                           I_96b_data[95:64]};
                        O_128b_valid   <= 1'b1;
                        S_96b_data_1d  <= I_96b_data;
                        S_cnt          <= 2'd2;
                    end
                    2'd2: begin
                        O_128b_data    <= {S_96b_data_1d[63:0],
                                           I_96b_data[95:32]};
                        O_128b_valid   <= 1'b1;
                        S_96b_data_1d  <= I_96b_data;
                        S_cnt          <= 2'd3;
                    end
                    default: begin
                        O_128b_data    <= {S_96b_data_1d[31:0],
                                           I_96b_data};
                        O_128b_valid   <= 1'b1;
                        S_96b_data_1d  <= I_96b_data;
                        S_cnt          <= 2'd0;
                    end
                endcase
            end
        end
    end

    

endmodule







/*
module data96_128 (

    input wire [95:0] I_tdata,

    output wire [127:0] O_tdata

);

  assign O_tdata = {
    {8'd0}, I_tdata[95:72], {8'd0}, I_tdata[71:48], {8'd0}, I_tdata[47:24], {8'd0}, I_tdata[23:0]
  };
 
endmodule
*/

