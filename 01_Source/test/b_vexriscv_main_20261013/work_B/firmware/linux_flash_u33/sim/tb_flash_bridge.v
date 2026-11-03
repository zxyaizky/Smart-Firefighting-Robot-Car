`timescale 1ns/1ps
module tb_flash_bridge;
    reg clk=0,ahb_clk=0,rst=1;
    always #10 clk=~clk;
    always #7 ahb_clk=~ahb_clk;
    reg cyc=0,stb=0,we=0;
    reg [29:0] address=0;
    wire ack,err;
    wire [31:0] data,hrdata;
    wire [1:0] hresp;
    wire hready;
    reg [1:0] htrans=0;
    reg hwrite=0;
    reg [30:0] haddr=0;
    reg [2:0] hsize=2;
    reg [31:0] hwdata=0;
    integer tests=0,i,limit;
    reg [31:0] value;
    cpu_u33_flash_bridge #(.TIMEOUT_CYCLES(200)) dut(
        .clk(clk),.rst(rst),.clk_ahb(ahb_clk),.rst_ahb(rst),
        .cyc_i(cyc),.stb_i(stb),.we_i(we),.address_i(address),
        .ack_o(ack),.error_o(err),.data_o(data),.htrans_i(htrans),
        .hwrite_i(hwrite),.haddr_i(haddr),.hsize_i(hsize),.hwdata_i(hwdata),
        .hrdata_o(hrdata),.hresp_o(hresp),.hready_o(hready)
    );
    task fail;
        input [511:0] reason;
        begin $display("FAIL bridge %0s",reason);$finish;end
    endtask
    task reset;
        begin rst=1;cyc=0;stb=0;we=0;htrans=0;repeat(8)@(negedge clk);rst=0;end
    endtask
    task start;
        input [31:0] a;
        input writing;
        begin @(negedge clk);cyc=1;stb=1;we=writing;address=a>>2;end
    endtask
    task ahb_read;
        input [30:0] a;
        output [31:0] v;
        begin
            @(negedge ahb_clk);haddr=a;htrans=2;hwrite=0;hsize=2;
            @(negedge ahb_clk);htrans=0;#1;
            if(hready!==1 || hresp!==0)fail("AHB read response");
            v=hrdata;
            if((^v)===1'bx)fail("unknown AHB data");
        end
    endtask
    task ahb_write;
        input [30:0] a;
        input [31:0] v;
        begin
            @(negedge ahb_clk);haddr=a;htrans=2;hwrite=1;
            @(negedge ahb_clk);htrans=0;hwdata=v;
            @(negedge ahb_clk);
        end
    endtask
    task finish_request;
        input expected_error;
        input [31:0] expected_data;
        begin
            limit=0;
            while(ack!==1 && err!==1 && limit<250)begin @(negedge clk);limit=limit+1;end
            if(limit>=250 || err!==expected_error || ack===err)fail("missing/wrong WB termination");
            if(!expected_error && data!==expected_data)fail("WB read data");
            cyc=0;stb=0;repeat(3)@(negedge clk);
            if(ack!==0 || err!==0)fail("response without owner");
            tests=tests+1;
        end
    endtask
    initial begin
        reset;
        for(i=0;i<4;i=i+1)begin
            // Includes offsets beyond the old 19-bit/512 KiB ingress limit.
            start(32'h20200000+i*32'h100000,0);
            repeat(6+i)@(negedge ahb_clk);
            ahb_read(0,value);if(value!==1)fail("no pending request");
            ahb_read(4,value);if(value!==32'h20200000+i*32'h100000)fail("address truncated");
            ahb_write(8,32'h12340000+i);
            finish_request(0,32'h12340000+i);
        end
        start(32'h20200000,1);finish_request(1,0);
        start(32'h21000000,0);finish_request(1,0);
        start(32'h20200000,0);
        repeat(5)@(negedge ahb_clk);ahb_write(12,32'hdeadbeef);
        finish_request(1,0);
        start(32'h20200000,0);finish_request(1,0);
        // A late reply after timeout must never satisfy a new transaction.
        ahb_write(8,32'hbadbad00);
        start(32'h20200004,0);finish_request(1,0);
        reset;
        start(32'h20fffffc,0);repeat(6)@(negedge ahb_clk);
        ahb_read(4,value);if(value!==32'h20fffffc)fail("last Flash address");
        ahb_write(8,32'hfeedbeef);finish_request(0,32'hfeedbeef);
        start(32'h20200000,0);repeat(4)@(negedge clk);
        cyc=0;stb=0;repeat(4)@(negedge clk);
        // Replacement owner must not receive the canceled request's response.
        start(32'h20200004,0);ahb_write(8,32'hbad00000);
        repeat(6)begin @(negedge clk);if(ack || err)fail("canceled reply reused");end
        repeat(5)@(negedge ahb_clk);
        ahb_read(4,value);if(value!==32'h20200004)fail("replacement address");
        ahb_write(8,32'habcdef01);finish_request(0,32'habcdef01);
        start(32'h20200000,0);repeat(4)@(negedge clk);reset;
        start(32'h20200004,0);repeat(6)@(negedge ahb_clk);
        ahb_write(8,32'h55aa55aa);finish_request(0,32'h55aa55aa);
        $display("PASS flash_bridge checks=%0d CDC AHB_phases wide_address readonly timeout late_reply reset",tests);
        $finish;
    end
    initial begin #2000000;fail("watchdog");end
endmodule
