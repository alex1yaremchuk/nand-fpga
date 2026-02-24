module app_timing #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer KEYS_PERIOD_MS = 50,
    parameter integer INIT_PERIOD_MS = 500
)(
    input  wire clk,
    output reg  tick_1ms = 0,
    output reg  init_req = 0,
    output reg  keys_req = 0
);

    localparam integer TICKS_PER_MS = (CLK_HZ / 1000);
    localparam integer DIV_W = (TICKS_PER_MS <= 2) ? 2 : $clog2(TICKS_PER_MS);
    localparam integer KEYS_W = (KEYS_PERIOD_MS <= 2) ? 2 : $clog2(KEYS_PERIOD_MS);
    localparam integer INIT_W = (INIT_PERIOD_MS <= 2) ? 2 : $clog2(INIT_PERIOD_MS);

    reg [DIV_W-1:0]  ms_div = 0;
    reg [KEYS_W-1:0] keys_ms = 0;
    reg [INIT_W-1:0] init_ms = 0;

    always @(posedge clk) begin
        tick_1ms <= 1'b0;
        init_req <= 1'b0;
        keys_req <= 1'b0;

        if (ms_div == TICKS_PER_MS - 1) begin
            ms_div <= 0;
            tick_1ms <= 1'b1;

            if (init_ms == INIT_PERIOD_MS - 1) begin
                init_ms <= 0;
                init_req <= 1'b1;
            end else begin
                init_ms <= init_ms + 1'b1;
            end

            if (keys_ms == KEYS_PERIOD_MS - 1) begin
                keys_ms <= 0;
                keys_req <= 1'b1;
            end else begin
                keys_ms <= keys_ms + 1'b1;
            end
        end else begin
            ms_div <= ms_div + 1'b1;
        end
    end

endmodule
