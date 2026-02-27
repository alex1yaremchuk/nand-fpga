module uart_bridge #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD = 115_200,
    parameter integer DATA_W = 16,
    parameter integer ADDR_W = 15
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  uart_rx,
    output wire                  uart_tx,

    input  wire [ADDR_W-1:0]     cpu_pc,
    input  wire [ADDR_W-1:0]     cpu_a,
    input  wire [DATA_W-1:0]     cpu_d,
    input  wire                  cpu_run_en,

    output reg                   cpu_step_pulse = 1'b0,
    output reg                   cpu_reset_pulse = 1'b0,
    output reg                   cpu_run_set = 1'b0,
    output reg                   cpu_run_clr = 1'b0,

    output reg                   mem_req = 1'b0,
    output reg                   mem_we = 1'b0,
    output reg [ADDR_W-1:0]      mem_addr = {ADDR_W{1'b0}},
    output reg [DATA_W-1:0]      mem_wdata = {DATA_W{1'b0}},
    input  wire [DATA_W-1:0]     mem_rdata,

    output reg                   rom_we = 1'b0,
    output reg                   rom_rd_req = 1'b0,
    output reg [ADDR_W-1:0]      rom_addr = {ADDR_W{1'b0}},
    output reg [DATA_W-1:0]      rom_wdata = {DATA_W{1'b0}},
    input  wire [DATA_W-1:0]     rom_rdata,

    output reg                   kbd_we = 1'b0,
    output reg [DATA_W-1:0]      kbd_data = {DATA_W{1'b0}}
);

    localparam [7:0] CMD_PEEK  = 8'h01;
    localparam [7:0] CMD_POKE  = 8'h02;
    localparam [7:0] CMD_STEP  = 8'h03;
    localparam [7:0] CMD_RUN   = 8'h04;
    localparam [7:0] CMD_RESET = 8'h05;
    localparam [7:0] CMD_STATE = 8'h06;
    localparam [7:0] CMD_KBD   = 8'h07;
    localparam [7:0] CMD_ROMW  = 8'h08;
    localparam [7:0] CMD_ROMR  = 8'h09;
    localparam [7:0] CMD_HALT  = 8'h0A;

    localparam [7:0] RSP_PEEK  = 8'h81;
    localparam [7:0] RSP_POKE  = 8'h82;
    localparam [7:0] RSP_STEP  = 8'h83;
    localparam [7:0] RSP_RUN   = 8'h84;
    localparam [7:0] RSP_RESET = 8'h85;
    localparam [7:0] RSP_STATE = 8'h86;
    localparam [7:0] RSP_KBD   = 8'h87;
    localparam [7:0] RSP_ROMW  = 8'h88;
    localparam [7:0] RSP_ROMR  = 8'h89;
    localparam [7:0] RSP_HALT  = 8'h8A;
    localparam [7:0] RSP_ERR   = 8'hFF;

    localparam [4:0] S_IDLE          = 5'd0;
    localparam [4:0] S_RX_ARGS       = 5'd1;
    localparam [4:0] S_EXEC          = 5'd2;
    localparam [4:0] S_MEM_RD_SETUP  = 5'd3;
    localparam [4:0] S_MEM_RD_WAIT   = 5'd4;
    localparam [4:0] S_ROM_RD_SETUP  = 5'd5;
    localparam [4:0] S_ROM_RD_WAIT   = 5'd6;
    localparam [4:0] S_STEP_WAIT     = 5'd7;
    localparam [4:0] S_RUN           = 5'd8;
    localparam [4:0] S_RUN_WAIT      = 5'd9;
    localparam [4:0] S_TX            = 5'd10;
    localparam [4:0] S_STEP_RESP     = 5'd11;
    localparam [4:0] S_RUN_RESP      = 5'd12;

    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_busy;

    reg tx_start = 1'b0;
    reg [7:0] tx_data = 8'h00;
    wire tx_busy;

    reg [4:0] state = S_IDLE;
    reg [7:0] cmd = 8'h00;
    reg [7:0] args [0:7];
    reg [3:0] arg_len = 4'd0;
    reg [3:0] arg_idx = 4'd0;

    reg [7:0] resp [0:15];
    reg [3:0] resp_len = 4'd0;
    reg [3:0] resp_idx = 4'd0;

    reg [31:0] run_left = 32'd0;

    function [3:0] cmd_arg_len;
        input [7:0] c;
        begin
            case (c)
                CMD_PEEK:  cmd_arg_len = 4'd2;
                CMD_POKE:  cmd_arg_len = 4'd4;
                CMD_STEP:  cmd_arg_len = 4'd0;
                CMD_RUN:   cmd_arg_len = 4'd4;
                CMD_RESET: cmd_arg_len = 4'd0;
                CMD_STATE: cmd_arg_len = 4'd0;
                CMD_KBD:   cmd_arg_len = 4'd2;
                CMD_ROMW:  cmd_arg_len = 4'd4;
                CMD_ROMR:  cmd_arg_len = 4'd2;
                CMD_HALT:  cmd_arg_len = 4'd0;
                default:   cmd_arg_len = 4'd0;
            endcase
        end
    endfunction

    function [ADDR_W-1:0] to_addr;
        input [15:0] v;
        begin
            to_addr = v[ADDR_W-1:0];
        end
    endfunction

    task load_status_resp;
        input [7:0] rsp_code;
        begin
            resp[0] <= rsp_code;
            resp[1] <= {1'b0, cpu_pc[ADDR_W-1:8]};
            resp[2] <= cpu_pc[7:0];
            resp[3] <= {1'b0, cpu_a[ADDR_W-1:8]};
            resp[4] <= cpu_a[7:0];
            resp[5] <= cpu_d[15:8];
            resp[6] <= cpu_d[7:0];
            resp[7] <= {7'b0, cpu_run_en};
            resp_len <= 4'd8;
            resp_idx <= 4'd0;
        end
    endtask

    task load_simple_resp;
        input [7:0] b0;
        begin
            resp[0] <= b0;
            resp_len <= 4'd1;
            resp_idx <= 4'd0;
        end
    endtask

    uart_rx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) u_rx (
        .clk(clk),
        .rst(rst),
        .rx(uart_rx),
        .data(rx_data),
        .valid(rx_valid),
        .busy(rx_busy)
    );

    uart_tx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) u_tx (
        .clk(clk),
        .rst(rst),
        .start(tx_start),
        .data(tx_data),
        .tx(uart_tx),
        .busy(tx_busy)
    );

    always @(posedge clk) begin
        tx_start <= 1'b0;

        cpu_step_pulse <= 1'b0;
        cpu_reset_pulse <= 1'b0;
        cpu_run_set <= 1'b0;
        cpu_run_clr <= 1'b0;

        mem_req <= 1'b0;
        mem_we <= 1'b0;

        rom_we <= 1'b0;
        rom_rd_req <= 1'b0;

        kbd_we <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            cmd <= 8'h00;
            arg_len <= 4'd0;
            arg_idx <= 4'd0;
            resp_len <= 4'd0;
            resp_idx <= 4'd0;
            run_left <= 32'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (rx_valid) begin
                        cmd <= rx_data;
                        arg_len <= cmd_arg_len(rx_data);
                        arg_idx <= 4'd0;
                        if (cmd_arg_len(rx_data) == 0) begin
                            state <= S_EXEC;
                        end else begin
                            state <= S_RX_ARGS;
                        end
                    end
                end

                S_RX_ARGS: begin
                    if (rx_valid) begin
                        args[arg_idx] <= rx_data;
                        if (arg_idx + 1 >= arg_len) begin
                            state <= S_EXEC;
                        end else begin
                            arg_idx <= arg_idx + 1'b1;
                        end
                    end
                end

                S_EXEC: begin
                    case (cmd)
                        CMD_PEEK: begin
                            mem_addr <= to_addr({args[0], args[1]});
                            mem_req <= 1'b1;
                            mem_we <= 1'b0;
                            state <= S_MEM_RD_SETUP;
                        end

                        CMD_POKE: begin
                            mem_addr <= to_addr({args[0], args[1]});
                            mem_wdata <= {args[2], args[3]};
                            mem_req <= 1'b1;
                            mem_we <= 1'b1;
                            load_simple_resp(RSP_POKE);
                            state <= S_TX;
                        end

                        CMD_STEP: begin
                            cpu_step_pulse <= 1'b1;
                            state <= S_STEP_WAIT;
                        end

                        CMD_RUN: begin
                            run_left <= {args[0], args[1], args[2], args[3]};
                            cpu_run_clr <= 1'b1;
                            if ({args[0], args[1], args[2], args[3]} == 32'd0) begin
                                load_status_resp(RSP_RUN);
                                state <= S_TX;
                            end else begin
                                state <= S_RUN;
                            end
                        end

                        CMD_RESET: begin
                            cpu_run_clr <= 1'b1;
                            cpu_reset_pulse <= 1'b1;
                            load_simple_resp(RSP_RESET);
                            state <= S_TX;
                        end

                        CMD_STATE: begin
                            load_status_resp(RSP_STATE);
                            state <= S_TX;
                        end

                        CMD_KBD: begin
                            kbd_data <= {args[0], args[1]};
                            kbd_we <= 1'b1;
                            load_simple_resp(RSP_KBD);
                            state <= S_TX;
                        end

                        CMD_ROMW: begin
                            rom_addr <= to_addr({args[0], args[1]});
                            rom_wdata <= {args[2], args[3]};
                            rom_we <= 1'b1;
                            load_simple_resp(RSP_ROMW);
                            state <= S_TX;
                        end

                        CMD_ROMR: begin
                            rom_addr <= to_addr({args[0], args[1]});
                            rom_rd_req <= 1'b1;
                            state <= S_ROM_RD_SETUP;
                        end

                        CMD_HALT: begin
                            cpu_run_clr <= 1'b1;
                            load_simple_resp(RSP_HALT);
                            state <= S_TX;
                        end

                        default: begin
                            resp[0] <= RSP_ERR;
                            resp[1] <= cmd;
                            resp_len <= 4'd2;
                            resp_idx <= 4'd0;
                            state <= S_TX;
                        end
                    endcase
                end

                S_MEM_RD_SETUP: begin
                    mem_req <= 1'b1;
                    mem_we <= 1'b0;
                    state <= S_MEM_RD_WAIT;
                end

                S_MEM_RD_WAIT: begin
                    mem_req <= 1'b1;
                    mem_we <= 1'b0;
                    resp[0] <= RSP_PEEK;
                    resp[1] <= mem_rdata[15:8];
                    resp[2] <= mem_rdata[7:0];
                    resp_len <= 4'd3;
                    resp_idx <= 4'd0;
                    state <= S_TX;
                end

                S_ROM_RD_SETUP: begin
                    rom_rd_req <= 1'b1;
                    state <= S_ROM_RD_WAIT;
                end

                S_ROM_RD_WAIT: begin
                    rom_rd_req <= 1'b1;
                    resp[0] <= RSP_ROMR;
                    resp[1] <= rom_rdata[15:8];
                    resp[2] <= rom_rdata[7:0];
                    resp_len <= 4'd3;
                    resp_idx <= 4'd0;
                    state <= S_TX;
                end

                S_STEP_WAIT: begin
                    state <= S_STEP_RESP;
                end

                S_STEP_RESP: begin
                    load_status_resp(RSP_STEP);
                    state <= S_TX;
                end

                S_RUN: begin
                    if (run_left != 0) begin
                        cpu_step_pulse <= 1'b1;
                        run_left <= run_left - 1'b1;
                        if (run_left == 32'd1) begin
                            state <= S_RUN_WAIT;
                        end
                    end else begin
                        state <= S_RUN_WAIT;
                    end
                end

                S_RUN_WAIT: begin
                    state <= S_RUN_RESP;
                end

                S_RUN_RESP: begin
                    load_status_resp(RSP_RUN);
                    state <= S_TX;
                end

                S_TX: begin
                    // Guard against one-cycle tx_busy latency in simulation:
                    // only enqueue a new byte when previous tx_start pulse has cleared.
                    if (!tx_busy && !tx_start && (resp_idx < resp_len)) begin
                        tx_data <= resp[resp_idx];
                        tx_start <= 1'b1;
                        resp_idx <= resp_idx + 1'b1;
                    end
                    if ((resp_idx >= resp_len) && !tx_busy && !tx_start) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
