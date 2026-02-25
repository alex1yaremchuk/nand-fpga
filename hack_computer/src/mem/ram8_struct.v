module ram8_struct #(
    parameter integer WIDTH = 8
)(
    input  wire             clk,
    input  wire             load,
    input  wire [2:0]       addr,
    input  wire [WIDTH-1:0] d,
    output wire [WIDTH-1:0] q
);

    wire [WIDTH-1:0] q0;
    wire [WIDTH-1:0] q1;
    wire [WIDTH-1:0] q2;
    wire [WIDTH-1:0] q3;
    wire [WIDTH-1:0] q4;
    wire [WIDTH-1:0] q5;
    wire [WIDTH-1:0] q6;
    wire [WIDTH-1:0] q7;

    register_n #(.WIDTH(WIDTH)) u_reg0 (.clk(clk), .load(load & (addr == 3'd0)), .d(d), .q(q0));
    register_n #(.WIDTH(WIDTH)) u_reg1 (.clk(clk), .load(load & (addr == 3'd1)), .d(d), .q(q1));
    register_n #(.WIDTH(WIDTH)) u_reg2 (.clk(clk), .load(load & (addr == 3'd2)), .d(d), .q(q2));
    register_n #(.WIDTH(WIDTH)) u_reg3 (.clk(clk), .load(load & (addr == 3'd3)), .d(d), .q(q3));
    register_n #(.WIDTH(WIDTH)) u_reg4 (.clk(clk), .load(load & (addr == 3'd4)), .d(d), .q(q4));
    register_n #(.WIDTH(WIDTH)) u_reg5 (.clk(clk), .load(load & (addr == 3'd5)), .d(d), .q(q5));
    register_n #(.WIDTH(WIDTH)) u_reg6 (.clk(clk), .load(load & (addr == 3'd6)), .d(d), .q(q6));
    register_n #(.WIDTH(WIDTH)) u_reg7 (.clk(clk), .load(load & (addr == 3'd7)), .d(d), .q(q7));

    assign q = (addr == 3'd0) ? q0 :
               (addr == 3'd1) ? q1 :
               (addr == 3'd2) ? q2 :
               (addr == 3'd3) ? q3 :
               (addr == 3'd4) ? q4 :
               (addr == 3'd5) ? q5 :
               (addr == 3'd6) ? q6 : q7;

endmodule
