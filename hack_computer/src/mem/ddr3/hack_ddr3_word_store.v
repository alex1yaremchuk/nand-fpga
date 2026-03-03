module hack_ddr3_word_store #(
    parameter integer ADDR_W = 15
)(
    input  wire             ref_clk,
    input  wire             req,
    input  wire             load,
    input  wire [ADDR_W-1:0] addr,
    input  wire [15:0]      d,
    output wire [15:0]      q,
    output wire             ready,
    output wire             core_clk,
    output wire             init_done,

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

    localparam [2:0] CMD_WR = 3'b000;
    localparam [2:0] CMD_RD = 3'b001;
    localparam integer LINE_ADDR_W = ADDR_W - 3;

    wire memory_clk;
    wire pll_lock;
    wire cmd_ready;
    wire wr_data_rdy;
    wire [127:0] rd_data;
    wire rd_data_valid;
    wire rd_data_end;
    wire clk_out;
    wire ddr_rst_unused;
    wire sr_ack_unused;
    wire ref_ack_unused;
    wire o_ddr_cs_n;

    reg [2:0] app_cmd = 3'b000;
    reg app_cmd_en = 1'b0;
    reg [27:0] app_addr = 28'h0;
    reg [127:0] app_wr_data = 128'h0;
    reg app_wr_data_en = 1'b0;
    reg app_wr_data_end = 1'b0;
    reg [15:0] app_wr_mask = 16'hFFFF;

    reg line_valid = 1'b0;
    reg [LINE_ADDR_W-1:0] line_addr = {LINE_ADDR_W{1'b0}};
    reg [127:0] line_data = 128'h0;

    reg wr_pending = 1'b0;
    reg [ADDR_W-1:0] wr_addr = {ADDR_W{1'b0}};
    reg [15:0] wr_word = 16'h0000;

    reg rd_pending = 1'b0;
    reg [LINE_ADDR_W-1:0] rd_line_addr = {LINE_ADDR_W{1'b0}};

    wire [LINE_ADDR_W-1:0] addr_line = addr[ADDR_W-1:3];
    wire [2:0] addr_lane = addr[2:0];
    wire line_hit = line_valid && (line_addr == addr_line);

    wire [LINE_ADDR_W-1:0] wr_line = wr_addr[ADDR_W-1:3];
    wire [2:0] wr_lane = wr_addr[2:0];

    function [27:0] to_app_addr;
        input [LINE_ADDR_W-1:0] line;
        begin
            to_app_addr = {{(28-(LINE_ADDR_W+3)){1'b0}}, line, 3'b000};
        end
    endfunction

    function [15:0] get_word;
        input [127:0] line;
        input [2:0] lane;
        begin
            case (lane)
                3'd0: get_word = line[15:0];
                3'd1: get_word = line[31:16];
                3'd2: get_word = line[47:32];
                3'd3: get_word = line[63:48];
                3'd4: get_word = line[79:64];
                3'd5: get_word = line[95:80];
                3'd6: get_word = line[111:96];
                default: get_word = line[127:112];
            endcase
        end
    endfunction

    function [127:0] set_word;
        input [127:0] line;
        input [2:0] lane;
        input [15:0] word;
        reg [127:0] tmp;
        begin
            tmp = line;
            case (lane)
                3'd0: tmp[15:0] = word;
                3'd1: tmp[31:16] = word;
                3'd2: tmp[47:32] = word;
                3'd3: tmp[63:48] = word;
                3'd4: tmp[79:64] = word;
                3'd5: tmp[95:80] = word;
                3'd6: tmp[111:96] = word;
                default: tmp[127:112] = word;
            endcase
            set_word = tmp;
        end
    endfunction

    function [127:0] make_payload;
        input [2:0] lane;
        input [15:0] word;
        reg [127:0] tmp;
        begin
            tmp = 128'h0;
            case (lane)
                3'd0: tmp[15:0] = word;
                3'd1: tmp[31:16] = word;
                3'd2: tmp[47:32] = word;
                3'd3: tmp[63:48] = word;
                3'd4: tmp[79:64] = word;
                3'd5: tmp[95:80] = word;
                3'd6: tmp[111:96] = word;
                default: tmp[127:112] = word;
            endcase
            make_payload = tmp;
        end
    endfunction

    function [15:0] make_mask;
        input [2:0] lane;
        reg [15:0] m;
        begin
            m = 16'hFFFF;
            case (lane)
                3'd0: m[1:0] = 2'b00;
                3'd1: m[3:2] = 2'b00;
                3'd2: m[5:4] = 2'b00;
                3'd3: m[7:6] = 2'b00;
                3'd4: m[9:8] = 2'b00;
                3'd5: m[11:10] = 2'b00;
                3'd6: m[13:12] = 2'b00;
                default: m[15:14] = 2'b00;
            endcase
            make_mask = m;
        end
    endfunction

    assign core_clk = clk_out;
    assign q = get_word(line_data, addr_lane);
    assign ready = init_done && line_hit && !wr_pending && !rd_pending && cmd_ready && wr_data_rdy;

    // Board has a single DDR chip, so chip-select is expected active-low.
    assign ddr_cs = o_ddr_cs_n;

    Gowin_rPLL u_ddr_pll (
        .clkout(memory_clk),
        .lock(pll_lock),
        .reset(1'b0),
        .clkin(ref_clk)
    );

    DDR3_Memory_Interface_Top u_ddr3 (
        .memory_clk(memory_clk),
        .clk(ref_clk),
        .pll_lock(pll_lock),
        .rst_n(1'b1),
        .app_burst_number(6'd0),
        .cmd_ready(cmd_ready),
        .cmd(app_cmd),
        .cmd_en(app_cmd_en),
        .addr(app_addr),
        .wr_data_rdy(wr_data_rdy),
        .wr_data(app_wr_data),
        .wr_data_en(app_wr_data_en),
        .wr_data_end(app_wr_data_end),
        .wr_data_mask(app_wr_mask),
        .rd_data(rd_data),
        .rd_data_valid(rd_data_valid),
        .rd_data_end(rd_data_end),
        .sr_req(1'b0),
        .ref_req(1'b0),
        .sr_ack(sr_ack_unused),
        .ref_ack(ref_ack_unused),
        .init_calib_complete(init_done),
        .clk_out(clk_out),
        .ddr_rst(ddr_rst_unused),
        .burst(1'b1),
        .O_ddr_addr(ddr_addr),
        .O_ddr_ba(ddr_bank),
        .O_ddr_cs_n(o_ddr_cs_n),
        .O_ddr_ras_n(ddr_ras),
        .O_ddr_cas_n(ddr_cas),
        .O_ddr_we_n(ddr_we),
        .O_ddr_clk(ddr_ck),
        .O_ddr_clk_n(ddr_ck_n),
        .O_ddr_cke(ddr_cke),
        .O_ddr_odt(ddr_odt),
        .O_ddr_reset_n(ddr_reset_n),
        .O_ddr_dqm(ddr_dm),
        .IO_ddr_dq(ddr_dq),
        .IO_ddr_dqs(ddr_dqs),
        .IO_ddr_dqs_n(ddr_dqs_n)
    );

    always @(posedge core_clk) begin
        app_cmd_en <= 1'b0;
        app_wr_data_en <= 1'b0;
        app_wr_data_end <= 1'b0;

        if (!init_done) begin
            line_valid <= 1'b0;
            wr_pending <= 1'b0;
            rd_pending <= 1'b0;
        end else begin
            if (load) begin
                wr_pending <= 1'b1;
                wr_addr <= addr;
                wr_word <= d;
            end

            if (wr_pending) begin
                if (cmd_ready && wr_data_rdy) begin
                    app_cmd <= CMD_WR;
                    app_cmd_en <= 1'b1;
                    app_addr <= to_app_addr(wr_line);
                    app_wr_data <= make_payload(wr_lane, wr_word);
                    app_wr_mask <= make_mask(wr_lane);
                    app_wr_data_en <= 1'b1;
                    app_wr_data_end <= 1'b1;
                    wr_pending <= 1'b0;
                    if (line_valid && (line_addr == wr_line)) begin
                        line_data <= set_word(line_data, wr_lane, wr_word);
                    end
                end
            end else if (rd_pending) begin
                if (rd_data_valid) begin
                    line_data <= rd_data;
                    line_addr <= rd_line_addr;
                    line_valid <= 1'b1;
                    rd_pending <= 1'b0;
                end
            end else if (req && !line_hit) begin
                if (cmd_ready) begin
                    app_cmd <= CMD_RD;
                    app_cmd_en <= 1'b1;
                    app_addr <= to_app_addr(addr_line);
                    rd_line_addr <= addr_line;
                    rd_pending <= 1'b1;
                end
            end
        end
    end

endmodule
