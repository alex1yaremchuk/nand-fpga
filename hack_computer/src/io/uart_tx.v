module uart_tx #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx = 1'b1,
    output reg        busy = 1'b0
);

    localparam integer CLKS_PER_BIT = (CLK_HZ / BAUD);
    localparam integer CTR_W = (CLKS_PER_BIT <= 2) ? 2 : $clog2(CLKS_PER_BIT);

    reg [CTR_W-1:0] ctr = {CTR_W{1'b0}};
    reg [3:0] bit_idx = 4'd0;
    reg [9:0] frame = 10'h3ff;

    always @(posedge clk) begin
        if (rst) begin
            tx <= 1'b1;
            busy <= 1'b0;
            ctr <= {CTR_W{1'b0}};
            bit_idx <= 4'd0;
            frame <= 10'h3ff;
        end else begin
            if (!busy) begin
                tx <= 1'b1;
                if (start) begin
                    // Frame: start(0), data[7:0] LSB first, stop(1)
                    frame <= {1'b1, data, 1'b0};
                    busy <= 1'b1;
                    bit_idx <= 4'd0;
                    ctr <= CLKS_PER_BIT - 1;
                    tx <= 1'b0; // start bit immediately
                end
            end else begin
                if (ctr == 0) begin
                    ctr <= CLKS_PER_BIT - 1;
                    bit_idx <= bit_idx + 1'b1;
                    if (bit_idx == 4'd9) begin
                        busy <= 1'b0;
                        tx <= 1'b1;
                    end else begin
                        tx <= frame[bit_idx + 1'b1];
                    end
                end else begin
                    ctr <= ctr - 1'b1;
                end
            end
        end
    end

endmodule
