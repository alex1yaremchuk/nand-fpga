module tm1638_rx #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BIT_HZ = 100_000
)(
    input  wire       clk,
    input  wire       start,
    input  wire       dio_in,
    output reg        stb = 1'b1,
    output reg        sclk = 1'b1,
    output reg        dio_oe = 1'b1,
    output reg        dio_out = 1'b1,
    output reg        busy = 1'b0,
    output reg        done = 1'b0,
    output reg [31:0] keys = 0
);

    localparam integer BIT_DIV = (CLK_HZ / BIT_HZ);
    localparam integer BIT_W = (BIT_DIV <= 2) ? 2 : $clog2(BIT_DIV);

    localparam [3:0] S_IDLE      = 4'd0;
    localparam [3:0] S_CMD_ST    = 4'd1;
    localparam [3:0] S_CMD_LO    = 4'd2;
    localparam [3:0] S_CMD_HI    = 4'd3;
    localparam [3:0] S_RD_LO     = 4'd4;
    localparam [3:0] S_RD_HI     = 4'd5;
    localparam [3:0] S_RD_NEXTB  = 4'd6;
    localparam [3:0] S_END       = 4'd7;

    reg [3:0] state = S_IDLE;
    reg [BIT_W-1:0] bit_cnt = 0;
    reg bit_tick = 0;

    reg [2:0] bit_idx = 0;
    reg [1:0] byte_idx = 0;
    reg [7:0] rbyte = 0;
    reg start_pending = 1'b0;

    always @(posedge clk) begin
        if (bit_cnt == BIT_DIV - 1) begin
            bit_cnt <= 0;
            bit_tick <= 1'b1;
        end else begin
            bit_cnt <= bit_cnt + 1'b1;
            bit_tick <= 1'b0;
        end

        done <= 1'b0;
        if (start) begin
            start_pending <= 1'b1;
        end

        if (bit_tick) begin
            case (state)
                S_IDLE: begin
                    stb <= 1'b1;
                    sclk <= 1'b1;
                    dio_oe <= 1'b1;
                    dio_out <= 1'b1;
                    busy <= 1'b0;
                    if (start_pending) begin
                        busy <= 1'b1;
                        start_pending <= 1'b0;
                        state <= S_CMD_ST;
                    end
                end

                S_CMD_ST: begin
                    stb <= 1'b0;
                    sclk <= 1'b1;
                    dio_oe <= 1'b1;
                    dio_out <= 1'b1;
                    bit_idx <= 0;
                    state <= S_CMD_LO;
                end

                S_CMD_LO: begin
                    sclk <= 1'b0;
                    dio_out <= ((8'h42 >> bit_idx) & 8'h01);
                    state <= S_CMD_HI;
                end

                S_CMD_HI: begin
                    sclk <= 1'b1;
                    if (bit_idx == 3'd7) begin
                        dio_oe <= 1'b0; // release line for read
                        bit_idx <= 0;
                        byte_idx <= 0;
                        rbyte <= 8'h00;
                        keys <= 32'h00000000;
                        state <= S_RD_LO;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                        state <= S_CMD_LO;
                    end
                end

                S_RD_LO: begin
                    sclk <= 1'b0;
                    state <= S_RD_HI;
                end

                S_RD_HI: begin
                    sclk <= 1'b1;
                    rbyte[bit_idx] <= dio_in;

                    if (bit_idx == 3'd7) begin
                        keys[byte_idx*8 +: 8] <= {dio_in, rbyte[6:0]};
                        state <= S_RD_NEXTB;
                    end else begin
                        bit_idx <= bit_idx + 1'b1;
                        state <= S_RD_LO;
                    end
                end

                S_RD_NEXTB: begin
                    if (byte_idx == 2'd3) begin
                        state <= S_END;
                    end else begin
                        byte_idx <= byte_idx + 1'b1;
                        bit_idx <= 0;
                        rbyte <= 8'h00;
                        state <= S_RD_LO;
                    end
                end

                S_END: begin
                    stb <= 1'b1;
                    sclk <= 1'b1;
                    dio_oe <= 1'b1;
                    dio_out <= 1'b1;
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
