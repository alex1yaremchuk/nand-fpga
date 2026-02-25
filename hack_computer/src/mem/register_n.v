module register_n #(
    parameter integer WIDTH = 8
)(
    input  wire             clk,
    input  wire             load,
    input  wire [WIDTH-1:0] d,
    output reg  [WIDTH-1:0] q = {WIDTH{1'b0}}
);

    always @(posedge clk) begin
        if (load) begin
            q <= d;
        end
    end

endmodule
