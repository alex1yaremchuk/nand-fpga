module key_debounce #(
    parameter integer WIDTH = 5
)(
    input  wire             clk,
    input  wire             sample_tick,
    input  wire [WIDTH-1:0] keys_level,
    output reg  [WIDTH-1:0] stable_level = {WIDTH{1'b0}},
    output reg  [WIDTH-1:0] press_pulse = {WIDTH{1'b0}}
);

    reg [WIDTH-1:0] h0 = {WIDTH{1'b0}};
    reg [WIDTH-1:0] h1 = {WIDTH{1'b0}};
    reg [WIDTH-1:0] h2 = {WIDTH{1'b0}};
    integer i;

    always @(posedge clk) begin
        press_pulse <= {WIDTH{1'b0}};

        if (sample_tick) begin
            h2 <= h1;
            h1 <= h0;
            h0 <= keys_level;

            for (i = 0; i < WIDTH; i = i + 1) begin
                if (h0[i] & h1[i] & h2[i]) begin
                    if (!stable_level[i]) press_pulse[i] <= 1'b1;
                    stable_level[i] <= 1'b1;
                end else if ((!h0[i]) & (!h1[i]) & (!h2[i])) begin
                    stable_level[i] <= 1'b0;
                end
            end
        end
    end

endmodule
