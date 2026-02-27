module memory_map #(
    parameter integer WIDTH = 8,
    parameter integer RAM16K_USE_BRAM = 1,
    parameter integer RAM16K_RAM4K_USE_BRAM = 1,
    parameter integer USE_SCREEN_BRAM = 1,
    parameter integer SCREEN_ADDR_W = 13
)(
    input  wire             clk,
    input  wire             load,
    input  wire [14:0]      addr,
    input  wire [WIDTH-1:0] d,
    input  wire [WIDTH-1:0] kbd_in,
    output wire [WIDTH-1:0] q
);

    wire sel_ram16k = (addr[14] == 1'b0);      // 0x0000..0x3FFF
    wire sel_kbd    = (addr == 15'h6000);      // 0x6000

    // Hack screen base is 0x4000. For SCREEN_ADDR_W < 13 use a smaller
    // low-address window: 0x4000 .. (0x4000 + 2^SCREEN_ADDR_W - 1).
    localparam [14:0] SCREEN_BASE = 15'h4000;
    wire [14:0] screen_limit = SCREEN_BASE + (15'd1 << SCREEN_ADDR_W);
    wire sel_screen = (addr >= SCREEN_BASE) & (addr < screen_limit);

    wire [WIDTH-1:0] ram16k_q;
    wire [WIDTH-1:0] screen_q;

    ram16k_select #(
        .WIDTH(WIDTH),
        .USE_BRAM(RAM16K_USE_BRAM),
        .RAM4K_USE_BRAM(RAM16K_RAM4K_USE_BRAM)
    ) u_ram16k (
        .clk(clk),
        .load(load & sel_ram16k),
        .addr(addr[13:0]),
        .d(d),
        .q(ram16k_q)
    );

    generate
        if (USE_SCREEN_BRAM != 0) begin : g_screen_bram
            ram_bram #(
                .WIDTH(WIDTH),
                .ADDR_W(SCREEN_ADDR_W)
            ) u_screen (
                .clk(clk),
                .load(load & sel_screen),
                .addr(addr[SCREEN_ADDR_W-1:0]),
                .d(d),
                .q(screen_q)
            );
        end else begin : g_screen_stub
            assign screen_q = {WIDTH{1'b0}};
        end
    endgenerate

    assign q = sel_ram16k ? ram16k_q :
               sel_screen ? screen_q :
               sel_kbd    ? kbd_in :
                            {WIDTH{1'b0}};

endmodule
