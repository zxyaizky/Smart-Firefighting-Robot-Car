`timescale 1ns/1ps
module tb_integer_boundaries;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,valid=0;
    reg signed [31:0] value=0;
    reg [1:0] activation=0;
    reg [3:0] shift=0;
    wire signed [31:0] act;
    wire av,qv;
    wire [7:0] q;
    reg [79:0] vectors[0:9999];
    reg [79:0] current;
    integer count,dummy,i,acts=0,quants=0;
    activation_single a(.clk(clk),.rst_n(rst_n),.cfg_activation_type(activation),
        .in_sum(value),.in_valid(valid),.out_act(act),.out_valid(av));
    quantize_single z(.clk(clk),.rst_n(rst_n),.in_act(act),.in_valid(av),
        .shift_bits(shift),.out_pixel(q),.out_valid(qv));
    always @(posedge clk) if(rst_n) begin
        if(av) begin
            if(act!==current[39:8]) begin
                $display("FAIL activation vector=%0d actual=%h expected=%h",i,act,current[39:8]); $finish;
            end
            acts=acts+1;
        end
        if(qv) begin
            if(q!==current[7:0]) begin $display("FAIL quantization vector=%0d",i); $finish; end
            quants=quants+1;
        end
    end
    initial begin
        dummy=$value$plusargs("COUNT=%d",count);
        $readmemh("sim/network12/boundaries.hex",vectors,0,count-1);
        repeat(4) @(negedge clk); rst_n=1;
        for(i=0;i<count;i=i+1) begin
            @(negedge clk); current=vectors[i];
            activation=current[77:76];shift=current[75:72];value=current[71:40];valid=1;
            @(negedge clk);valid=0;
            repeat(3) @(negedge clk);
        end
        // Reset with activation valid but quantization not yet committed.
        @(negedge clk); current=vectors[0]; activation=current[77:76];
        shift=current[75:72];value=current[71:40];valid=1;
        @(posedge clk); #1; rst_n=0;valid=0;
        repeat(3) @(negedge clk);rst_n=1;
        repeat(4) @(negedge clk);
        if(acts!=count || quants!=count || av || qv) begin $display("FAIL reset/count"); $finish; end
        $display("INTEGER_BOUNDARIES_PASS vectors=%0d",count);$finish;
    end
endmodule
