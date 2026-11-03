`timescale 1ns/1ps
module tb_network12;
    `include "../td_project/import/npu_model_config.vh"
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,frame=0,valid=0;
    reg [7:0] pixel=0;
    wire busy,model_ready,done,error,tensor_valid,layer_done;
    wire [63:0] tensor_data;
    wire [7:0] tensor_x,tensor_y;
    wire req;
    wire [23:0] req_addr;
    wire [15:0] req_len;
    reg req_ready=0,rd_valid=0;
    reg [15:0] rd_data=0;
    reg [2:0] memory_state=0;
    reg [15:0] memory [0:MODEL_PARAMETER_HALFWORDS-1];
    reg [7:0] image [0:57599];
    reg [31:0] descriptors [0:95];
    integer fd,i,cycles=0,address,outputs=0,layers=0,loads=0,requests=0;
    integer boot_writes=0;
    reg own_input=0;
    reg dma_req_d=0;
    npu_network_top dut (
        .clk(clk),.rst_n(rst_n),.i_frame_valid(frame),.i_byte_valid(valid),.i_byte(pixel),
        .o_input_busy(busy),.o_model_ready(model_ready),.o_inference_done(done),
        .o_tile_error(error),.o_layer_done(layer_done),.o_tile_ready(),.o_tile_done(),
        .o_tensor_valid(tensor_valid),.o_tensor_data(tensor_data),
        .o_tensor_x(tensor_x),.o_tensor_y(tensor_y),
        .o_sdram_rd_req_valid(req),.i_sdram_rd_req_ready(req_ready),
        .o_sdram_rd_addr(req_addr),.o_sdram_rd_len_halfwords(req_len),
        .i_sdram_rd_data(rd_data),.i_sdram_rd_valid(rd_valid)
    );
    always @(negedge clk) begin
        req_ready=0; rd_valid=0;
        if (!rst_n) memory_state=0;
        else case(memory_state)
            0: if(req && cycles%7>=3) begin
                req_ready=1; address=req_addr-24'hc00000;
                if(req_len!=2 || address<0 || address+1>=MODEL_PARAMETER_HALFWORDS) begin
                    $fdisplay(fd,"FAIL SDRAM bounds"); $finish;
                end
                memory_state=1; requests=requests+1;
            end
            1: memory_state=2;
            2: begin rd_valid=1; rd_data=memory[address]; memory_state=3; end
            3: memory_state=4;
            4: begin rd_valid=1; rd_data=memory[address+1]; memory_state=5; end
            5: memory_state=0;
            default: memory_state=0;
        endcase
    end
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>100000000) begin $fdisplay(fd,"FAIL timeout"); $finish; end
        if(rst_n) begin
            if(error) begin $fdisplay(fd,"FAIL tile error layer=%0d",dut.u_npu.u_core.w_layer_id); $finish; end
            if(dut.desc_write) begin
                if((boot_writes < 96 && dut.desc_data !== descriptors[boot_writes]) ||
                   (boot_writes >= 96 && dut.desc_data !== 32'd0)) begin
                    $fdisplay(fd,"FAIL descriptor boot"); $finish;
                end
                boot_writes=boot_writes+1;
            end
            if(dut.u_npu.w_preload_done) begin
                loads=loads+1; own_input=1;
                if(!model_ready || boot_writes!=256) begin $fdisplay(fd,"FAIL early load"); $finish; end
            end
            if(own_input && !busy && !done) begin $fdisplay(fd,"FAIL ownership"); $finish; end
            if(dut.u_npu.r_inference_busy && dut.u_npu.w_preload_wr_en) begin
                $fdisplay(fd,"FAIL input overwritten"); $finish;
            end
            dma_req_d<=dut.u_npu.w_dma_req;
            if(dut.u_npu.w_dma_req && !dma_req_d)
                $fdisplay(fd,"D %0d %0d %0d %0d %0d %0d %0d",
                    dut.u_npu.u_core.w_layer_id,dut.u_npu.u_core.w_oc_group_idx,
                    dut.u_npu.u_core.w_tile_y_base,dut.u_npu.u_core.w_cin_group_idx,
                    dut.u_npu.w_dma_base_addr,dut.u_npu.w_bias_base_addr,dut.u_npu.w_dma_length);
            if(dut.u_npu.u_core.u_conv_engine.pe_valid_bus[0]) begin
                $fdisplay(fd,"C %0d %0d %0d %0d %0128h",dut.u_npu.u_core.w_layer_id,
                    dut.u_npu.u_core.w_oc_group_idx,dut.u_npu.u_core.u_conv_engine.pe_x_bus[7:0],
                    dut.u_npu.u_core.u_conv_engine.pe_y_bus[7:0],dut.u_npu.u_core.u_conv_engine.pe_sum_bus);
                $fdisplay(fd,"B %0d %0d %0d %0d %0128h",dut.u_npu.u_core.w_layer_id,
                    dut.u_npu.u_core.w_oc_group_idx,dut.u_npu.u_core.u_conv_engine.bias_x,
                    dut.u_npu.u_core.u_conv_engine.bias_y,dut.u_npu.u_core.u_conv_engine.bias_sum_bus);
            end
            if(dut.u_npu.u_core.u_conv_engine.act_valid)
                $fdisplay(fd,"A %0d %0d %0d %0d %0128h",dut.u_npu.u_core.w_layer_id,
                    dut.u_npu.u_core.w_oc_group_idx,dut.u_npu.u_core.u_conv_engine.act_x,
                    dut.u_npu.u_core.u_conv_engine.act_y,dut.u_npu.u_core.u_conv_engine.act_out_bus);
            if(dut.u_npu.u_core.u_conv_engine.quant_valid)
                $fdisplay(fd,"Q %0d %0d %0d %0d %032h",dut.u_npu.u_core.w_layer_id,
                    dut.u_npu.u_core.w_oc_group_idx,dut.u_npu.u_core.u_conv_engine.quant_x,
                    dut.u_npu.u_core.u_conv_engine.quant_y,dut.u_npu.u_core.u_conv_engine.quant_out_bus);
            if(dut.u_npu.u_core.w_npu_out_valid)
                $fdisplay(fd,"O %0d %0d %0d %0d %032h",dut.u_npu.u_core.w_layer_id,
                    dut.u_npu.u_core.w_oc_group_idx,dut.u_npu.u_core.w_npu_out_x,
                    dut.u_npu.u_core.w_npu_out_y,dut.u_npu.u_core.w_npu_out_bus);
            if(layer_done) begin
                $fdisplay(fd,"L %0d",dut.u_npu.u_core.w_layer_id);
                $display("NETWORK_LAYER_DONE %0d cycles=%0d",dut.u_npu.u_core.w_layer_id,cycles);
                layers=layers+1;
            end
            if(tensor_valid) begin
                // The deployed wrapper intentionally exports only the low 64 bits.
                // Audit the complete 9-channel test tensor and its true coordinates
                // at the unchanged internal result-stream boundary.
                $fdisplay(fd,"F %0d %0d %018h",
                    dut.u_npu.u_core.w_npu_out_x,
                    dut.u_npu.u_core.w_npu_out_y,
                    dut.u_npu.o_result_stream_data[71:0]);
                outputs=outputs+1;
            end
            if(done) own_input=0;
        end
    end
    // Verify the actual physical storage at each computation write.
    genvar lane;
    generate for(lane=0;lane<16;lane=lane+1) begin : memory_audit
        reg [12:0] a;
        reg [7:0] value;
        reg target;
        always @(posedge clk) if(rst_n && dut.u_npu.u_core.w_npu_out_valid) begin
            a=dut.u_npu.u_core.w_bcu_wr_addr;
            value=dut.u_npu.u_core.w_npu_out_bus[lane*8+:8];
            target=dut.u_npu.u_core.w_pingpong_sel;
            #1;
            if((target ? dut.u_npu.u_core.u_ping_array.gen_sram_bank[lane].mem[a] :
                         dut.u_npu.u_core.u_pong_array.gen_sram_bank[lane].mem[a]) !== value) begin
                $fdisplay(fd,"FAIL memory commit"); $finish;
            end
        end
    end endgenerate
    initial begin
        fd=$fopen("sim/network12/observed.txt","w");
        $readmemh("sim/network12/input.hex",image);
        $readmemh("sim/network12/parameters16.hex",memory);
        $readmemh("sim/network12/descriptors.hex",descriptors);
        repeat(8) @(negedge clk); rst_n=1;
        // Frame starts during boot and remains asserted beyond ready: reject whole.
        frame=1; valid=1; pixel=8'h7d;
        repeat(280) @(negedge clk);
        frame=0; valid=0;
        repeat(8) @(negedge clk);
        if(!model_ready || busy || loads) begin $fdisplay(fd,"FAIL boot admission"); $finish; end
        frame=1;
        for(i=0;i<57600;i=i+1) begin
            @(negedge clk); valid=1; pixel=image[i];
            if(i%29==17) begin @(negedge clk); valid=0; repeat(3) @(negedge clk); end
        end
        @(negedge clk); valid=0; frame=0;
        wait(dut.u_npu.r_inference_busy);
        // Drive another complete frame during inference to test real wrapper busy.
        @(negedge clk); frame=1;
        for(i=0;i<57600;i=i+1) begin @(negedge clk); valid=1; pixel=~image[i]; end
        @(negedge clk); valid=0; frame=0;
        wait(done);
        repeat(32) @(negedge clk);
        if(outputs!=300 || layers!=12 || loads!=1 || busy) begin
            $fdisplay(fd,"FAIL totals %0d %0d %0d",outputs,layers,loads); $finish;
        end
        if(dut.u_npu.r_num4_layer_count[10]!=600 || dut.u_npu.r_num4_layer_count[11]!=300) begin
            $fdisplay(fd,"FAIL late layer debug"); $finish;
        end
        $fdisplay(fd,"PASS %0d %0d %0d %0d",outputs,layers,requests,cycles);
        $fclose(fd); $display("NETWORK12_PASS"); $finish;
    end
endmodule
