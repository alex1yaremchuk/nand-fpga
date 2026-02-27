module rom32k_prog #(
    parameter integer WIDTH = 8,
    parameter integer ROM_ADDR_W = 15
)(
    input  wire             clk,
    input  wire             prog_we,
    input  wire [14:0]      prog_addr,
    input  wire [WIDTH-1:0] prog_data,
    input  wire [14:0]      rd_addr,
    output wire [WIDTH-1:0] q
);

    wire prog_in_range;
    wire rd_in_range;

    generate
        if (ROM_ADDR_W >= 15) begin : g_full_range
            assign prog_in_range = 1'b1;
            assign rd_in_range = 1'b1;
        end else begin : g_limited_range
            assign prog_in_range = (prog_addr[14:ROM_ADDR_W] == {(15-ROM_ADDR_W){1'b0}});
            assign rd_in_range = (rd_addr[14:ROM_ADDR_W] == {(15-ROM_ADDR_W){1'b0}});
        end
    endgenerate

    wire [ROM_ADDR_W-1:0] mem_addr =
        prog_we ? prog_addr[ROM_ADDR_W-1:0] : rd_addr[ROM_ADDR_W-1:0];
    wire mem_we = prog_we & prog_in_range;
    wire [WIDTH-1:0] mem_q;

    // For reduced ROM profiles, guard out-of-range access instead of wrapping.
    assign q = rd_in_range ? mem_q : {WIDTH{1'b0}};

    ram_bram #(
        .WIDTH(WIDTH),
        .ADDR_W(ROM_ADDR_W)
    ) u_rom_store (
        .clk(clk),
        .load(mem_we),
        .addr(mem_addr),
        .d(prog_data),
        .q(mem_q)
    );

endmodule
