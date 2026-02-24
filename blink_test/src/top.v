module top(
    input  wire Clock,
    output reg  led,

    output wire tm_stb,
    output wire tm_clk,
    inout  wire tm_dio
);

    // ------------------------------------------------------------
    // Simple scheduler: pulses for init/refresh/keys every N ms
    // ------------------------------------------------------------
    reg [21:0] ms_div = 0;
    reg tick_1ms = 0;

    // 27MHz -> 1ms is 27_000 cycles
    always @(posedge Clock) begin
        if (ms_div == 27_000 - 1) begin
            ms_div <= 0;
            tick_1ms <= 1'b1;
        end else begin
            ms_div <= ms_div + 1'b1;
            tick_1ms <= 1'b0;
        end
    end

    reg [7:0]  t_ms = 0;
    reg init_req = 0;
    reg refresh_req = 0;
    reg keys_req = 0;

    // ------------------------------------------------------------
    // TM1638 instance
    // ------------------------------------------------------------
    wire busy, done;
    wire [31:0] keys;
    wire keys_valid;

    reg [2:0] brightness = 3'd7;
    reg display_on = 1'b1;

    reg ram_we = 0;
    reg [3:0] ram_waddr = 0;
    reg [7:0] ram_wdata = 0;

    tm1638 #(
        .CLK_HZ(27_000_000),
        .BIT_HZ(10_000)
    ) u_tm (
        .clk(Clock),

        .stb(tm_stb),
        .sclk(tm_clk),
        .dio(tm_dio),

        .init_req(init_req),
        .refresh_req(refresh_req),
        .keys_req(keys_req),

        .brightness(brightness),
        .display_on(display_on),

        .ram_we(ram_we),
        .ram_waddr(ram_waddr),
        .ram_wdata(ram_wdata),

        .busy(busy),
        .done(done),
        .keys(keys),
        .keys_valid(keys_valid)
    );

    // ------------------------------------------------------------
    // HEX -> 7seg (common TM1638 style; may need segment order tweak)
    // returns bits: [0]=a [1]=b [2]=c [3]=d [4]=e [5]=f [6]=g [7]=dp
    // ------------------------------------------------------------
    function [7:0] hex7seg(input [3:0] v);
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

    // ------------------------------------------------------------
    // Write helpers into shadow RAM:
    // digit i uses addr = i*2 (segments)
    // led   i uses addr = i*2 + 1 (led bits, usually bit0)
    // ------------------------------------------------------------
    task write_digit(input [2:0] idx, input [7:0] seg);
        begin
            ram_we    <= 1'b1;
            ram_waddr <= {idx, 1'b0}; // *2
            ram_wdata <= seg;
        end
    endtask

    task write_led(input [2:0] idx, input on);
        begin
            ram_we    <= 1'b1;
            ram_waddr <= {idx, 1'b0} + 1; // *2+1
            ram_wdata <= on ? 8'h01 : 8'h00;
        end
    endtask

    // ------------------------------------------------------------
    // simple sequencer for RAM writes (since ram_we is 1-cycle)
    // ------------------------------------------------------------
    reg [4:0] sub = 0;
    reg started = 0;
    reg [31:0] keys_latched = 0;
    reg [7:0] buttons_latched = 0;

    // Map TM1638 key-scan matrix to 8 front-panel buttons.
    // Reverse order so button position matches digit position on this board.
    function [7:0] decode_buttons(input [31:0] raw);
        integer k;
        begin
            decode_buttons = 8'h00;
            for (k = 0; k < 8; k = k + 1) begin
                decode_buttons[k] = raw[((7-k)*4)];
            end
        end
    endfunction

    initial begin
        led = 0;
    end

    always @(posedge Clock) begin
        init_req    <= 1'b0;
        refresh_req <= 1'b0;
        keys_req    <= 1'b0;
        ram_we      <= 1'b0;

        if (tick_1ms) begin
            t_ms <= t_ms + 1'b1;

            // once at boot: init
            if (!started) begin
                started <= 1'b1;
                init_req <= 1'b1;
            end

            // periodic: every 50ms request keys
            if (t_ms == 50) begin
                t_ms <= 0;
                keys_req <= 1'b1;
            end
        end

        // latch keys when new
        if (keys_valid) begin
            keys_latched <= keys;
            buttons_latched <= decode_buttons(keys);
            // led <= ~led; // activity indicator
            sub <= 0;    // trigger RAM update below
        end

        // After we got keys, update RAM in few cycles then refresh
        // sub steps: write 8 digits + 8 leds, then refresh_req
        if (!busy) begin
            if (sub < 8) begin
                // show "2" on pressed button position, otherwise "0"
                write_digit(sub[2:0], hex7seg(buttons_latched[sub] ? 4'h3 : 4'h8));
                sub <= sub + 1'b1;
            end else if (sub < 16) begin
                // led under pressed button
                write_led(sub[2:0], buttons_latched[sub-8]);
                sub <= sub + 1'b1;
            end else if (sub == 16) begin
                refresh_req <= 1'b1;
                sub <= 17;
            end
        end
    end

endmodule
