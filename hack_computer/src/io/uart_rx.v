module uart_rx #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg [7:0]  data = 8'h00,
    output reg        valid = 1'b0,
    output reg        frame_err = 1'b0,
    output reg        busy = 1'b0
);

    localparam integer CLKS_PER_BIT = (CLK_HZ / BAUD);
    localparam integer CTR_W = (CLKS_PER_BIT <= 2) ? 2 : $clog2(CLKS_PER_BIT);

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg [1:0] state = S_IDLE;
    reg [CTR_W-1:0] ctr = {CTR_W{1'b0}};
    reg [2:0] bit_idx = 3'd0;
    reg [7:0] shift = 8'h00;

    always @(posedge clk) begin
        valid <= 1'b0;
        frame_err <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            ctr <= {CTR_W{1'b0}};
            bit_idx <= 3'd0;
            shift <= 8'h00;
            busy <= 1'b0;
            frame_err <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    ctr <= {CTR_W{1'b0}};
                    bit_idx <= 3'd0;
                    if (rx == 1'b0) begin
                        // Start bit detected, sample in the middle.
                        state <= S_START;
                        busy <= 1'b1;
                        ctr <= (CLKS_PER_BIT >> 1);
                    end
                end

                S_START: begin
                    if (ctr == 0) begin
                        if (rx == 1'b0) begin
                            state <= S_DATA;
                            ctr <= CLKS_PER_BIT - 1;
                            bit_idx <= 3'd0;
                        end else begin
                            // Glitch, return idle.
                            frame_err <= 1'b1;
                            state <= S_IDLE;
                        end
                    end else begin
                        ctr <= ctr - 1'b1;
                    end
                end

                S_DATA: begin
                    if (ctr == 0) begin
                        shift[bit_idx] <= rx;
                        ctr <= CLKS_PER_BIT - 1;
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        ctr <= ctr - 1'b1;
                    end
                end

                S_STOP: begin
                    if (ctr == 0) begin
                        // Still emit byte on framing error to keep interface robust.
                        if (rx != 1'b1) begin
                            frame_err <= 1'b1;
                        end
                        data <= shift;
                        valid <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        ctr <= ctr - 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
