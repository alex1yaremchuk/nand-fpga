module ram64_struct #(
    parameter integer WIDTH = 8
)(
    input  wire             clk,
    input  wire             load,
    input  wire [5:0]       addr,
    input  wire [WIDTH-1:0] d,
    output wire [WIDTH-1:0] q
);

    wire [2:0] bank = addr[5:3];
    wire [2:0] offs = addr[2:0];

    wire [WIDTH-1:0] q0;
    wire [WIDTH-1:0] q1;
    wire [WIDTH-1:0] q2;
    wire [WIDTH-1:0] q3;
    wire [WIDTH-1:0] q4;
    wire [WIDTH-1:0] q5;
    wire [WIDTH-1:0] q6;
    wire [WIDTH-1:0] q7;

    ram8_struct #(.WIDTH(WIDTH)) u_ram8_0 (.clk(clk), .load(load & (bank == 3'd0)), .addr(offs), .d(d), .q(q0));
    ram8_struct #(.WIDTH(WIDTH)) u_ram8_1 (.clk(clk), .load(load & (bank == 3'd1)), .addr(offs), .d(d), .q(q1));
    ram8_struct #(.WIDTH(WIDTH)) u_ram8_2 (.clk(clk), .load(load & (bank == 3'd2)), .addr(offs), .d(d), .q(q2));
    ram8_struct #(.WIDTH(WIDTH)) u_ram8_3 (.clk(clk), .load(load & (bank == 3'd3)), .addr(offs), .d(d), .q(q3));
    ram8_struct #(.WIDTH(WIDTH)) u_ram8_4 (.clk(clk), .load(load & (bank == 3'd4)), .addr(offs), .d(d), .q(q4));
    ram8_struct #(.WIDTH(WIDTH)) u_ram8_5 (.clk(clk), .load(load & (bank == 3'd5)), .addr(offs), .d(d), .q(q5));
    ram8_struct #(.WIDTH(WIDTH)) u_ram8_6 (.clk(clk), .load(load & (bank == 3'd6)), .addr(offs), .d(d), .q(q6));
    ram8_struct #(.WIDTH(WIDTH)) u_ram8_7 (.clk(clk), .load(load & (bank == 3'd7)), .addr(offs), .d(d), .q(q7));

    assign q = (bank == 3'd0) ? q0 :
               (bank == 3'd1) ? q1 :
               (bank == 3'd2) ? q2 :
               (bank == 3'd3) ? q3 :
               (bank == 3'd4) ? q4 :
               (bank == 3'd5) ? q5 :
               (bank == 3'd6) ? q6 : q7;

endmodule
