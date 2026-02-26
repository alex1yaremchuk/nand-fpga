module ram16k_select #(
    parameter integer WIDTH = 8,
    parameter integer USE_BRAM = 1,
    parameter integer RAM4K_USE_BRAM = 1
)(
    input  wire             clk,
    input  wire             load,
    input  wire [13:0]      addr,
    input  wire [WIDTH-1:0] d,
    output wire [WIDTH-1:0] q
);

    wire [WIDTH-1:0] q_i;
    assign q = q_i;

    generate
        if (USE_BRAM != 0) begin : g_bram
            ram_bram #(
                .WIDTH(WIDTH),
                .ADDR_W(14)
            ) u_bram (
                .clk(clk),
                .load(load),
                .addr(addr),
                .d(d),
                .q(q_i)
            );
        end else begin : g_struct
            wire [1:0] bank = addr[13:12];
            wire [11:0] offs = addr[11:0];

            wire [WIDTH-1:0] q0;
            wire [WIDTH-1:0] q1;
            wire [WIDTH-1:0] q2;
            wire [WIDTH-1:0] q3;

            ram4k_select #(
                .WIDTH(WIDTH),
                .USE_BRAM(RAM4K_USE_BRAM)
            ) u_ram4k_0 (
                .clk(clk),
                .load(load & (bank == 2'd0)),
                .addr(offs),
                .d(d),
                .q(q0)
            );

            ram4k_select #(
                .WIDTH(WIDTH),
                .USE_BRAM(RAM4K_USE_BRAM)
            ) u_ram4k_1 (
                .clk(clk),
                .load(load & (bank == 2'd1)),
                .addr(offs),
                .d(d),
                .q(q1)
            );

            ram4k_select #(
                .WIDTH(WIDTH),
                .USE_BRAM(RAM4K_USE_BRAM)
            ) u_ram4k_2 (
                .clk(clk),
                .load(load & (bank == 2'd2)),
                .addr(offs),
                .d(d),
                .q(q2)
            );

            ram4k_select #(
                .WIDTH(WIDTH),
                .USE_BRAM(RAM4K_USE_BRAM)
            ) u_ram4k_3 (
                .clk(clk),
                .load(load & (bank == 2'd3)),
                .addr(offs),
                .d(d),
                .q(q3)
            );

            assign q_i = (bank == 2'd0) ? q0 :
                         (bank == 2'd1) ? q1 :
                         (bank == 2'd2) ? q2 : q3;
        end
    endgenerate

endmodule
