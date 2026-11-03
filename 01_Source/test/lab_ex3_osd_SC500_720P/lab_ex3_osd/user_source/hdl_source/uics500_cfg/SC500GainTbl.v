`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Create Date:    01:32:02 06/12/2023 
// Module Name:    SC500GainTbl 
//////////////////////////////////////////////////////////////////////////////////
module SC500GainTbl(
	input 			I_clk,
	input 			I_rstn,
	input 	[6:0] 	I,
	output reg	[15:0] 	O
);

	// Four continuous fine-gain ranges. I=96 produces 16'h1f20,
	// matching the gain programmed by the original 720p register table.
	always @(posedge I_clk) begin
		if (!I_rstn)
			O <= 16'h1f20;
		else if (I < 7'd32)
			O <= 16'h0320 + I;
		else if (I < 7'd64)
			O <= 16'h0720 + (I - 7'd32);
		else if (I < 7'd96)
			O <= 16'h0f20 + (I - 7'd64);
		else
			O <= 16'h1f20 + (I - 7'd96);
	end

endmodule
