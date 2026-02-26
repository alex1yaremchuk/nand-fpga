module ram4k_select #(
    parameter integer WIDTH = 8,
    parameter integer USE_BRAM = 0
)(
    input  wire             clk,
    input  wire             load,
    input  wire [11:0]      addr,
    input  wire [WIDTH-1:0] d,
    output wire [WIDTH-1:0] q
);

    wire [WIDTH-1:0] q_i;
    assign q = q_i;

    generate
        if (USE_BRAM != 0) begin : g_bram
            ram_bram #(
                .WIDTH(WIDTH),
                .ADDR_W(12)
            ) u_bram (
                .clk(clk),
                .load(load),
                .addr(addr),
                .d(d),
                .q(q_i)
            );
        end else begin : g_struct
            wire [2:0] bank = addr[11:9];
            wire [8:0] offs = addr[8:0];

            wire [WIDTH-1:0] q0;
            wire [WIDTH-1:0] q1;
            wire [WIDTH-1:0] q2;
            wire [WIDTH-1:0] q3;
            wire [WIDTH-1:0] q4;
            wire [WIDTH-1:0] q5;
            wire [WIDTH-1:0] q6;
            wire [WIDTH-1:0] q7;

            ram512_struct #(.WIDTH(WIDTH)) u_ram512_0 (.clk(clk), .load(load & (bank == 3'd0)), .addr(offs), .d(d), .q(q0));
            ram512_struct #(.WIDTH(WIDTH)) u_ram512_1 (.clk(clk), .load(load & (bank == 3'd1)), .addr(offs), .d(d), .q(q1));
            ram512_struct #(.WIDTH(WIDTH)) u_ram512_2 (.clk(clk), .load(load & (bank == 3'd2)), .addr(offs), .d(d), .q(q2));
            ram512_struct #(.WIDTH(WIDTH)) u_ram512_3 (.clk(clk), .load(load & (bank == 3'd3)), .addr(offs), .d(d), .q(q3));
            ram512_struct #(.WIDTH(WIDTH)) u_ram512_4 (.clk(clk), .load(load & (bank == 3'd4)), .addr(offs), .d(d), .q(q4));
            ram512_struct #(.WIDTH(WIDTH)) u_ram512_5 (.clk(clk), .load(load & (bank == 3'd5)), .addr(offs), .d(d), .q(q5));
            ram512_struct #(.WIDTH(WIDTH)) u_ram512_6 (.clk(clk), .load(load & (bank == 3'd6)), .addr(offs), .d(d), .q(q6));
            ram512_struct #(.WIDTH(WIDTH)) u_ram512_7 (.clk(clk), .load(load & (bank == 3'd7)), .addr(offs), .d(d), .q(q7));

            assign q_i = (bank == 3'd0) ? q0 :
                         (bank == 3'd1) ? q1 :
                         (bank == 3'd2) ? q2 :
                         (bank == 3'd3) ? q3 :
                         (bank == 3'd4) ? q4 :
                         (bank == 3'd5) ? q5 :
                         (bank == 3'd6) ? q6 : q7;
        end
    endgenerate

endmodule
