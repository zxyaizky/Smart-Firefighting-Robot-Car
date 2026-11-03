// -----------------------------------------------------------------------------
// File   : vexriscv_b_memory.v
// Author : Codex
// Date   : 2026-10-13
// -----------------------------------------------------------------------------
// Description:
//   Independent Wishbone ROM, 64-byte RAM, sparse Sv32 tables and test MMIO.
//   Registered ACK/ERR responses; DDR decode is handled by the outer bridge.
// -----------------------------------------------------------------------------
// Change Log:
//   2026-10-20  Codex  v1.5  Single-hart CLINT; retain legacy self-test interrupts.
//   2026-10-19  Codex  v1.4  4 KiB ROM and optional polling CPU UART.
//   2026-10-13  Codex  v1.0  Small synthesizable CPU execution environment.
//   2026-10-13  Codex  v1.1  DRAM payload plus resettable byte-valid bits; sized counters.
//   2026-10-13  Codex  v1.2  One shared boot ROM; bounded I/D read arbitration.
//   2026-10-16  Codex  v1.3  Synchronous ERAM ROM with explicit data-capture stage.
// -----------------------------------------------------------------------------
`resetall
`timescale 1ns / 1ps
`default_nettype none

(* keep_hierarchy = "true" *) module vexriscv_b_memory #
(
    // Period of the local, latched timer interrupt in 50 MHz CPU cycles.
    parameter integer TIMER_PERIOD_CYCLES = 50000,
    // Additional wait cycles after accepting each Wishbone beat.
    parameter integer WAIT_CYCLES = 1,
    // Local self-test remains available; this only enables the DDR boot branch.
    parameter DDR_BOOT_ENABLE = 1'b0,
    parameter UART_ENABLE = 1'b0
)
(
    input  wire        clk,
    input  wire        rst,
    input  wire        ibus_cyc_i,
    input  wire        ibus_stb_i,
    input  wire        ibus_we_i,
    input  wire [29:0] ibus_adr_i,
    input  wire [3:0]  ibus_sel_i,
    input  wire [2:0]  ibus_cti_i,
    input  wire [1:0]  ibus_bte_i,
    output wire        ibus_ack_o,
    output wire        ibus_err_o,
    output wire [31:0] ibus_data_o,
    input  wire        dbus_cyc_i,
    input  wire        dbus_stb_i,
    input  wire        dbus_we_i,
    input  wire [29:0] dbus_adr_i,
    input  wire [31:0] dbus_data_i,
    input  wire [3:0]  dbus_sel_i,
    input  wire [2:0]  dbus_cti_i,
    input  wire [1:0]  dbus_bte_i,
    output wire        dbus_ack_o,
    output wire        dbus_err_o,
    output wire [31:0] dbus_data_o,
    output wire        timer_interrupt_o,
    output wire        software_interrupt_o,
    output wire [31:0] external_interrupt_array_o,
    output wire [31:0] cycle_count_o,
    output wire [31:0] status_o,
    output wire [31:0] heartbeat_o,
    output wire [31:0] last_trap_o,
    output wire [31:0] result_o,
    output wire        protocol_error_o,
    input  wire        ddr_ready_i,
    input  wire        ddr_busy_i,
    input  wire [2:0]  ddr_errors_i,
    output wire [31:0] ddr_status_o,
    output wire [31:0] ddr_heartbeat_o,
    input  wire        uart_rx_i,
    output wire        uart_tx_o
);
    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_WAIT = 2'd1;
    localparam [1:0] STATE_RESPONSE = 2'd2;
    localparam [1:0] STATE_ROM_DATA = 2'd3;
    localparam integer TIMER_WIDTH = TIMER_PERIOD_CYCLES > 1 ?
        $clog2(TIMER_PERIOD_CYCLES) : 1;
    localparam integer WAIT_WIDTH = WAIT_CYCLES > 0 ? $clog2(WAIT_CYCLES + 1) : 1;
    localparam [TIMER_WIDTH-1:0] TIMER_LAST_CYCLE = TIMER_PERIOD_CYCLES - 1;
    localparam [WAIT_WIDTH-1:0] BEAT_WAIT = WAIT_CYCLES;

    reg [1:0] ibus_state_reg = STATE_IDLE, ibus_state_next;
    reg [1:0] dbus_state_reg = STATE_IDLE, dbus_state_next;
    reg [WAIT_WIDTH-1:0] ibus_wait_reg = {WAIT_WIDTH{1'b0}}, ibus_wait_next;
    reg [WAIT_WIDTH-1:0] dbus_wait_reg = {WAIT_WIDTH{1'b0}}, dbus_wait_next;
    reg [31:0] ibus_data_reg = 32'd0;
    reg [31:0] dbus_data_reg = 32'd0;
    reg ibus_error_reg = 1'b0;
    reg dbus_error_reg = 1'b0;
    reg [31:0] cycle_count_reg = 32'd0;
    reg [31:0] status_reg = 32'd0, status_next;
    reg [31:0] heartbeat_reg = 32'd0, heartbeat_next;
    reg [31:0] last_trap_reg = 32'd0, last_trap_next;
    reg [31:0] result_reg = 32'd0, result_next;
    reg [31:0] ddr_status_reg = 32'd0, ddr_status_next;
    reg [31:0] ddr_heartbeat_reg = 32'd0, ddr_heartbeat_next;
    reg [31:0] root_entry_reg = 32'h00000c01, root_entry_next;
    reg [31:0] text_entry_reg = 32'h000000cb, text_entry_next;
    reg [31:0] data_entry_reg = 32'h000004c7, data_entry_next;
    reg [31:0] external_irq_reg = 32'd0, external_irq_next;
    reg software_irq_reg = 1'b0, software_irq_next;
    reg timer_enabled_reg = 1'b0, timer_enabled_next;
    reg timer_pending_reg = 1'b0, timer_pending_next;
    reg [TIMER_WIDTH-1:0] timer_count_reg = {TIMER_WIDTH{1'b0}}, timer_count_next;
    reg protocol_error_reg = 1'b0;
    // Payload has no reset. The first store initializes the whole word, with
    // zero in unselected bytes; one valid bit then covers all four bytes.
    reg [15:0] ram_word_valid_reg = 16'd0;
    wire [31:0] ram_read_data;
    wire [31:0] dbus_read_data;
    reg dbus_decoded_error;
    reg ibus_decoded_error;
    genvar ram_byte;

    wire [31:0] ibus_address;
    wire [31:0] dbus_address;
    wire [31:0] ibus_rom_data;
    wire [31:0] dbus_rom_data;
    wire rom_select_ibus;
    wire rom_read_enable;
    wire dbus_rom_ready;
    wire [9:0] shared_rom_address;
    wire [31:0] shared_rom_data;
    wire ibus_request;
    wire dbus_request;
    wire dbus_accept_write;
    wire dbus_rom_selected;
    wire dbus_ram_selected;
    wire dbus_root_selected;
    wire dbus_leaf_selected;
    wire dbus_mmio_selected;
    wire dbus_uart_selected;
    wire dbus_linux_timer_selected;
    wire [31:0] linux_timer_read_data;
    wire linux_timer_irq;
    wire linux_software_irq;
    wire dbus_access_ready;
    wire uart_tx_full;
    wire [31:0] uart_read_data;
    wire ibus_protocol_valid;
    wire dbus_protocol_valid;

    assign ibus_address = {ibus_adr_i, 2'b00};
    assign dbus_address = {dbus_adr_i, 2'b00};
    assign ibus_request = ibus_cyc_i && ibus_stb_i && !rst;
    assign dbus_request = dbus_cyc_i && dbus_stb_i && !rst;
    // At most one ROM read is accepted per clock; instruction has priority.
    // Its port enters ROM_DATA and captures the synchronous ROM result on
    // the next edge. The other port may issue a ROM read on that edge:
    // nonblocking assignments preserve the previous owner's data correctly.
    // Non-ROM data transactions still proceed independently.
    assign rom_select_ibus = ibus_state_reg == STATE_IDLE && ibus_request;
    assign rom_read_enable = (rom_select_ibus && !ibus_decoded_error) ||
        (dbus_state_reg == STATE_IDLE && dbus_request && dbus_rom_ready &&
         dbus_rom_selected && !dbus_decoded_error);
    assign dbus_rom_ready = !dbus_rom_selected || !rom_select_ibus;
    assign shared_rom_address = rom_select_ibus ? ibus_adr_i[9:0] : dbus_adr_i[9:0];
    assign ibus_rom_data = shared_rom_data;
    assign dbus_rom_data = shared_rom_data;
    assign dbus_rom_selected = dbus_address < 32'h00001000;
    assign dbus_ram_selected = dbus_address >= 32'h00001000 &&
                               dbus_address < 32'h00001040;
    assign dbus_root_selected = dbus_address[31:12] == 20'h00002;
    assign dbus_leaf_selected = dbus_address[31:12] == 20'h00003;
    assign dbus_mmio_selected = dbus_address[31:6] == (32'hf0001000 >> 6);
    assign dbus_uart_selected = dbus_address[31:5] == (32'hf0001100 >> 5);
    assign dbus_linux_timer_selected = dbus_address[31:16] == 16'hf001;
    assign dbus_access_ready = dbus_rom_ready && !(dbus_uart_selected && dbus_we_i &&
        dbus_address[4:0] == 5'd0 && dbus_sel_i[0] && uart_tx_full);
    assign ibus_protocol_valid = ibus_bte_i == 2'd0 && ibus_sel_i == 4'b1111 &&
        (ibus_cti_i == 3'b000 || ibus_cti_i == 3'b010 || ibus_cti_i == 3'b111);
    assign dbus_protocol_valid = dbus_bte_i == 2'd0 && dbus_sel_i != 4'b0000 &&
        (dbus_cti_i == 3'b000 || dbus_cti_i == 3'b010 || dbus_cti_i == 3'b111);
    assign dbus_accept_write = dbus_state_reg == STATE_IDLE && dbus_request &&
                               dbus_we_i && dbus_access_ready && !dbus_decoded_error;
    assign ibus_ack_o = ibus_state_reg == STATE_RESPONSE && ibus_request && !ibus_error_reg;
    assign ibus_err_o = ibus_state_reg == STATE_RESPONSE && ibus_request && ibus_error_reg;
    assign dbus_ack_o = dbus_state_reg == STATE_RESPONSE && dbus_request && !dbus_error_reg;
    assign dbus_err_o = dbus_state_reg == STATE_RESPONSE && dbus_request && dbus_error_reg;
    assign ibus_data_o = ibus_data_reg;
    assign dbus_data_o = dbus_data_reg;
    assign timer_interrupt_o = timer_pending_reg | linux_timer_irq;
    assign software_interrupt_o = software_irq_reg | linux_software_irq;
    assign external_interrupt_array_o = external_irq_reg;
    assign cycle_count_o = cycle_count_reg;
    assign status_o = status_reg;
    assign heartbeat_o = heartbeat_reg;
    assign last_trap_o = last_trap_reg;
    assign result_o = result_reg;
    assign protocol_error_o = protocol_error_reg;
    assign ddr_status_o = ddr_status_reg;
    assign ddr_heartbeat_o = ddr_heartbeat_reg;

    generate
        for (ram_byte = 0; ram_byte < 4; ram_byte = ram_byte + 1) begin : ram_byte_bank
            (* ram_style = "dram" *) reg [7:0] ram_byte_reg [0:15];
            assign ram_read_data[ram_byte * 8 +: 8] =
                ram_word_valid_reg[dbus_adr_i[3:0]] ?
                ram_byte_reg[dbus_adr_i[3:0]] : 8'd0;
            always @(posedge clk) begin
                if (!rst && dbus_accept_write && dbus_ram_selected &&
                    (!ram_word_valid_reg[dbus_adr_i[3:0]] || dbus_sel_i[ram_byte]))
                    ram_byte_reg[dbus_adr_i[3:0]] <=
                        dbus_sel_i[ram_byte] ? dbus_data_i[ram_byte * 8 +: 8] : 8'd0;
            end
        end
    endgenerate

    generate
        if (UART_ENABLE) begin : cpu_uart_enabled
            cpu_uart uart_inst (
                .clk       (clk),
                .rst       (rst),
                .rx_i      (uart_rx_i),
                .tx_o      (uart_tx_o),
                .address_i (dbus_address[4:2]),
                .write_i   (dbus_accept_write && dbus_uart_selected && dbus_sel_i[0]),
                .data_i    (dbus_data_i[7:0]),
                .data_o    (uart_read_data),
                .tx_full_o (uart_tx_full)
            );
        end else begin : cpu_uart_disabled
            assign uart_tx_o = 1'b1;
            assign uart_read_data = dbus_address[4:2] == 3'd2 ? 32'd1 : 32'd0;
            assign uart_tx_full = 1'b0;
        end
    endgenerate

    linux_timer linux_timer_inst (
        .clk (clk),
        .rst (rst),
        .write_i (dbus_accept_write && dbus_linux_timer_selected),
        .address_i (dbus_address[15:0]),
        .data_i (dbus_data_i),
        .select_i (dbus_sel_i),
        .data_o (linux_timer_read_data),
        .timer_interrupt_o (linux_timer_irq),
        .software_interrupt_o (linux_software_irq)
    );

    vexriscv_b_boot_rom shared_rom_inst (
        .clk            (clk),
        .enable_i       (rom_read_enable),
        .word_address_i (shared_rom_address),
        .instruction_o  (shared_rom_data)
    );

    // Parallel, mutually exclusive address selection avoids a region mux cascade.
    assign dbus_read_data =
        ({32{dbus_rom_selected}} & dbus_rom_data) |
        ({32{dbus_ram_selected}} & ram_read_data) |
        ({32{dbus_address == 32'h00002400}} & root_entry_reg) |
        ({32{dbus_address == 32'h00003000}} & text_entry_reg) |
        ({32{dbus_address == 32'h00003004}} & data_entry_reg) |
        ({32{dbus_address == 32'hf0001000}} & status_reg) |
        ({32{dbus_address == 32'hf0001004}} & cycle_count_reg) |
        ({32{dbus_address == 32'hf0001008}} & heartbeat_reg) |
        ({32{dbus_address == 32'hf000100c}} & last_trap_reg) |
        ({32{dbus_address == 32'hf0001010}} & {31'd0, software_irq_reg}) |
        ({32{dbus_address == 32'hf0001014}} & {30'd0, timer_pending_reg, timer_enabled_reg}) |
        ({32{dbus_address == 32'hf0001018}} & external_irq_reg) |
        ({32{dbus_address == 32'hf0001020}} & result_reg) |
        ({32{dbus_address == 32'hf0001024}} & (DDR_BOOT_ENABLE ? {28'd0, (|ddr_errors_i), ddr_busy_i, 1'b1, ddr_ready_i} : 32'd0)) |
        ({32{dbus_address == 32'hf0001028}} & ddr_status_reg) |
        ({32{dbus_address == 32'hf000102c}} & ddr_heartbeat_reg) |
        ({32{dbus_address == 32'hf0001030}} & (DDR_BOOT_ENABLE ? {29'd0, ddr_errors_i} : 32'd0)) |
        ({32{dbus_address == 32'hf0001034}} & 32'h01000000) |
        ({32{dbus_address == 32'hf0001038}} & 32'h40000000) |
        ({32{dbus_address == 32'hf000103c}} & 32'h02000000) |
        ({32{dbus_uart_selected}} & uart_read_data) |
        ({32{dbus_linux_timer_selected}} & linux_timer_read_data);

    always @* begin
        ibus_decoded_error = !ibus_protocol_valid || ibus_we_i ||
                             ibus_address >= 32'h00001000;
        dbus_decoded_error = !dbus_protocol_valid;
        if (dbus_rom_selected) begin
            if (dbus_we_i) dbus_decoded_error = 1'b1;
        end else if (dbus_ram_selected) begin
            // Both reads and writes are legal; protocol/SEL was checked above.
        end else if (dbus_root_selected) begin
            if (dbus_address != 32'h00002400 && dbus_we_i)
                dbus_decoded_error = 1'b1;
        end else if (dbus_leaf_selected) begin
            case (dbus_address)
                32'h00003000, 32'h00003004: ;
                default: if (dbus_we_i) dbus_decoded_error = 1'b1;
            endcase
        end else if (dbus_linux_timer_selected) begin
            case (dbus_address[15:0])
                16'h0000, 16'h4000, 16'h4004, 16'hbff8, 16'hbffc: ;
                default: dbus_decoded_error = 1'b1;
            endcase
        end else if (dbus_uart_selected) begin
            if (dbus_we_i && dbus_address[4:2] != 3'd0 &&
                dbus_address[4:2] != 3'd4 && dbus_address[4:2] != 3'd5 &&
                dbus_address[4:2] != 3'd6) dbus_decoded_error = 1'b1;
        end else if (dbus_mmio_selected) begin
            case (dbus_address[5:0])
                6'h00, 6'h08, 6'h0c, 6'h10, 6'h14, 6'h18,
                6'h20, 6'h28, 6'h2c: ;
                6'h04, 6'h24, 6'h30, 6'h34, 6'h38, 6'h3c:
                    if (dbus_we_i) dbus_decoded_error = 1'b1;
                default: dbus_decoded_error = 1'b1;
            endcase
        end else begin
            dbus_decoded_error = 1'b1;
        end
    end

    always @* begin
        ibus_state_next = ibus_state_reg;
        dbus_state_next = dbus_state_reg;
        ibus_wait_next = ibus_wait_reg;
        dbus_wait_next = dbus_wait_reg;
        case (ibus_state_reg)
            STATE_IDLE: begin
                if (ibus_request) begin
                    ibus_wait_next = BEAT_WAIT;
                    if (!ibus_decoded_error) ibus_state_next = STATE_ROM_DATA;
                    else ibus_state_next = (WAIT_CYCLES == 0) ? STATE_RESPONSE : STATE_WAIT;
                end
            end
            STATE_ROM_DATA: begin
                if (!ibus_request) ibus_state_next = STATE_IDLE;
                else ibus_state_next = (WAIT_CYCLES == 0) ? STATE_RESPONSE : STATE_WAIT;
            end
            STATE_WAIT: begin
                if (!ibus_request) ibus_state_next = STATE_IDLE;
                else if (ibus_wait_reg <= 8'd1) ibus_state_next = STATE_RESPONSE;
                else ibus_wait_next = ibus_wait_reg - 8'd1;
            end
            STATE_RESPONSE: ibus_state_next = STATE_IDLE;
            default: ibus_state_next = STATE_IDLE;
        endcase
        case (dbus_state_reg)
            STATE_IDLE: begin
                if (dbus_request && dbus_access_ready) begin
                    dbus_wait_next = BEAT_WAIT;
                    if (dbus_rom_selected && !dbus_decoded_error)
                        dbus_state_next = STATE_ROM_DATA;
                    else dbus_state_next = (WAIT_CYCLES == 0) ? STATE_RESPONSE : STATE_WAIT;
                end
            end
            STATE_ROM_DATA: begin
                if (!dbus_request) dbus_state_next = STATE_IDLE;
                else dbus_state_next = (WAIT_CYCLES == 0) ? STATE_RESPONSE : STATE_WAIT;
            end
            STATE_WAIT: begin
                if (!dbus_request) dbus_state_next = STATE_IDLE;
                else if (dbus_wait_reg <= 8'd1) dbus_state_next = STATE_RESPONSE;
                else dbus_wait_next = dbus_wait_reg - 8'd1;
            end
            STATE_RESPONSE: dbus_state_next = STATE_IDLE;
            default: dbus_state_next = STATE_IDLE;
        endcase
    end

    always @* begin
        status_next = status_reg;
        heartbeat_next = heartbeat_reg;
        last_trap_next = last_trap_reg;
        result_next = result_reg;
        ddr_status_next = ddr_status_reg;
        ddr_heartbeat_next = ddr_heartbeat_reg;
        root_entry_next = root_entry_reg;
        text_entry_next = text_entry_reg;
        data_entry_next = data_entry_reg;
        external_irq_next = external_irq_reg;
        software_irq_next = software_irq_reg;
        timer_enabled_next = timer_enabled_reg;
        timer_pending_next = timer_pending_reg;
        timer_count_next = timer_count_reg;
        if (timer_enabled_reg) begin
            if (timer_count_reg == TIMER_LAST_CYCLE) begin
                timer_count_next = 32'd0;
                timer_pending_next = 1'b1;
            end else begin
                timer_count_next = timer_count_reg + 32'd1;
            end
        end
        if (dbus_accept_write) begin
            case (dbus_address)
                32'h00002400: begin
                    if (dbus_sel_i[0]) root_entry_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) root_entry_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) root_entry_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) root_entry_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                32'h00003000: begin
                    if (dbus_sel_i[0]) text_entry_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) text_entry_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) text_entry_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) text_entry_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                32'h00003004: begin
                    if (dbus_sel_i[0]) data_entry_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) data_entry_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) data_entry_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) data_entry_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                32'hf0001000: begin
                    if (dbus_sel_i[0]) status_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) status_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) status_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) status_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                32'hf0001008: begin
                    if (dbus_sel_i[0]) heartbeat_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) heartbeat_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) heartbeat_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) heartbeat_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                32'hf000100c: begin
                    if (dbus_sel_i[0]) last_trap_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) last_trap_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) last_trap_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) last_trap_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                32'hf0001010: begin
                    if (dbus_sel_i[0]) software_irq_next = dbus_data_i[0];
                end
                32'hf0001014: begin
                    if (dbus_sel_i[0]) begin
                        timer_enabled_next = dbus_data_i[0];
                        timer_pending_next = 1'b0;
                        timer_count_next = 32'd0;
                    end
                end
                32'hf0001018: begin
                    if (dbus_sel_i[0]) external_irq_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) external_irq_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) external_irq_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) external_irq_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                32'hf0001020: begin
                    if (dbus_sel_i[0]) result_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) result_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) result_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) result_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                32'hf0001028: begin
                    if (dbus_sel_i[0]) ddr_status_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) ddr_status_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) ddr_status_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) ddr_status_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                32'hf000102c: begin
                    if (dbus_sel_i[0]) ddr_heartbeat_next[0 +: 8] = dbus_data_i[0 +: 8];
                    if (dbus_sel_i[1]) ddr_heartbeat_next[8 +: 8] = dbus_data_i[8 +: 8];
                    if (dbus_sel_i[2]) ddr_heartbeat_next[16 +: 8] = dbus_data_i[16 +: 8];
                    if (dbus_sel_i[3]) ddr_heartbeat_next[24 +: 8] = dbus_data_i[24 +: 8];
                end
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        ibus_state_reg <= ibus_state_next;
        dbus_state_reg <= dbus_state_next;
        ibus_wait_reg <= ibus_wait_next;
        dbus_wait_reg <= dbus_wait_next;
        if (ibus_state_reg == STATE_IDLE && ibus_request) begin
            // For a valid ROM request the data is available one edge later.
            ibus_data_reg <= 32'd0;
            ibus_error_reg <= ibus_decoded_error;
        end
        if (ibus_state_reg == STATE_ROM_DATA && ibus_request)
            ibus_data_reg <= ibus_rom_data;
        if (dbus_state_reg == STATE_IDLE && dbus_request && dbus_access_ready) begin
            if (!dbus_rom_selected || dbus_decoded_error)
                dbus_data_reg <= dbus_read_data;
            dbus_error_reg <= dbus_decoded_error;
        end
        if (dbus_state_reg == STATE_ROM_DATA && dbus_request)
            dbus_data_reg <= dbus_rom_data;
        if (ibus_state_reg == STATE_IDLE && ibus_request && ibus_decoded_error)
            protocol_error_reg <= 1'b1;
        if (dbus_state_reg == STATE_IDLE && dbus_request && dbus_decoded_error)
            protocol_error_reg <= 1'b1;
        cycle_count_reg <= cycle_count_reg + 32'd1;
        status_reg <= status_next;
        heartbeat_reg <= heartbeat_next;
        last_trap_reg <= last_trap_next;
        result_reg <= result_next;
        ddr_status_reg <= ddr_status_next;
        ddr_heartbeat_reg <= ddr_heartbeat_next;
        root_entry_reg <= root_entry_next;
        text_entry_reg <= text_entry_next;
        data_entry_reg <= data_entry_next;
        external_irq_reg <= external_irq_next;
        software_irq_reg <= software_irq_next;
        timer_enabled_reg <= timer_enabled_next;
        timer_pending_reg <= timer_pending_next;
        timer_count_reg <= timer_count_next;
        if (dbus_accept_write && dbus_ram_selected)
            ram_word_valid_reg[dbus_adr_i[3:0]] <= 1'b1;
        if (rst) begin
            ibus_state_reg <= STATE_IDLE;
            dbus_state_reg <= STATE_IDLE;
            ibus_wait_reg <= {WAIT_WIDTH{1'b0}};
            dbus_wait_reg <= {WAIT_WIDTH{1'b0}};
            ibus_data_reg <= 32'd0;
            dbus_data_reg <= 32'd0;
            ibus_error_reg <= 1'b0;
            dbus_error_reg <= 1'b0;
            protocol_error_reg <= 1'b0;
            cycle_count_reg <= 32'd0;
            status_reg <= 32'd0;
            heartbeat_reg <= 32'd0;
            last_trap_reg <= 32'd0;
            result_reg <= 32'd0;
            ddr_status_reg <= 32'd0;
            ddr_heartbeat_reg <= 32'd0;
            root_entry_reg <= 32'h00000c01;
            text_entry_reg <= 32'h000000cb;
            data_entry_reg <= 32'h000004c7;
            external_irq_reg <= 32'd0;
            software_irq_reg <= 1'b0;
            timer_enabled_reg <= 1'b0;
            timer_pending_reg <= 1'b0;
            timer_count_reg <= {TIMER_WIDTH{1'b0}};
            ram_word_valid_reg <= 16'd0;
        end
    end
endmodule
`resetall
