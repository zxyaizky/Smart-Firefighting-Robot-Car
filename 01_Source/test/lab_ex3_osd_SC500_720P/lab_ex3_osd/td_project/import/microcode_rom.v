// Shared 64-bit x 32-word synchronous microcode ROM.
// TD resolves initialization files beside this RTL source. Simulation launched
// from the repository root defines MICROCODE_FILE to this same project resource.
`timescale 1ns/1ps

`ifndef MICROCODE_FILE
  `define MICROCODE_FILE "microcode_words.hex"
`endif

module microcode_rom (
    input  wire [4:0]  address,
    input  wire         clock,
    output reg  [63:0] q
);
    reg [63:0] words [0:31];

    initial begin
        $readmemh(`MICROCODE_FILE, words);
    end

    always @(posedge clock) begin
        q <= words[address];
    end
endmodule
