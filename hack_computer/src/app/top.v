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
);

    localparam integer CLK_HZ = 27_000_000;
    localparam integer POLL_CYCLES = 540_000; // 20 ms
    localparam integer DATA_W = `DATA_W;
    localparam integer HEX_DIGITS = (DATA_W + 3) / 4;
    localparam integer TICKS_PER_MS = (CLK_HZ / 1000);
    localparam integer MS_W = (TICKS_PER_MS <= 2) ? 2 : $clog2(TICKS_PER_MS);

    localparam [2:0] MODE_ALU    = 3'd0;
    localparam [2:0] MODE_REG    = 3'd1;
    localparam [2:0] MODE_RAM8   = 3'd2;
    localparam [2:0] MODE_RAM64  = 3'd3;
    localparam [2:0] MODE_RAM512 = 3'd4;
    localparam [2:0] MODE_BRAM   = 3'd5;
    localparam [2:0] MODE_RAM4K  = 3'd6;
    localparam [2:0] MODE_MEMMAP = 3'd7;
    localparam integer RAM4K_USE_BRAM = 1;
    localparam integer MEMMAP_RAM16K_USE_BRAM = 1;
    localparam integer MEMMAP_RAM16K_RAM4K_USE_BRAM = 1;

    reg [2:0] view_mode = MODE_ALU;

    reg [DATA_W-1:0] op_a = 0;
    reg [DATA_W-1:0] op_b = 0;
    reg [3:0] op_sel = 0;

    wire [DATA_W-1:0] alu_y;
    wire alu_zr;
    wire alu_ng;
    wire alu_carry;
    wire alu_ovf;

    reg [DATA_W-1:0] mem_reg_d = 0;
    reg mem_reg_load = 1'b0;
    wire [DATA_W-1:0] mem_reg_q;

    reg [DATA_W-1:0] ram8_d = 0;
    reg ram8_load = 1'b0;
    reg [2:0] ram8_addr = 0;
    wire [DATA_W-1:0] ram8_q;

    reg [DATA_W-1:0] ram64_d = 0;
    reg ram64_load = 1'b0;
    reg [5:0] ram64_addr = 0;
    wire [DATA_W-1:0] ram64_q;

    reg [DATA_W-1:0] ram512_d = 0;
    reg ram512_load = 1'b0;
    reg [8:0] ram512_addr = 0;
    wire [DATA_W-1:0] ram512_q;

    reg [DATA_W-1:0] ram_bram_d = 0;
    reg ram_bram_load = 1'b0;
    reg [8:0] ram_bram_addr = 0;
    wire [DATA_W-1:0] ram_bram_q;

    reg [DATA_W-1:0] ram4k_d = 0;
    reg ram4k_load = 1'b0;
    reg [11:0] ram4k_addr = 0;
    wire [DATA_W-1:0] ram4k_q;

    reg [DATA_W-1:0] memmap_d = 0;
    reg memmap_load = 1'b0;
    reg [14:0] memmap_addr = 0;
    wire [DATA_W-1:0] memmap_q;

    wire [DATA_W-1:0] rhs_val =
        (view_mode == MODE_REG)    ? mem_reg_q :
        (view_mode == MODE_RAM8)   ? ram8_q :
        (view_mode == MODE_RAM64)  ? ram64_q :
        (view_mode == MODE_RAM512) ? ram512_q :
        (view_mode == MODE_BRAM)   ? ram_bram_q :
        (view_mode == MODE_RAM4K)  ? ram4k_q :
        (view_mode == MODE_MEMMAP) ? memmap_q :
                                      alu_y;

    reg [127:0] frame_data = 0;
    reg [63:0] disp_digits = 0;
    reg [7:0] disp_leds = 0;

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
    reg  [7:0] tm_prev = 0;
    wire [7:0] tm_edge = tm_buttons & ~tm_prev;
    wire [DATA_W-1:0] kbd_word = {{(DATA_W-8){1'b0}}, tm_buttons};

    reg [21:0] key_poll_div = 0;

    integer i;

    function [2:0] mode_next;
        input [2:0] mode_cur;
        begin
            case (mode_cur)
                MODE_ALU:    mode_next = MODE_REG;
                MODE_REG:    mode_next = MODE_RAM8;
                MODE_RAM8:   mode_next = MODE_RAM64;
                MODE_RAM64:  mode_next = MODE_RAM512;
                MODE_RAM512: mode_next = MODE_BRAM;
                MODE_BRAM:   mode_next = MODE_RAM4K;
                MODE_RAM4K:  mode_next = MODE_MEMMAP;
                MODE_MEMMAP: mode_next = MODE_ALU;
                default:     mode_next = MODE_ALU;
            endcase
        end
    endfunction

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

    alu_core #(
        .DATA_W(DATA_W)
    ) u_alu (
        .a(op_a),
        .b(op_b),
        .op(op_sel),
        .y(alu_y),
        .carry_out(alu_carry),
        .overflow(alu_ovf),
        .zr(alu_zr),
        .ng(alu_ng)
    );

    register_n #(
        .WIDTH(DATA_W)
    ) u_reg_mem_stage1 (
        .clk(Clock),
        .load(mem_reg_load),
        .d(mem_reg_d),
        .q(mem_reg_q)
    );

    ram8_struct #(
        .WIDTH(DATA_W)
    ) u_ram8_stage2 (
        .clk(Clock),
        .load(ram8_load),
        .addr(ram8_addr),
        .d(ram8_d),
        .q(ram8_q)
    );

    ram64_struct #(
        .WIDTH(DATA_W)
    ) u_ram64_stage3 (
        .clk(Clock),
        .load(ram64_load),
        .addr(ram64_addr),
        .d(ram64_d),
        .q(ram64_q)
    );

    ram512_struct #(
        .WIDTH(DATA_W)
    ) u_ram512_stage4 (
        .clk(Clock),
        .load(ram512_load),
        .addr(ram512_addr),
        .d(ram512_d),
        .q(ram512_q)
    );

    ram_bram #(
        .WIDTH(DATA_W),
        .ADDR_W(9)
    ) u_ram_bram_stage5 (
        .clk(Clock),
        .load(ram_bram_load),
        .addr(ram_bram_addr),
        .d(ram_bram_d),
        .q(ram_bram_q)
    );

    ram4k_select #(
        .WIDTH(DATA_W),
        .USE_BRAM(RAM4K_USE_BRAM)
    ) u_ram4k_stage6 (
        .clk(Clock),
        .load(ram4k_load),
        .addr(ram4k_addr),
        .d(ram4k_d),
        .q(ram4k_q)
    );

    memory_map #(
        .WIDTH(DATA_W),
        .RAM16K_USE_BRAM(MEMMAP_RAM16K_USE_BRAM),
        .RAM16K_RAM4K_USE_BRAM(MEMMAP_RAM16K_RAM4K_USE_BRAM)
    ) u_memmap_stage7 (
        .clk(Clock),
        .load(memmap_load),
        .addr(memmap_addr),
        .d(memmap_d),
        .kbd_in(kbd_word),
        .q(memmap_q)
    );

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

    // Build 8 digit bytes.
    always @(*) begin
        disp_digits = 64'h0;

        for (i = 0; i < HEX_DIGITS; i = i + 1) begin
            if (i < 8) begin
                disp_digits[i*8 +: 8] = hex7seg(op_a[i*4 +: 4]);
            end
            if ((i + HEX_DIGITS) < 8) begin
                disp_digits[(i + HEX_DIGITS)*8 +: 8] = hex7seg(rhs_val[i*4 +: 4]);
            end
        end

        if ((2 * HEX_DIGITS) < 8) begin
            if (view_mode == MODE_ALU) begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(op_sel);
            end else if (view_mode == MODE_REG) begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(4'hD);
            end else if (view_mode == MODE_RAM8) begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(4'h8);
            end else if (view_mode == MODE_RAM64) begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(4'h6);
            end else if (view_mode == MODE_RAM512) begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(4'h5);
            end else if (view_mode == MODE_BRAM) begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(4'hB);
            end else if (view_mode == MODE_RAM4K) begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(4'h4);
            end else if (view_mode == MODE_MEMMAP) begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(4'hE);
            end else begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(4'h0);
            end
        end

        if ((2 * HEX_DIGITS + 1) < 8) begin
            if (view_mode == MODE_ALU) begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg({2'b00, alu_zr, alu_ng});
            end else if (view_mode == MODE_REG) begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg({3'b000, (mem_reg_q == 0)});
            end else if (view_mode == MODE_RAM8) begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg({1'b0, ram8_addr});
            end else if (view_mode == MODE_RAM64) begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg({1'b0, ram64_addr[5:3]});
            end else if (view_mode == MODE_RAM512) begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg({1'b0, ram512_addr[8:6]});
            end else if (view_mode == MODE_BRAM) begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg({1'b0, ram_bram_addr[8:6]});
            end else if (view_mode == MODE_RAM4K) begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg(ram4k_addr[11:8]);
            end else if (view_mode == MODE_MEMMAP) begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg({1'b0, memmap_addr[14:12]});
            end else begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg(4'h0);
            end
        end

        if ((2 * HEX_DIGITS + 2) < 8) begin
            if (view_mode == MODE_ALU) begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg({2'b00, alu_carry, alu_ovf});
            end else if (view_mode == MODE_REG) begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg(4'h1);
            end else if (view_mode == MODE_RAM8) begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg(4'h2);
            end else if (view_mode == MODE_RAM64) begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg({1'b0, ram64_addr[2:0]});
            end else if (view_mode == MODE_RAM512) begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg({1'b0, ram512_addr[5:3]});
            end else if (view_mode == MODE_BRAM) begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg({1'b0, ram_bram_addr[5:3]});
            end else if (view_mode == MODE_RAM4K) begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg(ram4k_addr[7:4]);
            end else if (view_mode == MODE_MEMMAP) begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg(memmap_addr[7:4]);
            end else begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg(4'h0);
            end
        end

        if ((2 * HEX_DIGITS + 3) < 8) begin
            if (view_mode == MODE_RAM512) begin
                disp_digits[(2 * HEX_DIGITS + 3)*8 +: 8] = hex7seg({1'b0, ram512_addr[2:0]});
            end else if (view_mode == MODE_BRAM) begin
                disp_digits[(2 * HEX_DIGITS + 3)*8 +: 8] = hex7seg({1'b0, ram_bram_addr[2:0]});
            end else if (view_mode == MODE_RAM4K) begin
                disp_digits[(2 * HEX_DIGITS + 3)*8 +: 8] = hex7seg(ram4k_addr[3:0]);
            end else if (view_mode == MODE_MEMMAP) begin
                disp_digits[(2 * HEX_DIGITS + 3)*8 +: 8] = hex7seg(memmap_addr[3:0]);
            end else begin
                disp_digits[(2 * HEX_DIGITS + 3)*8 +: 8] = hex7seg(4'h0);
            end
        end
    end

    // Build LED bytes.
    always @(*) begin
        disp_leds = 8'h00;

        disp_leds[0] = (view_mode == MODE_REG);
        disp_leds[1] = (view_mode == MODE_RAM8);
        disp_leds[2] = (view_mode == MODE_RAM64);
        disp_leds[3] = (view_mode == MODE_RAM512);
        disp_leds[4] = (view_mode == MODE_BRAM);
        disp_leds[5] = (view_mode == MODE_RAM4K) | (view_mode == MODE_MEMMAP);

        if (view_mode == MODE_RAM8) begin
            disp_leds[6] = ram8_addr[0];
            disp_leds[7] = ram8_addr[1];
        end else if (view_mode == MODE_RAM64) begin
            disp_leds[6] = ram64_addr[0];
            disp_leds[7] = ram64_addr[1];
        end else if (view_mode == MODE_RAM512) begin
            disp_leds[6] = ram512_addr[0];
            disp_leds[7] = ram512_addr[1];
        end else if (view_mode == MODE_BRAM) begin
            disp_leds[6] = ram_bram_addr[0];
            disp_leds[7] = ram_bram_addr[1];
        end else if (view_mode == MODE_RAM4K) begin
            disp_leds[6] = ram4k_addr[0];
            disp_leds[7] = ram4k_addr[1];
        end else if (view_mode == MODE_MEMMAP) begin
            disp_leds[6] = memmap_addr[13];
            disp_leds[7] = memmap_addr[14];
        end else begin
            disp_leds[6] = op_sel[0];
            disp_leds[7] = op_sel[1];
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
        mem_reg_load <= 1'b0;
        ram8_load <= 1'b0;
        ram64_load <= 1'b0;
        ram512_load <= 1'b0;
        ram_bram_load <= 1'b0;
        ram4k_load <= 1'b0;
        memmap_load <= 1'b0;

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
        if (rx_done) begin
            rx_active <= 1'b0;

            if (tm_edge[0]) op_a <= op_a + 1'b1; // data/A++
            if (tm_edge[1]) op_a <= op_a - 1'b1; // data/A--
            if (tm_edge[7]) view_mode <= mode_next(view_mode); // mode cycle

            if (view_mode == MODE_ALU) begin
                if (tm_edge[2]) op_b <= op_b + 1'b1; // B++
                if (tm_edge[3]) op_b <= op_b - 1'b1; // B--
                if (tm_edge[4]) op_sel <= op_sel + 1'b1; // OP++
                if (tm_edge[5]) op_sel <= op_sel - 1'b1; // OP--
            end else if (view_mode == MODE_REG) begin
                if (tm_edge[2]) begin // REG <= A
                    mem_reg_d <= op_a;
                    mem_reg_load <= 1'b1;
                end
                if (tm_edge[3]) begin // REG <= 0
                    mem_reg_d <= {DATA_W{1'b0}};
                    mem_reg_load <= 1'b1;
                end
            end else if (view_mode == MODE_RAM8) begin
                if (tm_edge[2]) begin // RAM8[addr] <= A
                    ram8_d <= op_a;
                    ram8_load <= 1'b1;
                end
                if (tm_edge[3]) begin // A <= RAM8[addr]
                    op_a <= ram8_q;
                end
                if (tm_edge[4]) ram8_addr <= ram8_addr + 1'b1; // addr++
                if (tm_edge[5]) ram8_addr <= ram8_addr - 1'b1; // addr--
            end else if (view_mode == MODE_RAM64) begin
                if (tm_edge[2]) begin // RAM64[addr] <= A
                    ram64_d <= op_a;
                    ram64_load <= 1'b1;
                end
                if (tm_edge[3]) begin // A <= RAM64[addr]
                    op_a <= ram64_q;
                end
                if (tm_edge[4]) ram64_addr <= ram64_addr + 1'b1; // addr++
                if (tm_edge[5]) ram64_addr <= ram64_addr - 1'b1; // addr--
            end else if (view_mode == MODE_RAM512) begin
                if (tm_edge[2]) begin // RAM512[addr] <= A
                    ram512_d <= op_a;
                    ram512_load <= 1'b1;
                end
                if (tm_edge[3]) begin // A <= RAM512[addr]
                    op_a <= ram512_q;
                end
                if (tm_edge[4]) ram512_addr <= ram512_addr + 1'b1; // addr++
                if (tm_edge[5]) ram512_addr <= ram512_addr - 1'b1; // addr--
            end else if (view_mode == MODE_BRAM) begin
                if (tm_edge[2]) begin // BRAM[addr] <= A
                    ram_bram_d <= op_a;
                    ram_bram_load <= 1'b1;
                end
                if (tm_edge[3]) begin // A <= BRAM[addr]
                    op_a <= ram_bram_q;
                end
                if (tm_edge[4]) ram_bram_addr <= ram_bram_addr + 1'b1; // addr++
                if (tm_edge[5]) ram_bram_addr <= ram_bram_addr - 1'b1; // addr--
            end else if (view_mode == MODE_RAM4K) begin
                if (tm_edge[2]) begin // RAM4K[addr] <= A
                    ram4k_d <= op_a;
                    ram4k_load <= 1'b1;
                end
                if (tm_edge[3]) begin // A <= RAM4K[addr]
                    op_a <= ram4k_q;
                end
                if (tm_edge[4]) ram4k_addr <= ram4k_addr + 1'b1; // addr++
                if (tm_edge[5]) ram4k_addr <= ram4k_addr - 1'b1; // addr--
            end else if (view_mode == MODE_MEMMAP) begin
                if (tm_edge[2]) begin // MEM[addr] <= A
                    memmap_d <= op_a;
                    memmap_load <= 1'b1;
                end
                if (tm_edge[3]) begin // A <= MEM[addr]
                    op_a <= memmap_q;
                end
                if (tm_edge[4]) memmap_addr <= memmap_addr + 1'b1; // addr++
                if (tm_edge[5]) memmap_addr <= memmap_addr - 1'b1; // addr--
            end

            if (tm_edge[6]) begin
                op_a <= {DATA_W{1'b0}};
                op_b <= {DATA_W{1'b0}};
                op_sel <= 4'h0;
                view_mode <= MODE_ALU;
                mem_reg_d <= {DATA_W{1'b0}};
                mem_reg_load <= 1'b1;
                ram8_addr <= 3'b000;
                ram64_addr <= 6'b000000;
                ram512_addr <= 9'b000000000;
                ram_bram_addr <= 9'b000000000;
                ram4k_addr <= 12'b000000000000;
                memmap_addr <= 15'b000000000000000;
            end

            if (|tm_edge) led <= ~led;
            tm_prev <= tm_buttons;
        end

        // Board controls (debounced press pulse).
        if (board_press[0]) begin
            op_a <= op_a + 1'b1;
            led <= ~led;
        end

        if (board_press[1]) begin
            if (view_mode == MODE_ALU) begin
                op_b <= op_b + 1'b1;
            end else if (view_mode == MODE_REG) begin
                mem_reg_d <= op_a;
                mem_reg_load <= 1'b1;
            end else if (view_mode == MODE_RAM8) begin
                ram8_d <= op_a;
                ram8_load <= 1'b1;
            end else if (view_mode == MODE_RAM64) begin
                ram64_d <= op_a;
                ram64_load <= 1'b1;
            end else if (view_mode == MODE_RAM512) begin
                ram512_d <= op_a;
                ram512_load <= 1'b1;
            end else if (view_mode == MODE_BRAM) begin
                ram_bram_d <= op_a;
                ram_bram_load <= 1'b1;
            end else if (view_mode == MODE_RAM4K) begin
                ram4k_d <= op_a;
                ram4k_load <= 1'b1;
            end else if (view_mode == MODE_MEMMAP) begin
                memmap_d <= op_a;
                memmap_load <= 1'b1;
            end
            led <= ~led;
        end

        if (board_press[2]) begin
            if (view_mode == MODE_ALU) begin
                op_sel <= op_sel + 1'b1;
            end else if (view_mode == MODE_REG) begin
                mem_reg_d <= {DATA_W{1'b0}};
                mem_reg_load <= 1'b1;
            end else if (view_mode == MODE_RAM8) begin
                ram8_addr <= ram8_addr + 1'b1;
            end else if (view_mode == MODE_RAM64) begin
                ram64_addr <= ram64_addr + 1'b1;
            end else if (view_mode == MODE_RAM512) begin
                ram512_addr <= ram512_addr + 1'b1;
            end else if (view_mode == MODE_BRAM) begin
                ram_bram_addr <= ram_bram_addr + 1'b1;
            end else if (view_mode == MODE_RAM4K) begin
                ram4k_addr <= ram4k_addr + 1'b1;
            end else if (view_mode == MODE_MEMMAP) begin
                memmap_addr <= memmap_addr + 15'h1000;
            end
            led <= ~led;
        end

        if (board_press[3]) begin
            view_mode <= mode_next(view_mode);
            led <= ~led;
        end

        if (board_press[4]) begin
            op_a <= {DATA_W{1'b0}};
            op_b <= {DATA_W{1'b0}};
            op_sel <= 4'h0;
            view_mode <= MODE_ALU;
            mem_reg_d <= {DATA_W{1'b0}};
            mem_reg_load <= 1'b1;
            ram8_addr <= 3'b000;
            ram64_addr <= 6'b000000;
            ram512_addr <= 9'b000000000;
            ram_bram_addr <= 9'b000000000;
            ram4k_addr <= 12'b000000000000;
            memmap_addr <= 15'b000000000000000;
            led <= ~led;
        end
    end

endmodule
