module Matrix_Generate_3X3_8Bit #
(
    parameter [10:0] IMG_HDISP = 11'd1280,
    parameter       SPARSE_INPUT = 1'b0
)
(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       per_frame_vsync,
    input  wire       per_frame_href,
    input  wire       per_frame_clken,
    input  wire [7:0] per_img_Y,

    output wire       matrix_frame_vsync,
    output wire       matrix_frame_href,
    output wire       matrix_frame_clken,
    output wire [7:0] matrix_p11,
    output wire [7:0] matrix_p12,
    output wire [7:0] matrix_p13,
    output wire [7:0] matrix_p21,
    output wire [7:0] matrix_p22,
    output wire [7:0] matrix_p23,
    output wire [7:0] matrix_p31,
    output wire [7:0] matrix_p32,
    output wire [7:0] matrix_p33
);

wire [7:0] row1_data;
wire [7:0] row2_data;
wire       read_frame_href;
wire       read_frame_clken;
wire       tail_clken;
wire       first_column;
wire       third_last_column;
wire       penultimate_column;
wire       last_column;

reg [7:0] row3_data;
reg [6:0] per_frame_vsync_r;
reg [6:0] per_frame_href_r;
reg [6:0] per_frame_clken_r;
reg [10:0] output_column;

reg [7:0] top0;
reg [7:0] top1;
reg [7:0] top2;
reg [7:0] middle0;
reg [7:0] middle1;
reg [7:0] middle2;
reg [7:0] middle_n1;
reg [7:0] middle_n2;
reg [7:0] bottom0;
reg [7:0] bottom1;
reg [7:0] bottom2;
reg [7:0] bottom3;
reg [7:0] bottom_n1;
reg [7:0] bottom_n2;
reg [7:0] bottom_n3;

// RGB565 pixels are valid on alternate 96 MHz clocks.  Preserve those
// one-clock pulses and add only two isolated flush pulses in horizontal blank.
assign tail_clken = (!per_frame_href) &&
                    (per_frame_clken_r[2] | per_frame_clken_r[4]);
assign read_frame_href = |per_frame_href_r[5:0];
assign read_frame_clken = per_frame_clken_r[0] | tail_clken;

assign matrix_frame_vsync = per_frame_vsync_r[6];
assign matrix_frame_href = per_frame_href_r[6];
assign matrix_frame_clken = per_frame_clken_r[6];

assign first_column = (output_column == 11'd0);
assign third_last_column = (output_column == IMG_HDISP - 11'd3);
assign penultimate_column = (output_column == IMG_HDISP - 11'd2);
assign last_column = (output_column == IMG_HDISP - 11'd1);

// The same matrix is used by the sparse 96 MHz camera stream and by a
// continuous-valid 25 MHz display stream.  The line RAM has a fixed clock
// latency, so the three rows occupy different history taps in the two cases.
generate
    if (SPARSE_INPUT) begin : g_sparse_taps
        assign matrix_p11 = first_column ? top2 : top1;
        assign matrix_p12 = first_column ? top2 :
                            last_column  ? top1 : top2;
        assign matrix_p13 = first_column       ? row1_data :
                            penultimate_column ? top2 :
                            last_column        ? top1 : row1_data;

        assign matrix_p21 = first_column ? middle1 : middle0;
        assign matrix_p22 = middle1;
        assign matrix_p23 = first_column ? middle2 :
                            last_column  ? middle1 : middle2;

        assign matrix_p31 = first_column ? bottom1 : bottom0;
        assign matrix_p32 = bottom1;
        assign matrix_p33 = first_column ? bottom2 :
                            last_column  ? bottom1 : bottom2;
    end else begin : g_continuous_taps
        assign matrix_p11 = first_column ? top1 : top0;
        assign matrix_p12 = third_last_column ? top1 :
                            (penultimate_column | last_column) ? top0 : top1;
        assign matrix_p13 = third_last_column ? top1 :
                            (penultimate_column | last_column) ? top0 : top2;

        assign matrix_p21 = first_column ? middle_n1 :
                            last_column  ? middle_n1 : middle_n2;
        assign matrix_p22 = last_column ? middle0 : middle_n1;
        assign matrix_p23 = middle0;

        assign matrix_p31 = first_column ? bottom_n2 :
                            last_column  ? bottom_n2 : bottom_n3;
        assign matrix_p32 = last_column ? bottom_n1 : bottom_n2;
        assign matrix_p33 = bottom_n1;
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        row3_data <= 8'd0;
    else if (per_frame_clken)
        row3_data <= per_img_Y;
end

line_shift_RAM_8bit u_line_shift_ram_8bit
(
    .clock          (clk),
    .clken          (per_frame_clken),
    .per_frame_href (per_frame_href),
    .shiftin        (per_img_Y),
    .taps0x         (row2_data),
    .taps1x         (row1_data)
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        per_frame_vsync_r <= 7'd0;
        per_frame_href_r <= 7'd0;
        per_frame_clken_r <= 7'd0;
    end else begin
        per_frame_vsync_r <= {per_frame_vsync_r[5:0], per_frame_vsync};
        per_frame_href_r <= {per_frame_href_r[5:0], per_frame_href};
        per_frame_clken_r <= {per_frame_clken_r[5:0], per_frame_clken};
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        output_column <= 11'd0;
    else if (!matrix_frame_href)
        output_column <= 11'd0;
    else if (matrix_frame_clken) begin
        if (output_column == IMG_HDISP - 11'd1)
            output_column <= 11'd0;
        else
            output_column <= output_column + 11'd1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        top0 <= 8'd0;
        top1 <= 8'd0;
        top2 <= 8'd0;
        middle0 <= 8'd0;
        middle1 <= 8'd0;
        middle2 <= 8'd0;
        middle_n1 <= 8'd0;
        middle_n2 <= 8'd0;
        bottom0 <= 8'd0;
        bottom1 <= 8'd0;
        bottom2 <= 8'd0;
        bottom3 <= 8'd0;
        bottom_n1 <= 8'd0;
        bottom_n2 <= 8'd0;
        bottom_n3 <= 8'd0;
    end else if (!read_frame_href) begin
        top0 <= 8'd0;
        top1 <= 8'd0;
        top2 <= 8'd0;
        middle0 <= 8'd0;
        middle1 <= 8'd0;
        middle2 <= 8'd0;
        middle_n1 <= 8'd0;
        middle_n2 <= 8'd0;
        bottom0 <= 8'd0;
        bottom1 <= 8'd0;
        bottom2 <= 8'd0;
        bottom3 <= 8'd0;
        bottom_n1 <= 8'd0;
        bottom_n2 <= 8'd0;
        bottom_n3 <= 8'd0;
    end else if (read_frame_clken) begin
        top0 <= top1;
        top1 <= top2;
        top2 <= row1_data;
        middle_n2 <= middle_n1;
        middle_n1 <= middle0;
        middle0 <= middle1;
        middle1 <= middle2;
        middle2 <= row2_data;
        bottom_n3 <= bottom_n2;
        bottom_n2 <= bottom_n1;
        bottom_n1 <= bottom0;
        bottom0 <= bottom1;
        bottom1 <= bottom2;
        bottom2 <= bottom3;
        bottom3 <= row3_data;
    end
end

endmodule
