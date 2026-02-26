module ram_bram #(
    parameter integer WIDTH = 8,
    parameter integer ADDR_W = 9
)(
    input  wire              clk,
    input  wire              load,
    input  wire [ADDR_W-1:0] addr,
    input  wire [WIDTH-1:0]  d,
    output reg  [WIDTH-1:0]  q = {WIDTH{1'b0}}
);

    localparam integer DEPTH = (1 << ADDR_W);

    // Ask synthesizer to map this array to FPGA block RAM.
    (* syn_ramstyle = "block_ram" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

    generate
        if (DEPTH <= 2000) begin : g_init_small
            integer i;
            initial begin
                for (i = 0; i < DEPTH; i = i + 1) begin
                    mem[i] = {WIDTH{1'b0}};
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (load) begin
            mem[addr] <= d;
        end
        q <= mem[addr];
    end

endmodule
