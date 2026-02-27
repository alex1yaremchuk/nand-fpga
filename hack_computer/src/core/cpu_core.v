module cpu_core #(
    parameter integer DATA_W = 16,
    parameter integer ADDR_W = 15
)(
    input  wire                  clk,
    input  wire                  reset,
    input  wire                  step,
    input  wire [DATA_W-1:0]     instr,
    input  wire [DATA_W-1:0]     inM,
    output wire [DATA_W-1:0]     outM,
    output wire                  writeM,
    output wire [ADDR_W-1:0]     addressM,
    output wire [ADDR_W-1:0]     pc,
    output wire [ADDR_W-1:0]     a_dbg,
    output wire [DATA_W-1:0]     d_dbg
);

    reg [ADDR_W-1:0] a_reg = {ADDR_W{1'b0}};
    reg [DATA_W-1:0] d_reg = {DATA_W{1'b0}};
    reg [ADDR_W-1:0] pc_reg = {ADDR_W{1'b0}};

    wire instr_is_a = ~instr[15];
    wire instr_is_c = instr[15];

    wire comp_a = instr[12];
    wire [5:0] comp = instr[11:6];
    wire [2:0] dest = instr[5:3];
    wire [2:0] jump = instr[2:0];

    wire [DATA_W-1:0] x0 = d_reg;
    wire [DATA_W-1:0] y0 = comp_a ? inM : {{(DATA_W-ADDR_W){1'b0}}, a_reg};

    wire [DATA_W-1:0] x1 = comp[5] ? {DATA_W{1'b0}} : x0; // zx
    wire [DATA_W-1:0] x2 = comp[4] ? ~x1 : x1;            // nx
    wire [DATA_W-1:0] y1 = comp[3] ? {DATA_W{1'b0}} : y0; // zy
    wire [DATA_W-1:0] y2 = comp[2] ? ~y1 : y1;            // ny

    wire [DATA_W-1:0] f_out = comp[1] ? (x2 + y2) : (x2 & y2); // f
    wire [DATA_W-1:0] alu_out = comp[0] ? ~f_out : f_out;       // no

    wire alu_zr = (alu_out == {DATA_W{1'b0}});
    wire alu_ng = alu_out[DATA_W-1];

    wire jlt = jump[2] & alu_ng;
    wire jeq = jump[1] & alu_zr;
    wire jgt = jump[0] & (~alu_ng & ~alu_zr);
    wire do_jump = instr_is_c & (jlt | jeq | jgt);

    wire load_a = step & (instr_is_a | (instr_is_c & dest[2]));
    wire load_d = step & instr_is_c & dest[1];

    assign outM = alu_out;
    assign writeM = step & instr_is_c & dest[0];
    assign addressM = a_reg;
    assign pc = pc_reg;
    assign a_dbg = a_reg;
    assign d_dbg = d_reg;

    always @(posedge clk) begin
        if (reset) begin
            a_reg <= {ADDR_W{1'b0}};
            d_reg <= {DATA_W{1'b0}};
            pc_reg <= {ADDR_W{1'b0}};
        end else if (step) begin
            if (load_a) begin
                if (instr_is_a) begin
                    a_reg <= instr[ADDR_W-1:0];
                end else begin
                    a_reg <= alu_out[ADDR_W-1:0];
                end
            end

            if (load_d) begin
                d_reg <= alu_out;
            end

            if (do_jump) begin
                pc_reg <= a_reg;
            end else begin
                pc_reg <= pc_reg + {{(ADDR_W-1){1'b0}}, 1'b1};
            end
        end
    end

endmodule
