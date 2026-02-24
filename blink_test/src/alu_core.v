module alu_core #(
    parameter integer DATA_W = 8
)(
    input  wire [DATA_W-1:0] a,
    input  wire [DATA_W-1:0] b,
    input  wire [3:0]        op,
    output reg  [DATA_W-1:0] y,
    output reg               carry_out,
    output reg               overflow,
    output wire              zr,
    output wire              ng
);

    reg [DATA_W:0] tmp;
    localparam integer MSB = DATA_W - 1;

    always @(*) begin
        y = {DATA_W{1'b0}};
        carry_out = 1'b0;
        overflow = 1'b0;
        tmp = {(DATA_W+1){1'b0}};

        case (op)
            4'h0: begin y = a; end
            4'h1: begin y = b; end
            4'h2: begin
                tmp = {1'b0, a} + {1'b0, b};
                y = tmp[DATA_W-1:0];
                carry_out = tmp[DATA_W];
                overflow = (~(a[MSB] ^ b[MSB])) & (a[MSB] ^ y[MSB]);
            end
            4'h3: begin
                tmp = {1'b0, a} + {1'b0, ~b} + {{DATA_W{1'b0}}, 1'b1};
                y = tmp[DATA_W-1:0];
                carry_out = tmp[DATA_W];
                overflow = (a[MSB] ^ b[MSB]) & (a[MSB] ^ y[MSB]);
            end
            4'h4: begin y = a & b; end
            4'h5: begin y = a | b; end
            4'h6: begin y = a ^ b; end
            4'h7: begin y = ~a; end
            4'h8: begin y = a << 1; carry_out = a[MSB]; end
            4'h9: begin y = a >> 1; carry_out = a[0]; end
            4'hA: begin
                tmp = {1'b0, a} + {{DATA_W{1'b0}}, 1'b1};
                y = tmp[DATA_W-1:0];
                carry_out = tmp[DATA_W];
                overflow = (~a[MSB]) & y[MSB];
            end
            4'hB: begin
                tmp = {1'b0, a} + {1'b0, {DATA_W{1'b1}}};
                y = tmp[DATA_W-1:0];
                carry_out = tmp[DATA_W];
                overflow = a[MSB] & (~y[MSB]);
            end
            4'hC: begin
                tmp = {1'b0, ~a} + {{DATA_W{1'b0}}, 1'b1};
                y = tmp[DATA_W-1:0];
                carry_out = tmp[DATA_W];
                overflow = (a == ({1'b1, {MSB{1'b0}}}));
            end
            4'hD: begin y = (a == b) ? {{(DATA_W-1){1'b0}}, 1'b1} : {DATA_W{1'b0}}; end
            4'hE: begin y = ($signed(a) < $signed(b)) ? {{(DATA_W-1){1'b0}}, 1'b1} : {DATA_W{1'b0}}; end
            4'hF: begin y = ~(a & b); end
            default: begin y = {DATA_W{1'b0}}; end
        endcase
    end

    assign zr = (y == {DATA_W{1'b0}});
    assign ng = y[MSB];

endmodule
