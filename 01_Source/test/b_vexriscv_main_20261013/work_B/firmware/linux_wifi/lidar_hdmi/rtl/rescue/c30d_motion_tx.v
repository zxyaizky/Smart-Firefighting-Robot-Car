`timescale 1ns/1ps
`default_nettype none
// Motion frame: AA, command (0 stop / 1 forward / 2 back / 3 left / 4 right), AA XOR command.
module c30d_motion_tx #(
    parameter integer CLK_HZ=50000000,BAUD_RATE=9600,REPEAT_MS=50
)(input wire clk,rst_n,input wire [2:0] cmd_code,input wire cmd_valid,
  input wire send_enable_i,
  output wire cmd_ready,output reg uart_tx,output wire busy);
    localparam integer BIT_CLKS=(CLK_HZ+BAUD_RATE/2)/BAUD_RATE;
    localparam integer REPEAT_CLKS=CLK_HZ/1000*REPEAT_MS;
    localparam integer REPEAT_WIDTH=REPEAT_CLKS<1 ? 1 : $clog2(REPEAT_CLKS+1);
    localparam integer BAUD_WIDTH=BIT_CLKS<2 ? 1 : $clog2(BIT_CLKS);
    reg [2:0] latest;
    reg pending,active;
    reg [REPEAT_WIDTH-1:0] repeat_count;
    reg [BAUD_WIDTH-1:0] baud_count;
    reg [1:0] byte_index;
    reg [3:0] bit_index;
    reg [9:0] shift;
    reg [7:0] packet[0:2];
    assign cmd_ready=1'b1;
    assign busy=active || (send_enable_i && pending);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            latest<=0;pending<=1;active<=0;repeat_count<=0;baud_count<=0;
            byte_index<=0;bit_index<=0;uart_tx<=1;shift<=10'h3ff;
        end else begin
            if(repeat_count<REPEAT_CLKS) repeat_count<=repeat_count+1;
            if(cmd_valid) begin latest<=(cmd_code<=3'd4) ? cmd_code : 3'd0;pending<=1;end
            // Pause only between complete frames; never truncate a UART packet.
            if(send_enable_i && !active && !cmd_valid && (pending || repeat_count==REPEAT_CLKS)) begin
                packet[0]<=8'haa;
                packet[1]<={5'd0,latest};
                packet[2]<=8'haa^{5'd0,latest};
                shift<={1'b1,8'haa,1'b0};uart_tx<=0;active<=1;
                byte_index<=0;bit_index<=0;baud_count<=0;repeat_count<=0;
                pending<=0;
            end else if(active) begin
                if(baud_count==BIT_CLKS-1) begin
                    baud_count<=0;
                    if(bit_index==9) begin
                        if(byte_index==2) begin active<=0;uart_tx<=1;end
                        else begin
                            byte_index<=byte_index+1;bit_index<=0;
                            shift<={1'b1,packet[byte_index+1],1'b0};uart_tx<=0;
                        end
                    end else begin shift<={1'b1,shift[9:1]};uart_tx<=shift[1];bit_index<=bit_index+1;end
                end else baud_count<=baud_count+1;
            end
        end
    end
endmodule
`default_nettype wire
