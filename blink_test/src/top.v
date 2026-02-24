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

    reg [DATA_W-1:0] op_a = 0;
    reg [DATA_W-1:0] op_b = 0;
    reg [3:0] op_sel = 0;
    reg show_b = 1'b0;

    wire [DATA_W-1:0] alu_y;
    wire alu_zr;
    wire alu_ng;
    wire alu_carry;
    wire alu_ovf;
    wire [DATA_W-1:0] rhs_val = show_b ? op_b : alu_y;

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
            disp_digits[(2 * HEX_DIGITS)*8 +: 8] = hex7seg(op_sel);
        end
        if ((2 * HEX_DIGITS + 1) < 8) begin
            disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] = hex7seg({1'b0, show_b, alu_zr, alu_ng});
        end
        if ((2 * HEX_DIGITS + 2) < 8) begin
            disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] = hex7seg({2'b00, alu_carry, alu_ovf});
        end
    end

    // Build LED bytes.
    always @(*) begin
        disp_leds = 8'h00;
        disp_leds[0] = show_b;
        disp_leds[1] = alu_zr;
        disp_leds[2] = alu_ng;
        disp_leds[3] = alu_carry;
        disp_leds[4] = alu_ovf;
        disp_leds[5] = op_sel[0];
        disp_leds[6] = op_sel[1];
        disp_leds[7] = op_sel[2];
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

            if (tm_edge[0]) op_a <= op_a + 1'b1; // A++
            if (tm_edge[1]) op_a <= op_a - 1'b1; // A--
            if (tm_edge[2]) op_b <= op_b + 1'b1; // B++
            if (tm_edge[3]) op_b <= op_b - 1'b1; // B--
            if (tm_edge[4]) op_sel <= op_sel + 1'b1; // OP++
            if (tm_edge[5]) op_sel <= op_sel - 1'b1; // OP--
            if (tm_edge[6]) begin
                op_a <= {DATA_W{1'b0}};
                op_b <= {DATA_W{1'b0}};
                op_sel <= 4'h0;
            end
            if (tm_edge[7]) show_b <= ~show_b; // B/Y view toggle

            if (|tm_edge) led <= ~led;
            tm_prev <= tm_buttons;
        end

        // Board controls (debounced press pulse).
        if (board_press[0]) begin op_a <= op_a + 1'b1; led <= ~led; end // s0
        if (board_press[1]) begin op_b <= op_b + 1'b1; led <= ~led; end // s1
        if (board_press[2]) begin op_sel <= op_sel + 1'b1; led <= ~led; end // s2
        if (board_press[3]) begin show_b <= ~show_b; led <= ~led; end // s3
        if (board_press[4]) begin
            op_a <= {DATA_W{1'b0}};
            op_b <= {DATA_W{1'b0}};
            op_sel <= 4'h0;
            led <= ~led;
        end
    end

endmodule
