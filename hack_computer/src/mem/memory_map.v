module memory_map #(
    parameter integer WIDTH = 8,
    parameter integer RAM16K_USE_BRAM = 1,
    parameter integer RAM16K_RAM4K_USE_BRAM = 1
)(
    input  wire             clk,
    input  wire             load,
    input  wire [14:0]      addr,
    input  wire [WIDTH-1:0] d,
    input  wire [WIDTH-1:0] kbd_in,
    output wire [WIDTH-1:0] q
);

    wire sel_ram16k  = (addr[14] == 1'b0);         // 0x0000..0x3FFF
    wire sel_screen  = (addr[14:13] == 2'b10);     // 0x4000..0x5FFF
    wire sel_kbd     = (addr == 15'h6000);         // 0x6000

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

    ram_bram #(
        .WIDTH(WIDTH),
        .ADDR_W(13)
    ) u_screen (
        .clk(clk),
        .load(load & sel_screen),
        .addr(addr[12:0]),
        .d(d),
        .q(screen_q)
    );

    assign q = sel_ram16k ? ram16k_q :
               sel_screen ? screen_q :
               sel_kbd    ? kbd_in :
                            {WIDTH{1'b0}};

endmodule
