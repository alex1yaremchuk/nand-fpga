module panel_controller #(
    parameter integer DATA_W = 8,
    parameter integer CLK_HZ = 27_000_000,
    parameter integer KEYS_PERIOD_MS = 50
)(
    input  wire              clk,
    input  wire              busy,
    input  wire [31:0]       keys,
    input  wire              keys_valid,
    input  wire [4:0]        board_keys_n, // active-low: {s4,s3,s2,s1,s0}

    output wire              init_req,
    output wire              keys_req,
    output wire              refresh_req,
    output wire              ram_we,
    output wire [3:0]        ram_waddr,
    output wire [7:0]        ram_wdata,
    output wire              led
);

    localparam integer HEX_DIGITS = (DATA_W + 3) / 4;

    wire tick_1ms;
    wire [7:0] tm_buttons;
    wire [4:0] board_level;
    wire [4:0] board_press;
    wire [4:0] board_stable_unused;

    reg [7:0] tm_prev = 0;

    reg [DATA_W-1:0] op_a = 0;
    reg [DATA_W-1:0] op_b = 0;
    reg [3:0] op_sel = 0;
    reg show_b = 0;

    wire [DATA_W-1:0] alu_y;
    wire alu_zr;
    wire alu_ng;
    wire alu_carry;
    wire alu_ovf;

    reg [63:0] disp_digits = 0;
    reg [7:0]  disp_leds = 0;
    reg start_frame = 0;
    wire frame_busy;
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

    assign board_level = ~board_keys_n;
    assign led = show_b;

    app_timing #(
        .CLK_HZ(CLK_HZ),
        .KEYS_PERIOD_MS(KEYS_PERIOD_MS)
    ) u_timing (
        .clk(clk),
        .tick_1ms(tick_1ms),
        .init_req(init_req),
        .keys_req(keys_req)
    );

    panel_mapper u_map (
        .keys_raw(keys),
        .buttons(tm_buttons)
    );

    key_debounce #(
        .WIDTH(5)
    ) u_board_keys (
        .clk(clk),
        .sample_tick(tick_1ms),
        .keys_level(board_level),
        .stable_level(board_stable_unused),
        .press_pulse(board_press)
    );

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

    panel_renderer u_render (
        .clk(clk),
        .busy(busy),
        .start(start_frame),
        .digits(disp_digits),
        .leds(disp_leds),
        .frame_busy(frame_busy),
        .refresh_req(refresh_req),
        .ram_we(ram_we),
        .ram_waddr(ram_waddr),
        .ram_wdata(ram_wdata)
    );

    always @(posedge clk) begin
        start_frame <= 1'b0;

        // TM1638 button edge actions
        if (keys_valid) begin
            if (tm_buttons[0] && !tm_prev[0]) op_a <= op_a + 1'b1; // A++
            if (tm_buttons[1] && !tm_prev[1]) op_a <= op_a - 1'b1; // A--
            if (tm_buttons[2] && !tm_prev[2]) op_b <= op_b + 1'b1; // B++
            if (tm_buttons[3] && !tm_prev[3]) op_b <= op_b - 1'b1; // B--
            if (tm_buttons[4] && !tm_prev[4]) op_sel <= op_sel + 1'b1; // OP++
            if (tm_buttons[5] && !tm_prev[5]) op_sel <= op_sel - 1'b1; // OP--
            if (tm_buttons[6] && !tm_prev[6]) begin
                op_a <= {DATA_W{1'b0}};
                op_b <= {DATA_W{1'b0}};
            end
            if (tm_buttons[7] && !tm_prev[7]) show_b <= ~show_b; // toggle B/Y on right half

            tm_prev <= tm_buttons;
        end

        // Board button actions (s0..s4)
        // s0..s3 toggle op bits, s4 toggles B/Y view
        if (board_press[0]) begin op_sel[0] <= ~op_sel[0]; end
        if (board_press[1]) begin op_sel[1] <= ~op_sel[1]; end
        if (board_press[2]) begin op_sel[2] <= ~op_sel[2]; end
        if (board_press[3]) begin op_sel[3] <= ~op_sel[3]; end
        if (board_press[4]) begin show_b <= ~show_b;       end

        // Build display/led payload and push frame continuously when renderer is free.
        if (!busy && !frame_busy) begin
            disp_digits <= 64'h0;

            for (i = 0; i < HEX_DIGITS; i = i + 1) begin
                disp_digits[i*8 +: 8] <= hex7seg(op_a[(i*4) +: 4]);
                if (show_b) begin
                    disp_digits[(i + HEX_DIGITS)*8 +: 8] <= hex7seg(op_b[(i*4) +: 4]);
                end else begin
                    disp_digits[(i + HEX_DIGITS)*8 +: 8] <= hex7seg(alu_y[(i*4) +: 4]);
                end
            end

            // If there is room (8-bit mode), show OP and flags on remaining digits.
            if ((2 * HEX_DIGITS) < 8) begin
                disp_digits[(2 * HEX_DIGITS)*8 +: 8] <= hex7seg(op_sel);
            end
            if ((2 * HEX_DIGITS + 1) < 8) begin
                disp_digits[(2 * HEX_DIGITS + 1)*8 +: 8] <= hex7seg({1'b0, show_b, alu_zr, alu_ng});
            end
            if ((2 * HEX_DIGITS + 2) < 8) begin
                disp_digits[(2 * HEX_DIGITS + 2)*8 +: 8] <= hex7seg({2'b00, alu_carry, alu_ovf});
            end

            disp_leds <= {op_sel[3:0], show_b, alu_zr, alu_ng, alu_ovf};

            start_frame <= 1'b1;
        end
    end

endmodule
