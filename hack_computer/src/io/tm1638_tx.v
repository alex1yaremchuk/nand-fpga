module tm1638_tx #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BIT_HZ = 100_000,
    parameter integer REFRESH_HZ = 40
)(
    input  wire        clk,
    input  wire        enable,
    input  wire [127:0] frame_data,   // 16 bytes: addr0..15
    input  wire [2:0]  brightness,    // 0..7
    input  wire        display_on,
    output reg         stb = 1'b1,
    output reg         sclk = 1'b1,
    output reg         dio_oe = 1'b1,
    output reg         dio_out = 1'b1,
    output reg         busy = 1'b0
);

    localparam integer BIT_DIV = (CLK_HZ / BIT_HZ);
    localparam integer BIT_W = (BIT_DIV <= 2) ? 2 : $clog2(BIT_DIV);
    localparam integer REF_DIV = (CLK_HZ / REFRESH_HZ);
    localparam integer REF_W = (REF_DIV <= 2) ? 2 : $clog2(REF_DIV);

    localparam [2:0] S_IDLE       = 3'd0;
    localparam [2:0] S_FRAME_ST   = 3'd1;
    localparam [2:0] S_BIT_LO     = 3'd2;
    localparam [2:0] S_BIT_HI     = 3'd3;
    localparam [2:0] S_NEXT_BYTE  = 3'd4;
    localparam [2:0] S_FRAME_END  = 3'd5;
    localparam [2:0] S_GAP        = 3'd6;

    reg [2:0] state = S_IDLE;
    reg [1:0] frame = 0;      // 0:0x40, 1:0xC0+16, 2:0x8x
    reg [4:0] byte_idx = 0;
    reg [2:0] bit_idx = 0;
    reg [7:0] cur_byte = 0;
    reg [7:0] gap_cnt = 0;

    reg [BIT_W-1:0] bit_cnt = 0;
    reg bit_tick = 0;

    reg [REF_W-1:0] ref_cnt = 0;
    reg refresh_due = 1'b1;

    reg [7:0] ram [0:15];
    integer i;

    wire [7:0] disp_ctrl = 8'h80 | (display_on ? 8'h08 : 8'h00) | {5'b0, brightness};

    function [4:0] frame_len;
        input [1:0] f;
        begin
            frame_len = (f == 2'd1) ? 5'd17 : 5'd1;
        end
    endfunction

    always @(posedge clk) begin
        if (bit_cnt == BIT_DIV - 1) begin
            bit_cnt <= 0;
            bit_tick <= 1'b1;
        end else begin
            bit_cnt <= bit_cnt + 1'b1;
            bit_tick <= 1'b0;
        end

        if (ref_cnt == REF_DIV - 1) begin
            ref_cnt <= 0;
            refresh_due <= 1'b1;
        end else begin
            ref_cnt <= ref_cnt + 1'b1;
        end

        if (!enable) begin
            state <= S_IDLE;
            busy <= 1'b0;
            stb <= 1'b1;
            sclk <= 1'b1;
            dio_oe <= 1'b1;
            dio_out <= 1'b1;
        end else if (bit_tick) begin
            case (state)
                S_IDLE: begin
                    stb <= 1'b1;
                    sclk <= 1'b1;
                    dio_oe <= 1'b1;
                    dio_out <= 1'b1;
                    busy <= 1'b0;

                    if (refresh_due) begin
                        refresh_due <= 1'b0;
                        busy <= 1'b1;
                        frame <= 0;
                        byte_idx <= 0;
                        bit_idx <= 0;
                        for (i = 0; i < 16; i = i + 1) begin
                            ram[i] <= frame_data[i*8 +: 8];
                        end
                        state <= S_FRAME_ST;
                    end
                end

                S_FRAME_ST: begin
                    stb <= 1'b0;
                    sclk <= 1'b1;
                    dio_oe <= 1'b1;
                    bit_idx <= 0;
                    byte_idx <= 0;

                    if (frame == 2'd0) cur_byte <= 8'h40;
                    else if (frame == 2'd1) cur_byte <= 8'hC0;
                    else cur_byte <= disp_ctrl;

                    state <= S_BIT_LO;
                end

                S_BIT_LO: begin
                    sclk <= 1'b0;
                    dio_out <= cur_byte[bit_idx];
                    state <= S_BIT_HI;
                end

                S_BIT_HI: begin
                    sclk <= 1'b1;
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

                        if (frame == 2'd0) cur_byte <= 8'h40;
                        else if (frame == 2'd1) begin
                            if (byte_idx + 1 == 0) cur_byte <= 8'hC0;
                            else cur_byte <= ram[byte_idx];
                        end else cur_byte <= disp_ctrl;

                        state <= S_BIT_LO;
                    end else begin
                        state <= S_FRAME_END;
                    end
                end

                S_FRAME_END: begin
                    stb <= 1'b1;
                    sclk <= 1'b1;
                    dio_out <= 1'b1;
                    gap_cnt <= 0;
                    state <= S_GAP;
                end

                S_GAP: begin
                    if (gap_cnt == 8'd20) begin
                        if (frame == 2'd2) begin
                            state <= S_IDLE;
                        end else begin
                            frame <= frame + 1'b1;
                            state <= S_FRAME_ST;
                        end
                    end else begin
                        gap_cnt <= gap_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
