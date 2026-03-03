module memory_map_ddr3 #(
    parameter integer WIDTH = 16,
    parameter integer SCREEN_ADDR_W = 13
)(
    input  wire             ref_clk,
    input  wire             req,
    input  wire             load,
    input  wire [14:0]      addr,
    input  wire [WIDTH-1:0] d,
    input  wire [WIDTH-1:0] kbd_in,
    output wire [WIDTH-1:0] q,
    output wire             ready,
    output wire             core_clk,

    output wire [13:0]      ddr_addr,
    output wire [2:0]       ddr_bank,
    output wire             ddr_cs,
    output wire             ddr_ras,
    output wire             ddr_cas,
    output wire             ddr_we,
    output wire             ddr_ck,
    output wire             ddr_ck_n,
    output wire             ddr_cke,
    output wire             ddr_odt,
    output wire             ddr_reset_n,
    output wire [1:0]       ddr_dm,
    inout  wire [15:0]      ddr_dq,
    inout  wire [1:0]       ddr_dqs,
    inout  wire [1:0]       ddr_dqs_n
);

    wire sel_ram16k = (addr[14] == 1'b0); // 0x0000..0x3FFF
    wire sel_kbd = (addr == 15'h6000);    // 0x6000

    localparam [14:0] SCREEN_BASE = 15'h4000;
    wire [14:0] screen_limit = SCREEN_BASE + (15'd1 << SCREEN_ADDR_W);
    wire sel_screen = (addr >= SCREEN_BASE) & (addr < screen_limit);

    wire sel_ddr = sel_ram16k | sel_screen;
    wire ddr_req = req & sel_ddr;
    wire ddr_load = load & sel_ddr;

    wire [15:0] ddr_q;
    wire ddr_ready;

    hack_ddr3_word_store #(
        .ADDR_W(15)
    ) u_ddr_store (
        .ref_clk(ref_clk),
        .req(ddr_req),
        .load(ddr_load),
        .addr(addr),
        .d(d),
        .q(ddr_q),
        .ready(ddr_ready),
        .core_clk(core_clk),
        .init_done(),
        .ddr_addr(ddr_addr),
        .ddr_bank(ddr_bank),
        .ddr_cs(ddr_cs),
        .ddr_ras(ddr_ras),
        .ddr_cas(ddr_cas),
        .ddr_we(ddr_we),
        .ddr_ck(ddr_ck),
        .ddr_ck_n(ddr_ck_n),
        .ddr_cke(ddr_cke),
        .ddr_odt(ddr_odt),
        .ddr_reset_n(ddr_reset_n),
        .ddr_dm(ddr_dm),
        .ddr_dq(ddr_dq),
        .ddr_dqs(ddr_dqs),
        .ddr_dqs_n(ddr_dqs_n)
    );

    assign q = sel_ddr ? ddr_q :
               sel_kbd ? kbd_in :
                         {WIDTH{1'b0}};

    assign ready = !req ? 1'b1 :
                   sel_ddr ? ddr_ready :
                   1'b1;

endmodule
