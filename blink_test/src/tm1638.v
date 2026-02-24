// TM1638 driver (write display/leds + read keys)
// - 27MHz input clock, internal clock-enable for bit-banging
// - frame-based STB (correct for TM1638)
// - DIO is bidirectional (inout + tri-state)
// - internal shadow RAM (16 bytes): addr0..15 (segments on even, leds on odd)

module tm1638 #(
    parameter integer CLK_HZ   = 27_000_000,
    parameter integer BIT_HZ   = 10_000      // bit step rate (each state advances at this rate)
)(
    input  wire clk,

    // TM1638 pins
    output reg  stb,
    output reg  sclk,
    inout  wire dio,

    // control
    input  wire        init_req,        // pulse 1 -> (re)init chip
    input  wire        refresh_req,     // pulse 1 -> write shadow RAM to chip
    input  wire        keys_req,        // pulse 1 -> read keys (32 bits)

    input  wire [2:0]  brightness,      // 0..7
    input  wire        display_on,      // 0/1

    // shadow RAM interface (16 bytes, simple write port)
    input  wire        ram_we,
    input  wire [3:0]  ram_waddr,       // 0..15
    input  wire [7:0]  ram_wdata,

    // status/results
    output reg         busy,
    output reg         done,            // 1-tick pulse when operation completes
    output reg [31:0]  keys,            // last read keys
    output reg         keys_valid        // pulse on new keys
);

    // ------------------------------------------------------------
    // clock enable for bit-banging
    // ------------------------------------------------------------
    localparam integer TICK_DIV = (CLK_HZ / BIT_HZ);
    localparam integer TICK_W   = (TICK_DIV <= 2) ? 2 : $clog2(TICK_DIV);

    reg [TICK_W-1:0] tick_cnt = 0;
    reg tick_en = 0;

    always @(posedge clk) begin
        if (tick_cnt == TICK_DIV-1) begin
            tick_cnt <= 0;
            tick_en  <= 1'b1;
        end else begin
            tick_cnt <= tick_cnt + 1'b1;
            tick_en  <= 1'b0;
        end
    end

    // ------------------------------------------------------------
    // shadow RAM (16 bytes)
    // addr even: segments for digit (0,2,4,...,14)
    // addr odd : leds bits (1,3,5,...,15) -- usually bit0 is led for that digit
    // ------------------------------------------------------------
    reg [7:0] ram [0:15];
    integer i;

    initial begin
        for (i = 0; i < 16; i = i + 1) ram[i] = 8'h00;
        stb  = 1'b1;
        sclk = 1'b1;
    end

    always @(posedge clk) begin
        if (ram_we) ram[ram_waddr] <= ram_wdata;
    end

    // ------------------------------------------------------------
    // DIO tri-state handling
    // ------------------------------------------------------------
    reg dio_out = 1'b1;
    reg dio_oe  = 1'b1;   // 1=drive, 0=hi-z (read)
    assign dio = dio_oe ? dio_out : 1'bz;
    wire dio_in = dio;

    // ------------------------------------------------------------
    // Low-level sender/reader FSM
    // We'll implement operations as sequences of frames:
    // - init:   [0x40] (write auto inc) + [0xC0 + 16 bytes] + [0x80 | on<<3 | bright]
    // - refresh:[0x40] + [0xC0 + 16 bytes]
    // - keys:   [0x42] then read 4 bytes
    // ------------------------------------------------------------

    // main op selector
    localparam OP_NONE    = 0;
    localparam OP_INIT    = 1;
    localparam OP_REFRESH = 2;
    localparam OP_KEYS    = 3;

    reg [1:0] op = OP_NONE;

    // FSM states
    localparam S_IDLE         = 0;
    localparam S_FRAME_START  = 1;
    localparam S_SEND_BIT_LO  = 2;
    localparam S_SEND_BIT_HI  = 3;
    localparam S_NEXT_BYTE    = 4;
    localparam S_FRAME_END    = 5;
    localparam S_GAP          = 6;
    localparam S_READ_BIT_HI  = 7;
    localparam S_READ_NEXTBIT = 8;
    localparam S_READ_NEXTB   = 9;
    localparam S_DONE         = 10;

    reg [3:0] state = S_IDLE;

    // current frame/byte
    reg [7:0] cur_byte = 8'h00;
    reg [2:0] bit_idx  = 0;

    // script pointers
    reg [5:0] byte_idx = 0;
    reg [2:0] frame_idx = 0;
    reg [3:0] gap_cnt = 0;

    // read buffer for keys
    reg [7:0] rbyte = 8'h00;
    reg [1:0] rcount = 0;

    // helpers: lengths and bytes for each operation
    function [2:0] op_frames(input [1:0] o);
        begin
            case (o)
                OP_INIT:    op_frames = 3; // 0x40, 0xC0+16, 0x8?
                OP_REFRESH: op_frames = 2; // 0x40, 0xC0+16
                OP_KEYS:    op_frames = 1; // 0x42 (then read 4 bytes as part of same frame)
                default:    op_frames = 0;
            endcase
        end
    endfunction

    function [5:0] frame_len(input [1:0] o, input [2:0] f);
        begin
            case (o)
                OP_INIT: begin
                    if (f == 0) frame_len = 1;    // 0x40
                    else if (f == 1) frame_len = 17; // 0xC0 + 16
                    else frame_len = 1;           // 0x8?
                end
                OP_REFRESH: begin
                    if (f == 0) frame_len = 1;    // 0x40
                    else frame_len = 17;          // 0xC0 + 16
                end
                OP_KEYS: begin
                    frame_len = 1;                // 0x42 (then read 4 bytes, handled separately)
                end
                default: frame_len = 0;
            endcase
        end
    endfunction

    function [7:0] frame_byte(input [1:0] o, input [2:0] f, input [5:0] idx);
        reg [7:0] disp_ctrl;
        begin
            disp_ctrl = 8'h80 | (display_on ? 8'h08 : 8'h00) | {5'b0, brightness}; // 0x88..0x8F or 0x80..0x87

            case (o)
                OP_INIT: begin
                    if (f == 0) begin
                        frame_byte = (idx == 0) ? 8'h40 : 8'h00;
                    end else if (f == 1) begin
                        if (idx == 0) frame_byte = 8'hC0;
                        else if (idx >= 1 && idx <= 16) frame_byte = ram[idx-1];
                        else frame_byte = 8'h00;
                    end else begin
                        frame_byte = (idx == 0) ? disp_ctrl : 8'h00;
                    end
                end

                OP_REFRESH: begin
                    if (f == 0) begin
                        frame_byte = (idx == 0) ? 8'h40 : 8'h00;
                    end else begin
                        if (idx == 0) frame_byte = 8'hC0;
                        else if (idx >= 1 && idx <= 16) frame_byte = ram[idx-1];
                        else frame_byte = 8'h00;
                    end
                end

                OP_KEYS: begin
                    frame_byte = (idx == 0) ? 8'h42 : 8'h00;
                end

                default: frame_byte = 8'h00;
            endcase
        end
    endfunction

    // ------------------------------------------------------------
    // Request latching (one op at a time)
    // priority: init > refresh > keys (можно поменять)
    // ------------------------------------------------------------
    always @(posedge clk) begin
        done       <= 1'b0;
        keys_valid <= 1'b0;

        if (state == S_IDLE) begin
            busy <= 1'b0;

            // idle bus levels
            stb    <= 1'b1;
            sclk   <= 1'b1;
            dio_oe <= 1'b1;
            dio_out<= 1'b1;

            if (init_req) begin
                op       <= OP_INIT;
                frame_idx<= 0;
                byte_idx <= 0;
                bit_idx  <= 0;
                busy     <= 1'b1;
                state    <= S_FRAME_START;
            end else if (refresh_req) begin
                op       <= OP_REFRESH;
                frame_idx<= 0;
                byte_idx <= 0;
                bit_idx  <= 0;
                busy     <= 1'b1;
                state    <= S_FRAME_START;
            end else if (keys_req) begin
                op       <= OP_KEYS;
                frame_idx<= 0;
                byte_idx <= 0;
                bit_idx  <= 0;
                rcount   <= 0;
                keys     <= keys; // keep
                busy     <= 1'b1;
                state    <= S_FRAME_START;
            end
        end else if (tick_en) begin
            // ----------------------------------------------------
            // progress FSM only on tick_en
            // ----------------------------------------------------
            case (state)
                S_FRAME_START: begin
                    // start frame
                    stb    <= 1'b0;
                    sclk   <= 1'b1;

                    dio_oe <= 1'b1;
                    dio_out<= 1'b1;

                    byte_idx <= 0;
                    bit_idx  <= 0;
                    cur_byte <= frame_byte(op, frame_idx, 0);

                    state <= S_SEND_BIT_LO;
                end

                // send bit (LSB first)
                S_SEND_BIT_LO: begin
                    sclk    <= 1'b0;
                    dio_oe  <= 1'b1;
                    dio_out <= cur_byte[bit_idx];
                    state   <= S_SEND_BIT_HI;
                end

                S_SEND_BIT_HI: begin
                    sclk <= 1'b1;
                    if (bit_idx == 7) begin
                        state <= S_NEXT_BYTE;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                        state   <= S_SEND_BIT_LO;
                    end
                end

                S_NEXT_BYTE: begin
                    if (byte_idx + 1 >= frame_len(op, frame_idx)) begin
                        // special: after sending 0x42 in OP_KEYS, now read 4 bytes before ending frame
                        if (op == OP_KEYS) begin
                            // prepare read
                            dio_oe <= 1'b0; // hi-z
                            rcount <= 0;
                            rbyte  <= 8'h00;
                            bit_idx<= 0;
                            state  <= S_READ_BIT_HI;
                        end else begin
                            state <= S_FRAME_END;
                        end
                    end else begin
                        byte_idx <= byte_idx + 1'b1;
                        cur_byte <= frame_byte(op, frame_idx, byte_idx + 1);
                        bit_idx  <= 0;
                        state    <= S_SEND_BIT_LO;
                    end
                end

                // -------- read keys (4 bytes) --------
                // TM1638 shifts out LSB first on each clock rising edge
                S_READ_BIT_HI: begin
                    // sample on clock high, but we need create clock pulses:
                    // set clock low next, then high and sample
                    sclk  <= 1'b0;
                    state <= S_READ_NEXTBIT;
                end

                S_READ_NEXTBIT: begin
                    // rising edge: sample current bit
                    sclk <= 1'b1;
                    rbyte[bit_idx] <= dio_in; // LSB-first
                    if (bit_idx == 7) begin
                        state <= S_READ_NEXTB;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                        state <= S_READ_BIT_HI;
                    end
                end

                S_READ_NEXTB: begin
                    // store completed read byte into keys[...]
                    // We pack as little-endian: first byte -> keys[7:0]
                    keys <= (keys & ~(32'hFF << (rcount*8))) | ( {24'h0, rbyte} << (rcount*8) );

                    if (rcount == 3) begin
                        keys_valid <= 1'b1;
                        state <= S_FRAME_END;
                    end else begin
                        rcount <= rcount + 1'b1;
                        rbyte  <= 8'h00;
                        bit_idx<= 0;
                        state  <= S_READ_BIT_HI;
                    end
                end

                // ------------------------------------
                S_FRAME_END: begin
                    stb    <= 1'b1;
                    sclk   <= 1'b1;
                    dio_oe <= 1'b1;
                    dio_out<= 1'b1;

                    gap_cnt <= 0;
                    state   <= S_GAP;
                end

                S_GAP: begin
                    if (gap_cnt == 4) begin
                        if (frame_idx + 1 >= op_frames(op)) begin
                            state <= S_DONE;
                        end else begin
                            frame_idx <= frame_idx + 1'b1;
                            state <= S_FRAME_START;
                        end
                    end else begin
                        gap_cnt <= gap_cnt + 1'b1;
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    op   <= OP_NONE;
                    state<= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule