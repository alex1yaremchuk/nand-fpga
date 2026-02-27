`include "project_config.vh"

module top(
    input  wire Clock,
    input  wire s0,
    input  wire s1,
    input  wire s2,
    input  wire s3,
    input  wire s4,
    output reg  led,
    output wire tm_stb,
    output wire tm_clk,
    inout  wire tm_dio
`ifdef CFG_ENABLE_UART_BRIDGE
    ,
    input  wire uart_rx,
    output wire uart_tx
`endif
);

    localparam integer CLK_HZ = 27_000_000;
    localparam integer POLL_CYCLES = 540_000; // 20 ms
    localparam integer DATA_W = `DATA_W;
    localparam integer ADDR_W = 15;
    localparam integer ROM_ADDR_W = `CFG_ROM_ADDR_W;
    localparam integer HEX_DIGITS = (DATA_W + 3) / 4;
    localparam integer TICKS_PER_MS = (CLK_HZ / 1000);
    localparam integer MS_W = (TICKS_PER_MS <= 2) ? 2 : $clog2(TICKS_PER_MS);

    localparam [1:0] PAGE_ROM   = 2'd0;
    localparam [1:0] PAGE_CPU   = 2'd1;
    localparam [1:0] PAGE_MEM   = 2'd2;
    localparam [1:0] PAGE_STATE = 2'd3;

    localparam integer MEMMAP_RAM16K_USE_BRAM = `CFG_RAM16K_USE_BRAM;
    localparam integer MEMMAP_RAM16K_RAM4K_USE_BRAM = `CFG_RAM16K_RAM4K_USE_BRAM;
    localparam integer MEMMAP_USE_SCREEN_BRAM = `CFG_USE_SCREEN_BRAM;
    localparam integer MEMMAP_SCREEN_ADDR_W = `CFG_SCREEN_ADDR_W;

    reg [1:0] page = PAGE_ROM;
    reg [1:0] edit_nibble = 2'd0;
    reg [DATA_W-1:0] edit_word = {DATA_W{1'b0}};
    reg [ADDR_W-1:0] edit_addr = {ADDR_W{1'b0}};

    reg rom_prog_we = 1'b0;
    reg [ADDR_W-1:0] rom_prog_addr = {ADDR_W{1'b0}};
    reg [DATA_W-1:0] rom_prog_data = {DATA_W{1'b0}};

    reg mem_ui_we = 1'b0;
    reg [DATA_W-1:0] mem_ui_data = {DATA_W{1'b0}};

    reg cpu_step_req = 1'b0;
    reg cpu_run = 1'b0;
    reg cpu_reset_req = 1'b0;

    wire [DATA_W-1:0] cpu_outM;
    wire cpu_writeM;
    wire [ADDR_W-1:0] cpu_addressM;
    wire [ADDR_W-1:0] cpu_pc;
    wire [ADDR_W-1:0] cpu_a_dbg;
    wire [DATA_W-1:0] cpu_d_dbg;

    wire [DATA_W-1:0] mem_q;
    wire [DATA_W-1:0] rom_instr;

`ifdef CFG_ENABLE_UART_BRIDGE
    wire uart_cpu_step_pulse;
    wire uart_cpu_reset_pulse;
    wire uart_cpu_run_set;
    wire uart_cpu_run_clr;

    wire uart_mem_req;
    wire uart_mem_we;
    wire [ADDR_W-1:0] uart_mem_addr;
    wire [DATA_W-1:0] uart_mem_data;

    wire uart_rom_we;
    wire uart_rom_rd_req;
    wire [ADDR_W-1:0] uart_rom_addr;
    wire [DATA_W-1:0] uart_rom_data;

    wire uart_kbd_we;
    wire [DATA_W-1:0] uart_kbd_data;

    reg [DATA_W-1:0] kbd_uart_word = {DATA_W{1'b0}};
    wire uart_bridge_rst = cpu_reset_req;
`endif

`ifdef CFG_ENABLE_UART_BRIDGE
    wire cpu_step = cpu_run_en | cpu_step_req | uart_cpu_step_pulse;
    wire cpu_reset = cpu_reset_req | uart_cpu_reset_pulse;
    wire uart_activity = uart_cpu_step_pulse | uart_cpu_reset_pulse |
                         uart_mem_req | uart_rom_we | uart_rom_rd_req |
                         uart_kbd_we | uart_cpu_run_set | uart_cpu_run_clr;
`else
    wire cpu_step = cpu_run_en | cpu_step_req;
    wire cpu_reset = cpu_reset_req;
    wire uart_activity = 1'b0;
`endif

    wire cpu_run_en = cpu_run & (page == PAGE_CPU);

    wire mem_use_cpu = (page == PAGE_CPU);
`ifdef CFG_ENABLE_UART_BRIDGE
    wire mem_use_uart = uart_mem_req;
    wire mem_load = mem_use_uart ? uart_mem_we :
                    (mem_use_cpu ? cpu_writeM : mem_ui_we);
    wire [ADDR_W-1:0] mem_addr = mem_use_uart ? uart_mem_addr :
                                 (mem_use_cpu ? cpu_addressM : edit_addr);
    wire [DATA_W-1:0] mem_d = mem_use_uart ? uart_mem_data :
                              (mem_use_cpu ? cpu_outM : mem_ui_data);
`else
    wire mem_load = mem_use_cpu ? cpu_writeM : mem_ui_we;
    wire [ADDR_W-1:0] mem_addr = mem_use_cpu ? cpu_addressM : edit_addr;
    wire [DATA_W-1:0] mem_d = mem_use_cpu ? cpu_outM : mem_ui_data;
`endif

`ifdef CFG_ENABLE_UART_BRIDGE
    wire rom_prog_we_eff = uart_rom_we ? 1'b1 : rom_prog_we;
    wire [ADDR_W-1:0] rom_prog_addr_eff = uart_rom_we ? uart_rom_addr : rom_prog_addr;
    wire [DATA_W-1:0] rom_prog_data_eff = uart_rom_we ? uart_rom_data : rom_prog_data;
    wire [ADDR_W-1:0] rom_read_addr = uart_rom_rd_req ? uart_rom_addr :
                                      ((page == PAGE_ROM) ? edit_addr : cpu_pc);
`else
    wire [ADDR_W-1:0] rom_read_addr = (page == PAGE_ROM) ? edit_addr : cpu_pc;
    wire rom_prog_we_eff = rom_prog_we;
    wire [ADDR_W-1:0] rom_prog_addr_eff = rom_prog_addr;
    wire [DATA_W-1:0] rom_prog_data_eff = rom_prog_data;
`endif

    reg [DATA_W-1:0] lhs_val = {DATA_W{1'b0}};
    reg [DATA_W-1:0] rhs_val = {DATA_W{1'b0}};

    reg [127:0] frame_data = 128'h0;
    reg [63:0] disp_digits = 64'h0;
    reg [7:0] disp_leds = 8'h00;

    // TM1638 TX/RX arbitration
    wire tx_busy;
    wire tx_dio_oe;
    wire tx_dio_out;
    wire tx_stb;
    wire tx_sclk;

    wire rx_busy;
    wire rx_done;
    wire [31:0] rx_keys;
    reg rx_start = 1'b0;
    reg rx_active = 1'b0;
    wire rx_dio_oe;
    wire rx_dio_out;
    wire rx_stb;
    wire rx_sclk;

    wire sel_rx = rx_active | rx_busy;
    wire dio_oe = sel_rx ? rx_dio_oe : tx_dio_oe;
    wire dio_out = sel_rx ? rx_dio_out : tx_dio_out;
    wire tm_dio_in = tm_dio;

    assign tm_dio = dio_oe ? dio_out : 1'bz;
    assign tm_stb = sel_rx ? rx_stb : tx_stb;
    assign tm_clk = sel_rx ? rx_sclk : tx_sclk;

    // 1 ms sampling tick for board button debounce
    reg [MS_W-1:0] ms_div = 0;
    reg tick_1ms = 1'b0;

    // Board buttons are active-low: {s4,s3,s2,s1,s0}
    wire [4:0] board_level = ~{s4, s3, s2, s1, s0};
    wire [4:0] board_stable;
    wire [4:0] board_press;

    // TM1638 decoded/ordered buttons and edge detect
    wire [7:0] tm_buttons;
    reg [7:0] tm_prev = 8'h00;
    wire [7:0] tm_edge = tm_buttons & ~tm_prev;
`ifdef CFG_ENABLE_UART_BRIDGE
    wire [DATA_W-1:0] kbd_word = kbd_uart_word;
`else
    wire [DATA_W-1:0] kbd_word = {{(DATA_W-8){1'b0}}, tm_buttons};
`endif

    reg [21:0] key_poll_div = 0;
    integer i;

    function [7:0] hex7seg;
        input [3:0] v;
        begin
            case (v)
                4'h0: hex7seg = 8'b00111111;
                4'h1: hex7seg = 8'b00000110;
                4'h2: hex7seg = 8'b01011011;
                4'h3: hex7seg = 8'b01001111;
                4'h4: hex7seg = 8'b01100110;
                4'h5: hex7seg = 8'b01101101;
                4'h6: hex7seg = 8'b01111101;
                4'h7: hex7seg = 8'b00000111;
                4'h8: hex7seg = 8'b01111111;
                4'h9: hex7seg = 8'b01101111;
                4'hA: hex7seg = 8'b01110111;
                4'hB: hex7seg = 8'b01111100;
                4'hC: hex7seg = 8'b00111001;
                4'hD: hex7seg = 8'b01011110;
                4'hE: hex7seg = 8'b01111001;
                4'hF: hex7seg = 8'b01110001;
            endcase
        end
    endfunction

    panel_mapper u_map (
        .keys_raw(rx_keys),
        .buttons(tm_buttons)
    );

    key_debounce #(
        .WIDTH(5)
    ) u_board_keys (
        .clk(Clock),
        .sample_tick(tick_1ms),
        .keys_level(board_level),
        .stable_level(board_stable),
        .press_pulse(board_press)
    );

    tm1638_tx #(
        .CLK_HZ(CLK_HZ),
        .BIT_HZ(100_000),
        .REFRESH_HZ(40)
    ) u_tx (
        .clk(Clock),
        .enable(!rx_active),
        .frame_data(frame_data),
        .brightness(3'd7),
        .display_on(1'b1),
        .stb(tx_stb),
        .sclk(tx_sclk),
        .dio_oe(tx_dio_oe),
        .dio_out(tx_dio_out),
        .busy(tx_busy)
    );

    tm1638_rx #(
        .CLK_HZ(CLK_HZ),
        .BIT_HZ(100_000)
    ) u_rx (
        .clk(Clock),
        .start(rx_start),
        .dio_in(tm_dio_in),
        .stb(rx_stb),
        .sclk(rx_sclk),
        .dio_oe(rx_dio_oe),
        .dio_out(rx_dio_out),
        .busy(rx_busy),
        .done(rx_done),
        .keys(rx_keys)
    );

`ifdef CFG_ENABLE_UART_BRIDGE
    uart_bridge #(
        .CLK_HZ(CLK_HZ),
        .BAUD(`CFG_UART_BAUD),
        .DATA_W(DATA_W),
        .ADDR_W(ADDR_W),
        .SCREEN_ADDR_W(MEMMAP_SCREEN_ADDR_W)
    ) u_uart_bridge (
        .clk(Clock),
        .rst(uart_bridge_rst),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .cpu_pc(cpu_pc),
        .cpu_a(cpu_a_dbg),
        .cpu_d(cpu_d_dbg),
        .cpu_run_en(cpu_run_en),
        .cpu_step_pulse(uart_cpu_step_pulse),
        .cpu_reset_pulse(uart_cpu_reset_pulse),
        .cpu_run_set(uart_cpu_run_set),
        .cpu_run_clr(uart_cpu_run_clr),
        .mem_req(uart_mem_req),
        .mem_we(uart_mem_we),
        .mem_addr(uart_mem_addr),
        .mem_wdata(uart_mem_data),
        .mem_rdata(mem_q),
        .rom_we(uart_rom_we),
        .rom_rd_req(uart_rom_rd_req),
        .rom_addr(uart_rom_addr),
        .rom_wdata(uart_rom_data),
        .rom_rdata(rom_instr),
        .kbd_we(uart_kbd_we),
        .kbd_data(uart_kbd_data)
    );
`endif

    memory_map #(
        .WIDTH(DATA_W),
        .RAM16K_USE_BRAM(MEMMAP_RAM16K_USE_BRAM),
        .RAM16K_RAM4K_USE_BRAM(MEMMAP_RAM16K_RAM4K_USE_BRAM),
        .USE_SCREEN_BRAM(MEMMAP_USE_SCREEN_BRAM),
        .SCREEN_ADDR_W(MEMMAP_SCREEN_ADDR_W)
    ) u_mem (
        .clk(Clock),
        .load(mem_load),
        .addr(mem_addr),
        .d(mem_d),
        .kbd_in(kbd_word),
        .q(mem_q)
    );

    rom32k_prog #(
        .WIDTH(DATA_W),
        .ROM_ADDR_W(ROM_ADDR_W)
    ) u_rom (
        .clk(Clock),
        .prog_we(rom_prog_we_eff),
        .prog_addr(rom_prog_addr_eff),
        .prog_data(rom_prog_data_eff),
        .rd_addr(rom_read_addr),
        .q(rom_instr)
    );

    cpu_core #(
        .DATA_W(DATA_W),
        .ADDR_W(ADDR_W)
    ) u_cpu (
        .clk(Clock),
        .reset(cpu_reset),
        .step(cpu_step),
        .instr(rom_instr),
        .inM(mem_q),
        .outM(cpu_outM),
        .writeM(cpu_writeM),
        .addressM(cpu_addressM),
        .pc(cpu_pc),
        .a_dbg(cpu_a_dbg),
        .d_dbg(cpu_d_dbg)
    );

    always @(*) begin
        case (page)
            PAGE_ROM: begin
                lhs_val = edit_word;
                rhs_val = {{(DATA_W-ADDR_W){1'b0}}, edit_addr};
            end
            PAGE_CPU: begin
                lhs_val = {{(DATA_W-ADDR_W){1'b0}}, cpu_a_dbg};
                rhs_val = cpu_d_dbg;
            end
            PAGE_MEM: begin
                lhs_val = edit_word;
                rhs_val = mem_q;
            end
            default: begin
                lhs_val = rom_instr;
                rhs_val = {{(DATA_W-ADDR_W){1'b0}}, cpu_pc};
            end
        endcase
    end

    // Build 8 digit bytes.
    always @(*) begin
        disp_digits = 64'h0;
        for (i = 0; i < HEX_DIGITS; i = i + 1) begin
            if (i < 8) begin
                disp_digits[i*8 +: 8] = hex7seg(lhs_val[i*4 +: 4]);
            end
            if ((i + HEX_DIGITS) < 8) begin
                disp_digits[(i + HEX_DIGITS)*8 +: 8] = hex7seg(rhs_val[i*4 +: 4]);
            end
        end
    end

    // Build LED bytes.
    always @(*) begin
        disp_leds = 8'h00;
        disp_leds[page] = 1'b1;
        disp_leds[4 + edit_nibble] = 1'b1;

        if (page == PAGE_CPU) begin
            disp_leds[6] = cpu_writeM;
            disp_leds[7] = cpu_run_en;
        end
    end

    // Pack 8 digits + 8 leds to TM1638 RAM image.
    always @(*) begin
        frame_data = 128'h0;
        for (i = 0; i < 8; i = i + 1) begin
            frame_data[(i*2)*8 +: 8] = disp_digits[i*8 +: 8];
            frame_data[(i*2 + 1)*8 +: 8] = disp_leds[i] ? 8'h01 : 8'h00;
        end
    end

    always @(posedge Clock) begin
        rx_start <= 1'b0;
        rom_prog_we <= 1'b0;
        mem_ui_we <= 1'b0;
        cpu_step_req <= 1'b0;
        cpu_reset_req <= 1'b0;

`ifdef CFG_ENABLE_UART_BRIDGE
        if (uart_kbd_we) begin
            kbd_uart_word <= uart_kbd_data;
        end
        if (uart_cpu_run_set) begin
            cpu_run <= 1'b1;
        end
        if (uart_cpu_run_clr) begin
            cpu_run <= 1'b0;
        end
        // UART bridge expects CPU-owned buses. Force PAGE_CPU while bridge is active.
        if (uart_cpu_step_pulse | uart_cpu_reset_pulse | uart_mem_req | uart_rom_we | uart_rom_rd_req | uart_kbd_we) begin
            page <= PAGE_CPU;
        end
`endif

        if (ms_div == TICKS_PER_MS - 1) begin
            ms_div <= 0;
            tick_1ms <= 1'b1;
        end else begin
            ms_div <= ms_div + 1'b1;
            tick_1ms <= 1'b0;
        end

        // Poll TM keys every 20 ms.
        if (key_poll_div == POLL_CYCLES - 1) begin
            key_poll_div <= 0;
            if (!rx_active && !rx_busy && !tx_busy) begin
                rx_start <= 1'b1;
                rx_active <= 1'b1;
            end
        end else begin
            key_poll_div <= key_poll_div + 1'b1;
        end

        // TM1638 controls (on press edge).
        // Ignore local panel input while UART bridge is actively driving control flow.
        if (rx_done && !uart_activity) begin
            rx_active <= 1'b0;

            if (tm_edge[0]) begin // selected nibble++
                case (edit_nibble)
                    2'd0: edit_word[3:0] <= edit_word[3:0] + 1'b1;
                    2'd1: edit_word[7:4] <= edit_word[7:4] + 1'b1;
                    2'd2: edit_word[11:8] <= edit_word[11:8] + 1'b1;
                    default: edit_word[15:12] <= edit_word[15:12] + 1'b1;
                endcase
            end

            if (tm_edge[1]) begin // selected nibble--
                case (edit_nibble)
                    2'd0: edit_word[3:0] <= edit_word[3:0] - 1'b1;
                    2'd1: edit_word[7:4] <= edit_word[7:4] - 1'b1;
                    2'd2: edit_word[11:8] <= edit_word[11:8] - 1'b1;
                    default: edit_word[15:12] <= edit_word[15:12] - 1'b1;
                endcase
            end

            if (page == PAGE_CPU) begin
                if (tm_edge[4]) cpu_run <= ~cpu_run; // run/pause
            end else begin
                if (tm_edge[4]) edit_nibble <= edit_nibble + 1'b1; // cursor++
                if (tm_edge[5]) edit_nibble <= edit_nibble - 1'b1; // cursor--
            end

            if (tm_edge[7]) begin // page cycle
                if (page == PAGE_CPU) begin
                    cpu_run <= 1'b0;
                end
                page <= page + 1'b1;
            end

            if (page == PAGE_ROM) begin
                if (tm_edge[2]) begin // ROM[addr] <= word
                    rom_prog_we <= 1'b1;
                    rom_prog_addr <= edit_addr;
                    rom_prog_data <= edit_word;
                    edit_addr <= edit_addr + 1'b1;
                end
                if (tm_edge[3]) begin
                    cpu_reset_req <= 1'b1;
                    cpu_run <= 1'b0;
                end
            end else if (page == PAGE_CPU) begin
                if (tm_edge[2]) cpu_step_req <= 1'b1;
                if (tm_edge[3]) begin
                    cpu_reset_req <= 1'b1;
                    cpu_run <= 1'b0;
                end
            end else if (page == PAGE_MEM) begin
                if (tm_edge[2]) begin // MEM[addr] <= word
                    mem_ui_we <= 1'b1;
                    mem_ui_data <= edit_word;
                end
                if (tm_edge[3]) begin // word <= MEM[addr]
                    edit_word <= mem_q;
                end
            end else begin
                if (tm_edge[2]) edit_word <= rom_instr;
                if (tm_edge[3]) edit_addr <= cpu_pc;
            end

            if (tm_edge[6]) begin // global reset
                page <= PAGE_ROM;
                edit_nibble <= 2'd0;
                edit_word <= {DATA_W{1'b0}};
                edit_addr <= {ADDR_W{1'b0}};
                cpu_reset_req <= 1'b1;
                cpu_run <= 1'b0;
            end

            if (|tm_edge) led <= ~led;
            tm_prev <= tm_buttons;
        end

        // Board controls (debounced press pulse).
        if (!uart_activity) begin
            if (board_press[0]) begin
                edit_addr <= edit_addr + 1'b1;
                led <= ~led;
            end

            if (board_press[1]) begin
                edit_addr <= edit_addr - 1'b1;
                led <= ~led;
            end

            if (board_press[2]) begin
                if (page == PAGE_CPU) begin
                    cpu_run <= ~cpu_run; // run/pause shortcut
                end else begin
                    edit_addr <= edit_addr + 15'h0100;
                end
                led <= ~led;
            end

            if (board_press[3]) begin
                if (page == PAGE_CPU) begin
                    cpu_run <= 1'b0;
                end
                page <= page + 1'b1;
                led <= ~led;
            end

            if (board_press[4]) begin
                page <= PAGE_ROM;
                edit_nibble <= 2'd0;
                edit_word <= {DATA_W{1'b0}};
                edit_addr <= {ADDR_W{1'b0}};
                cpu_reset_req <= 1'b1;
                cpu_run <= 1'b0;
                led <= ~led;
            end
        end
    end

endmodule
