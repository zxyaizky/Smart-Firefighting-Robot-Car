// Real VexRiscv/ROM/Wishbone bridges; simulated MCU AHB service and DDR storage.
`timescale 1ns/1ps
module tb_flash_boot;
    reg clk=0,ahb_clk=0,rst=1;
    always #10 clk=~clk;
    always #5 ahb_clk=~ahb_clk;
    wire tx,req_valid,req_ready,req_write,rsp_ready;
    wire [24:0] req_address;
    wire [127:0] req_data;
    wire [15:0] req_mask;
    wire [1:0] lane;
    wire [3:0] select;
    wire [31:0] status,result,last_trap;
    wire [2:0] debug;
    reg rsp_valid=0;
    reg [31:0] rsp_data=0;
    reg [1:0] htrans=0;
    reg hwrite=0;
    reg [30:0] haddr=0;
    reg [2:0] hsize=2;
    reg [31:0] hwdata=0;
    wire [31:0] hrdata;
    wire [1:0] hresp;
    wire hready;
    reg [31:0] memory[0:8388607];
    reg [31:0] flash[0:255];
    integer i,b,word_index,cycles=0,reads=0,delay_count=0,mode=0;
    reg [31:0] value,source;
    assign req_ready=!rsp_valid && delay_count==0;
    vexriscv_b_subsystem #(.ENABLE_DDR(1),.DDR_BOOT_ENABLE(1),.UART_ENABLE(1),
        .DDR_WORD_RESPONSE(1),.U33_FLASH_ENABLE(1)) dut (
        .clk(clk),.rst(rst),.clk_ahb(ahb_clk),.rst_ahb(rst),
        .mcu_htrans_i(htrans),.mcu_hwrite_i(hwrite),.mcu_haddr_i(haddr),
        .mcu_hsize_i(hsize),.mcu_hwdata_i(hwdata),.mcu_hrdata_o(hrdata),
        .mcu_hresp_o(hresp),.mcu_hready_o(hready),
        .cycle_count_o(),.status_o(status),.heartbeat_o(),.last_trap_o(last_trap),
        .result_o(result),.protocol_error_o(),.debug_state_o(debug),
        .ddr_ready_i(1'b1),.ddr_errors_i(2'b00),
        .ddr_req_valid_o(req_valid),.ddr_req_ready_i(req_ready),
        .ddr_req_write_o(req_write),.ddr_req_addr_o(req_address),
        .ddr_req_wdata_o(req_data),.ddr_req_mask_o(req_mask),
        .ddr_req_lane_o(lane),.ddr_req_select_o(select),
        .ddr_rsp_valid_i(rsp_valid),.ddr_rsp_ready_o(rsp_ready),
        .ddr_rsp_rdata_i(rsp_data),.ddr_rsp_error_i(1'b0),
        .ddr_status_o(),.ddr_heartbeat_o(),.ddr_busy_o(),.ddr_error_o(),
        .ddr_read_done_o(),.ddr_write_done_o(),.uart_rx_i(1'b1),.uart_tx_o(tx)
    );
    defparam dut.u33_flash_enabled.flash_bridge_inst.TIMEOUT_CYCLES=100000;
    task fail;
        input [511:0] reason;
        begin
            $display("FAIL flash_boot mode=%0d PC=%08x result=%08x trap=%08x %0s",
                mode,dut.cpu_top_inst.cpu_inst.writeBack_PC,result,last_trap,reason);
            $finish;
        end
    endtask
    task ahb_read;
        input [30:0] address;
        output [31:0] word;
        begin
            @(negedge ahb_clk);haddr=address;htrans=2;hwrite=0;
            @(negedge ahb_clk);htrans=0;#1;word=hrdata;
            if(hready!==1 || hresp!==0 || (^word)===1'bx)fail("AHB read");
        end
    endtask
    task ahb_write;
        input [31:0] word;
        begin
            @(negedge ahb_clk);haddr=8;htrans=2;hwrite=1;
            @(negedge ahb_clk);htrans=0;hwdata=word;
            @(negedge ahb_clk);
        end
    endtask
    initial begin
        if($value$plusargs("MODE=%d",mode))begin end
        $readmemh("flash_test.hex",flash);
        if(mode==1)flash[255]=flash[255]^32'h100;
        for(i=0;i<8388608;i=i+1)memory[i]=0;
        repeat(16)@(negedge clk);rst=0;
    end
    initial begin
        wait(!rst);
        forever begin
            ahb_read(0,value);
            if(value[0] && mode!=2)begin
                ahb_read(4,source);
                if(source<32'h20200000 || source>=32'h20200400)fail("XIP address");
                repeat(reads%7)@(negedge ahb_clk);
                ahb_write(flash[(source-32'h20200000)>>2]);reads=reads+1;
            end
        end
    end
    always @(posedge clk)begin
        if(!rst)begin
            cycles=cycles+1;
            if((^{status,result,last_trap,tx,debug})===1'bx)fail("unknown architectural state");
            if(req_valid && req_ready)begin
                if(req_address<25'h1000000 || req_address[2:0]!==0)fail("native DDR address");
                word_index=((req_address-25'h1000000)>>1)+lane;
                if(req_write)for(b=0;b<4;b=b+1)if(select[b])begin
                    if((^req_data[8*b+:8])===1'bx)fail("unknown DDR write");
                    memory[word_index][8*b+:8]<=req_data[8*b+:8];
                end
                rsp_data<=memory[word_index];delay_count<=2+cycles%4;
            end
            if(delay_count>0)begin
                delay_count<=delay_count-1;
                if(delay_count==1)rsp_valid<=1;
            end
            if(rsp_valid && rsp_ready)rsp_valid<=0;
            if(mode==0 && result==32'h600df123)begin
                if(reads!=256)fail("incomplete Flash copy");
                for(i=0;i<256;i=i+1)if(memory[262144+i]!==flash[i])fail("DDR copy mismatch");
                $display("PASS flash_boot ROM_reset_selftest_XIP_copy_DDR_CRC_FENCEI_jump cycles=%0d words=%0d",cycles,reads);$finish;
            end
            if(mode==1 && result==32'hbad30043)begin
                if(reads!=256)fail("CRC checked before copy finished");
                $display("PASS flash_boot corrupt_CRC_rejected_no_jump cycles=%0d",cycles);$finish;
            end
            if(mode==2 && result==32'hbad30045)begin
                if(last_trap!==5)fail("expected load access fault");
                $display("PASS flash_boot missing_MCU_bounded_error_no_jump cycles=%0d",cycles);$finish;
            end
            if(status==32'hbad00001 || result==32'hbad20001)fail("original boot selftest");
            if(cycles>3000000)fail("watchdog");
        end
    end
endmodule
