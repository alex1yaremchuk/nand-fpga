module top(
    input  wire Clock,
    output reg  led,
    output reg  tm_stb,
    output reg  tm_clk,
    inout  wire tm_dio
);

    // Direct-write-only TM1638 test:
    // 1) 0x40
    // 2) 0xC0 + 16 data bytes (all segments ON, all leds ON)
    // 3) 0x8F
    // Repeat forever.

    reg dio_out = 1'b1;
    assign tm_dio = dio_out;

    localparam integer STEP_DIV = 270; // 27MHz -> 100kHz step
    localparam integer STEP_W = $clog2(STEP_DIV);
    reg [STEP_W-1:0] step_cnt = 0;
    reg step = 1'b0;

    always @(posedge Clock) begin
        if (step_cnt == STEP_DIV - 1) begin
            step_cnt <= 0;
            step <= 1'b1;
        end else begin
            step_cnt <= step_cnt + 1'b1;
            step <= 1'b0;
        end
    end

    localparam S_BOOT       = 3'd0;
    localparam S_FRAME_ST   = 3'd1;
    localparam S_BIT_LO     = 3'd2;
    localparam S_BIT_HI     = 3'd3;
    localparam S_NEXT_BYTE  = 3'd4;
    localparam S_FRAME_END  = 3'd5;
    localparam S_GAP        = 3'd6;

    reg [2:0] state = S_BOOT;
    reg [1:0] frame = 0;
    reg [4:0] byte_idx = 0;
    reg [2:0] bit_idx = 0;
    reg [7:0] cur_byte = 8'h00;
    reg [15:0] boot_wait = 0;
    reg [7:0] gap_cnt = 0;

    function [4:0] frame_len;
        input [1:0] f;
        begin
            case (f)
                2'd0: frame_len = 5'd1;   // 0x40
                2'd1: frame_len = 5'd17;  // 0xC0 + 16 bytes
                2'd2: frame_len = 5'd1;   // 0x8F
                default: frame_len = 5'd1;
            endcase
        end
    endfunction

    function [7:0] frame_byte;
        input [1:0] f;
        input [4:0] idx;
        reg [3:0] a;
        begin
            case (f)
                2'd0: frame_byte = 8'h40;
                2'd1: begin
                    if (idx == 0) begin
                        frame_byte = 8'hC0;
                    end else begin
                        a = idx - 1;
                        // even addr: segment byte, odd addr: led byte
                        frame_byte = a[0] ? 8'h01 : 8'hFF;
                    end
                end
                2'd2: frame_byte = 8'h8F; // display ON, brightness max
                default: frame_byte = 8'h00;
            endcase
        end
    endfunction

    initial begin
        led = 1'b0;
        tm_stb = 1'b1;
        tm_clk = 1'b1;
    end

    always @(posedge Clock) begin
        if (step) begin
            case (state)
                S_BOOT: begin
                    tm_stb <= 1'b1;
                    tm_clk <= 1'b1;
                    dio_out <= 1'b1;
                    if (boot_wait == 16'd20000) begin
                        frame <= 0;
                        byte_idx <= 0;
                        state <= S_FRAME_ST;
                    end else begin
                        boot_wait <= boot_wait + 1'b1;
                    end
                end

                S_FRAME_ST: begin
                    tm_stb <= 1'b0;
                    tm_clk <= 1'b1;
                    dio_out <= 1'b1;
                    byte_idx <= 0;
                    bit_idx <= 0;
                    cur_byte <= frame_byte(frame, 0);
                    state <= S_BIT_LO;
                end

                S_BIT_LO: begin
                    tm_clk <= 1'b0;
                    dio_out <= cur_byte[bit_idx];
                    state <= S_BIT_HI;
                end

                S_BIT_HI: begin
                    tm_clk <= 1'b1;
                    if (bit_idx == 3'd7) begin
                        state <= S_NEXT_BYTE;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                        state <= S_BIT_LO;
                    end
                end

                S_NEXT_BYTE: begin
                    if (byte_idx + 1 < frame_len(frame)) begin
                        byte_idx <= byte_idx + 1'b1;
                        bit_idx <= 0;
                        cur_byte <= frame_byte(frame, byte_idx + 1'b1);
                        state <= S_BIT_LO;
                    end else begin
                        state <= S_FRAME_END;
                    end
                end

                S_FRAME_END: begin
                    tm_stb <= 1'b1;
                    tm_clk <= 1'b1;
                    dio_out <= 1'b1;
                    gap_cnt <= 0;
                    state <= S_GAP;
                end

                S_GAP: begin
                    if (gap_cnt == 8'd20) begin
                        if (frame == 2'd2) begin
                            frame <= 0;
                            led <= ~led; // heartbeat when full script done
                        end else begin
                            frame <= frame + 1'b1;
                        end
                        state <= S_FRAME_ST;
                    end else begin
                        gap_cnt <= gap_cnt + 1'b1;
                    end
                end

                default: state <= S_BOOT;
            endcase
        end
    end

endmodule
