    // Shared test wiring; DUT is always the current production subsystem.
    wire app_en,wdf_valid,wdf_end,read_ready,write_ready,wdf_ready;
    wire [24:0] app_addr;
    wire [2:0] app_cmd;
    wire [127:0] wdf_data,rd_data;
    wire [15:0] wdf_mask;
    wire rd_valid,rd_end;
    wire video_ready,video_rd_valid;
    wire [127:0] video_rd_data;
    reg video_wr=0, video_rd=0;
    reg [24:0] video_addr=0;
    reg [127:0] video_data=0;
    reg load_begin=0,load_valid=0,load_last=0;
    reg [23:0] load_size=0;
    reg [31:0] load_crc=0;
    reg [127:0] load_data=0;
    wire load_begin_ready,load_ready,load_busy,load_error,params_ready,transport_error;
    reg hold_responses=0,stall_commands=0,corrupt_readback=0;
    npu_ddr_subsystem memory_path (
        .clk_ddr(dclk),.clk_npu(clk),.rst_n(memory_rst_n),.i_client_rst_n(client_rst_n),
        .i_video_wr(video_wr),.i_video_rd(video_rd),.i_video_addr(video_addr),.i_video_data(video_data),
        .o_video_ready(video_ready),.o_video_rd_valid(video_rd_valid),.o_video_rd_data(video_rd_data),
        .i_load_begin_valid(load_begin),.o_load_begin_ready(load_begin_ready),
        .i_load_size_bytes(load_size),.i_load_crc32(load_crc),
        .i_load_valid(load_valid),.o_load_ready(load_ready),.i_load_data(load_data),.i_load_last(load_last),
        .o_load_busy(load_busy),.o_load_error(load_error),.o_params_ready_npu(params_ready),
        .i_npu_req_valid(req),.o_npu_req_ready(req_ready),.i_npu_req_addr(req_addr),.i_npu_req_len(req_len),
        .o_npu_rd_valid(npu_rd_valid),.o_npu_rd_data(npu_rd_data),
        .o_app_en(app_en),.o_app_addr(app_addr),.o_app_cmd(app_cmd),
        .i_app_read_ready(read_ready),.i_app_write_ready(write_ready),.o_wdf_valid(wdf_valid),
        .o_wdf_data(wdf_data),.o_wdf_end(wdf_end),.o_wdf_mask(wdf_mask),.i_wdf_ready(wdf_ready),
        .i_rd_valid(rd_valid),.i_rd_end(rd_end),.i_rd_data(rd_data),.o_transport_error(transport_error)
    );
    native_memory_model mem (
        .clk(dclk),.rst_n(memory_rst_n),.app_en(app_en),.app_cmd(app_cmd),.app_addr(app_addr),
        .read_ready(read_ready),.write_ready(write_ready),.wdf_valid(wdf_valid),.wdf_data(wdf_data),
        .wdf_end(wdf_end),.wdf_mask(wdf_mask),.wdf_ready(wdf_ready),
        .rd_valid(rd_valid),.rd_end(rd_end),.rd_data(rd_data),
        .hold_responses(hold_responses),.stall_commands(stall_commands),.corrupt_readback(corrupt_readback)
    );
