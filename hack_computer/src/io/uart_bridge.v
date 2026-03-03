module uart_bridge #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD = 115_200,
    parameter integer DATA_W = 16,
    parameter integer ADDR_W = 15,
    parameter integer SCREEN_ADDR_W = 13,
    parameter integer ARG_TIMEOUT_CYCLES = (CLK_HZ / 50),
    parameter [ADDR_W-1:0] SCREEN_BASE = 15'h4000
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
    input  wire                  mem_ready,

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
    localparam [7:0] CMD_SCRDELTA = 8'h0B;
    localparam [7:0] CMD_DIAG = 8'h0C;
    localparam [7:0] CMD_SEQ   = 8'h0D;

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
    localparam [7:0] RSP_SCRDELTA = 8'h8B;
    localparam [7:0] RSP_DIAG  = 8'h8C;
    localparam [7:0] RSP_SEQ   = 8'h8D;
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
    localparam [4:0] S_SCR_RD_SETUP  = 5'd13;
    localparam [4:0] S_SCR_RD_WAIT   = 5'd14;
    localparam [4:0] S_SCR_RD_PROC   = 5'd15;
    localparam [4:0] S_STEP_PREP     = 5'd16;
    localparam [4:0] S_STEP_EXEC     = 5'd17;
    localparam [4:0] S_RUN_PREP      = 5'd18;
    localparam [4:0] S_RESP_WRAP     = 5'd19;
    localparam [4:0] S_MEM_WR_WAIT   = 5'd20;

    localparam integer RESP_CAPACITY = 80;
    localparam integer SCREEN_WORDS = (1 << SCREEN_ADDR_W);
    localparam integer ARG_TIMEOUT_SAFE = (ARG_TIMEOUT_CYCLES < 2) ? 2 : ARG_TIMEOUT_CYCLES;
    localparam integer ARG_TO_W = (ARG_TIMEOUT_SAFE <= 2) ? 2 : $clog2(ARG_TIMEOUT_SAFE);

    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_frame_err;
    wire rx_busy;

    reg tx_start = 1'b0;
    reg [7:0] tx_data = 8'h00;
    wire tx_busy;

    reg [4:0] state = S_IDLE;
    reg [7:0] cmd = 8'h00;
    reg [7:0] args [0:7];
    reg [3:0] arg_len = 4'd0;
    reg [3:0] arg_idx = 4'd0;

    reg [7:0] resp [0:RESP_CAPACITY-1];
    reg [6:0] resp_len = 7'd0;
    reg [6:0] resp_idx = 7'd0;
    reg seq_wrap_pending = 1'b0;
    reg [7:0] seq_req_id = 8'h00;
    reg [7:0] seq_req_cmd = 8'h00;
    reg [3:0] seq_req_arg_len = 4'd0;
    reg [7:0] seq_req_args [0:3];
    reg seq_last_valid = 1'b0;
    reg [7:0] seq_last_id = 8'h00;
    reg [7:0] seq_last_cmd = 8'h00;
    reg [3:0] seq_last_arg_len = 4'd0;
    reg [7:0] seq_last_args [0:3];
    reg [7:0] seq_last_resp [0:RESP_CAPACITY-1];
    reg [6:0] seq_last_resp_len = 7'd0;

    reg [31:0] run_left = 32'd0;
    reg [1:0] prep_cnt = 2'd0;
    reg [DATA_W-1:0] screen_shadow [0:SCREEN_WORDS-1];
    reg [SCREEN_ADDR_W-1:0] scr_scan_idx = {SCREEN_ADDR_W{1'b0}};
    reg [ADDR_W-1:0] scr_scan_addr = SCREEN_BASE;
    reg scr_sync_mode = 1'b0;
    reg [7:0] scr_limit = 8'd1;
    reg [7:0] scr_count = 8'd0;
    reg scr_wrapped = 1'b0;
    reg [ARG_TO_W-1:0] arg_timeout_ctr = {ARG_TO_W{1'b0}};

    reg [15:0] rx_err_count = 16'h0000;
    reg [15:0] desync_count = 16'h0000;
    reg [15:0] unknown_cmd_count = 16'h0000;

    function [6:0] scr_resp_len;
        input [7:0] count;
        reg [6:0] count4x;
        begin
            // count is clamped to <= 15, so 4*count always fits in 6 bits.
            count4x = {count[3:0], 2'b00};
            scr_resp_len = 7'd3 + count4x;
        end
    endfunction

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
                CMD_SCRDELTA: cmd_arg_len = 4'd2;
                CMD_DIAG:  cmd_arg_len = 4'd0;
                CMD_SEQ:   cmd_arg_len = 4'd6;
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
            resp_len <= 7'd8;
            resp_idx <= 7'd0;
        end
    endtask

    task load_simple_resp;
        input [7:0] b0;
        begin
            resp[0] <= b0;
            resp_len <= 7'd1;
            resp_idx <= 7'd0;
        end
    endtask

    task load_diag_resp;
        begin
            resp[0] <= RSP_DIAG;
            resp[1] <= rx_err_count[15:8];
            resp[2] <= rx_err_count[7:0];
            resp[3] <= desync_count[15:8];
            resp[4] <= desync_count[7:0];
            resp[5] <= unknown_cmd_count[15:8];
            resp[6] <= unknown_cmd_count[7:0];
            resp[7] <= 8'h01; // bit0: SEQ wrapper is supported
            resp_len <= 7'd8;
            resp_idx <= 7'd0;
        end
    endtask

    task load_seq_cached_resp;
        integer k;
        begin
            for (k = 0; k < RESP_CAPACITY; k = k + 1) begin
                resp[k] <= seq_last_resp[k];
            end
            resp_len <= seq_last_resp_len;
            resp_idx <= 7'd0;
        end
    endtask

    task wrap_seq_response;
        integer k;
        reg [6:0] old_len;
        begin
            old_len = resp_len;
            if (old_len > RESP_CAPACITY - 3) begin
                old_len = RESP_CAPACITY - 3;
            end

            seq_last_valid <= 1'b1;
            seq_last_id <= seq_req_id;
            seq_last_cmd <= seq_req_cmd;
            seq_last_arg_len <= seq_req_arg_len;
            seq_last_args[0] <= seq_req_args[0];
            seq_last_args[1] <= seq_req_args[1];
            seq_last_args[2] <= seq_req_args[2];
            seq_last_args[3] <= seq_req_args[3];
            seq_last_resp_len <= old_len + 7'd3;

            resp[0] <= RSP_SEQ;
            resp[1] <= seq_req_id;
            resp[2] <= {1'b0, old_len};
            seq_last_resp[0] <= RSP_SEQ;
            seq_last_resp[1] <= seq_req_id;
            seq_last_resp[2] <= {1'b0, old_len};

            for (k = 0; k < (RESP_CAPACITY - 3); k = k + 1) begin
                if (k < old_len) begin
                    resp[k + 3] <= resp[k];
                    seq_last_resp[k + 3] <= resp[k];
                end
            end

            resp_len <= old_len + 7'd3;
            resp_idx <= 7'd0;
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
        .frame_err(rx_frame_err),
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
            resp_len <= 7'd0;
            resp_idx <= 7'd0;
            seq_wrap_pending <= 1'b0;
            seq_req_id <= 8'h00;
            seq_req_cmd <= 8'h00;
            seq_req_arg_len <= 4'd0;
            seq_req_args[0] <= 8'h00;
            seq_req_args[1] <= 8'h00;
            seq_req_args[2] <= 8'h00;
            seq_req_args[3] <= 8'h00;
            seq_last_valid <= 1'b0;
            seq_last_id <= 8'h00;
            seq_last_cmd <= 8'h00;
            seq_last_arg_len <= 4'd0;
            seq_last_args[0] <= 8'h00;
            seq_last_args[1] <= 8'h00;
            seq_last_args[2] <= 8'h00;
            seq_last_args[3] <= 8'h00;
            seq_last_resp_len <= 7'd0;
            run_left <= 32'd0;
            prep_cnt <= 2'd0;
            scr_scan_idx <= {SCREEN_ADDR_W{1'b0}};
            scr_scan_addr <= SCREEN_BASE;
            scr_sync_mode <= 1'b0;
            scr_limit <= 8'd1;
            scr_count <= 8'd0;
            scr_wrapped <= 1'b0;
            arg_timeout_ctr <= {ARG_TO_W{1'b0}};
            rx_err_count <= 16'h0000;
            desync_count <= 16'h0000;
            unknown_cmd_count <= 16'h0000;
        end else begin
            if (rx_frame_err && (rx_err_count != 16'hFFFF)) begin
                rx_err_count <= rx_err_count + 1'b1;
            end

            case (state)
                S_IDLE: begin
                    if (rx_valid) begin
                        seq_wrap_pending <= 1'b0;
                        cmd <= rx_data;
                        arg_len <= cmd_arg_len(rx_data);
                        arg_idx <= 4'd0;
                        if (cmd_arg_len(rx_data) == 0) begin
                            state <= S_EXEC;
                        end else begin
                            arg_timeout_ctr <= ARG_TIMEOUT_SAFE - 1;
                            state <= S_RX_ARGS;
                        end
                    end
                end

                S_RX_ARGS: begin
                    if (rx_valid) begin
                        args[arg_idx] <= rx_data;
                        arg_timeout_ctr <= ARG_TIMEOUT_SAFE - 1;
                        if (arg_idx + 1 >= arg_len) begin
                            state <= S_EXEC;
                        end else begin
                            arg_idx <= arg_idx + 1'b1;
                        end
                    end else begin
                        if (arg_timeout_ctr != 0) begin
                            arg_timeout_ctr <= arg_timeout_ctr - 1'b1;
                        end else begin
                            if (desync_count != 16'hFFFF) begin
                                desync_count <= desync_count + 1'b1;
                            end
                            resp[0] <= RSP_ERR;
                            resp[1] <= 8'hFE; // malformed/partial command timeout
                            resp_len <= 7'd2;
                            resp_idx <= 7'd0;
                            arg_idx <= 4'd0;
                            arg_len <= 4'd0;
                            state <= S_RESP_WRAP;
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
                            state <= S_MEM_WR_WAIT;
                        end

                        CMD_STEP: begin
                            prep_cnt <= 2'd2;
                            state <= S_STEP_PREP;
                        end

                        CMD_RUN: begin
                            run_left <= {args[0], args[1], args[2], args[3]};
                            cpu_run_clr <= 1'b1;
                            if ({args[0], args[1], args[2], args[3]} == 32'd0) begin
                                load_status_resp(RSP_RUN);
                                state <= S_RESP_WRAP;
                            end else begin
                                prep_cnt <= 2'd2;
                                state <= S_RUN_PREP;
                            end
                        end

                        CMD_RESET: begin
                            cpu_run_clr <= 1'b1;
                            cpu_reset_pulse <= 1'b1;
                            load_simple_resp(RSP_RESET);
                            state <= S_RESP_WRAP;
                        end

                        CMD_STATE: begin
                            load_status_resp(RSP_STATE);
                            state <= S_RESP_WRAP;
                        end

                        CMD_KBD: begin
                            kbd_data <= {args[0], args[1]};
                            kbd_we <= 1'b1;
                            load_simple_resp(RSP_KBD);
                            state <= S_RESP_WRAP;
                        end

                        CMD_ROMW: begin
                            rom_addr <= to_addr({args[0], args[1]});
                            rom_wdata <= {args[2], args[3]};
                            rom_we <= 1'b1;
                            load_simple_resp(RSP_ROMW);
                            state <= S_RESP_WRAP;
                        end

                        CMD_ROMR: begin
                            rom_addr <= to_addr({args[0], args[1]});
                            rom_rd_req <= 1'b1;
                            state <= S_ROM_RD_SETUP;
                        end

                        CMD_HALT: begin
                            cpu_run_clr <= 1'b1;
                            load_simple_resp(RSP_HALT);
                            state <= S_RESP_WRAP;
                        end

                        CMD_SCRDELTA: begin
                            scr_sync_mode <= args[0][0];
                            scr_limit <= (args[1] == 8'd0) ? 8'd1 : ((args[1] > 8'd15) ? 8'd15 : args[1]);
                            scr_count <= 8'd0;
                            scr_wrapped <= 1'b0;
                            if (args[0][0]) begin
                                scr_scan_idx <= {SCREEN_ADDR_W{1'b0}};
                                scr_scan_addr <= SCREEN_BASE;
                            end
                            resp[0] <= RSP_SCRDELTA;
                            resp[1] <= 8'h00;
                            resp[2] <= 8'h00;
                            state <= S_SCR_RD_SETUP;
                        end

                        CMD_DIAG: begin
                            load_diag_resp();
                            state <= S_RESP_WRAP;
                        end

                        CMD_SEQ: begin
                            seq_req_id <= args[0];
                            seq_req_cmd <= args[1];
                            seq_req_arg_len <= cmd_arg_len(args[1]);
                            seq_req_args[0] <= args[2];
                            seq_req_args[1] <= args[3];
                            seq_req_args[2] <= args[4];
                            seq_req_args[3] <= args[5];

                            if (args[1] == CMD_SEQ) begin
                                seq_wrap_pending <= 1'b1;
                                resp[0] <= RSP_ERR;
                                resp[1] <= 8'hFD; // invalid nested sequenced command
                                resp_len <= 7'd2;
                                resp_idx <= 7'd0;
                                state <= S_RESP_WRAP;
                            end else if (seq_last_valid &&
                                (seq_last_id == args[0]) &&
                                (seq_last_cmd == args[1]) &&
                                (seq_last_arg_len == cmd_arg_len(args[1])) &&
                                (seq_last_args[0] == args[2]) &&
                                (seq_last_args[1] == args[3]) &&
                                (seq_last_args[2] == args[4]) &&
                                (seq_last_args[3] == args[5])) begin
                                seq_wrap_pending <= 1'b0;
                                load_seq_cached_resp();
                                state <= S_TX;
                            end else begin
                                seq_wrap_pending <= 1'b1;
                                cmd <= args[1];
                                arg_len <= cmd_arg_len(args[1]);
                                args[0] <= args[2];
                                args[1] <= args[3];
                                args[2] <= args[4];
                                args[3] <= args[5];
                                state <= S_EXEC;
                            end
                        end

                        default: begin
                            if (unknown_cmd_count != 16'hFFFF) begin
                                unknown_cmd_count <= unknown_cmd_count + 1'b1;
                            end
                            resp[0] <= RSP_ERR;
                            resp[1] <= cmd;
                            resp_len <= 7'd2;
                            resp_idx <= 7'd0;
                            state <= S_RESP_WRAP;
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
                    if (mem_ready) begin
                        resp[0] <= RSP_PEEK;
                        resp[1] <= mem_rdata[15:8];
                        resp[2] <= mem_rdata[7:0];
                        resp_len <= 7'd3;
                        resp_idx <= 7'd0;
                        state <= S_RESP_WRAP;
                    end
                end

                S_MEM_WR_WAIT: begin
                    mem_req <= 1'b1;
                    mem_we <= 1'b1;
                    if (mem_ready) begin
                        load_simple_resp(RSP_POKE);
                        state <= S_RESP_WRAP;
                    end
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
                    resp_len <= 7'd3;
                    resp_idx <= 7'd0;
                    state <= S_RESP_WRAP;
                end

                S_STEP_PREP: begin
                    if (prep_cnt != 0) begin
                        prep_cnt <= prep_cnt - 1'b1;
                    end else begin
                        state <= S_STEP_EXEC;
                    end
                end

                S_STEP_EXEC: begin
                    cpu_step_pulse <= 1'b1;
                    state <= S_STEP_WAIT;
                end

                S_STEP_WAIT: begin
                    state <= S_STEP_RESP;
                end

                S_STEP_RESP: begin
                    load_status_resp(RSP_STEP);
                    state <= S_RESP_WRAP;
                end

                S_RUN_PREP: begin
                    if (prep_cnt != 0) begin
                        prep_cnt <= prep_cnt - 1'b1;
                    end else begin
                        state <= S_RUN;
                    end
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
                    state <= S_RESP_WRAP;
                end

                S_SCR_RD_SETUP: begin
                    mem_addr <= scr_scan_addr;
                    mem_req <= 1'b1;
                    mem_we <= 1'b0;
                    state <= S_SCR_RD_WAIT;
                end

                S_SCR_RD_WAIT: begin
                    mem_req <= 1'b1;
                    mem_we <= 1'b0;
                    if (mem_ready) begin
                        state <= S_SCR_RD_PROC;
                    end
                end

                S_SCR_RD_PROC: begin
                    mem_req <= 1'b1;
                    mem_we <= 1'b0;

                    if ((!scr_sync_mode) && (mem_rdata != screen_shadow[scr_scan_idx]) && (scr_count >= scr_limit)) begin
                        resp[1] <= {6'b0, 1'b1, scr_wrapped}; // bit1=more, bit0=wrapped
                        resp[2] <= scr_count;
                        resp_len <= scr_resp_len(scr_count);
                        resp_idx <= 7'd0;
                        state <= S_RESP_WRAP;
                    end else begin
                        if ((!scr_sync_mode) && (mem_rdata != screen_shadow[scr_scan_idx]) && (scr_count < scr_limit)) begin
                            resp[3 + (scr_count << 2)] <= {1'b0, scr_scan_addr[ADDR_W-1:8]};
                            resp[4 + (scr_count << 2)] <= scr_scan_addr[7:0];
                            resp[5 + (scr_count << 2)] <= mem_rdata[15:8];
                            resp[6 + (scr_count << 2)] <= mem_rdata[7:0];
                            scr_count <= scr_count + 1'b1;
                        end

                        screen_shadow[scr_scan_idx] <= mem_rdata;

                        if (scr_scan_idx == SCREEN_WORDS - 1) begin
                            scr_scan_idx <= {SCREEN_ADDR_W{1'b0}};
                            scr_scan_addr <= SCREEN_BASE;
                            scr_wrapped <= 1'b1;
                            resp[1] <= {6'b0, 1'b0, 1'b1}; // bit1=more, bit0=wrapped
                            resp[2] <= ((!scr_sync_mode) &&
                                        (mem_rdata != screen_shadow[scr_scan_idx]) &&
                                        (scr_count < scr_limit)) ? (scr_count + 1'b1) : scr_count;
                            resp_len <= scr_resp_len(((!scr_sync_mode) &&
                                                      (mem_rdata != screen_shadow[scr_scan_idx]) &&
                                                      (scr_count < scr_limit)) ? (scr_count + 1'b1) : scr_count);
                            resp_idx <= 7'd0;
                            state <= S_RESP_WRAP;
                        end else begin
                            scr_scan_idx <= scr_scan_idx + 1'b1;
                            scr_scan_addr <= scr_scan_addr + 1'b1;
                            state <= S_SCR_RD_SETUP;
                        end
                    end
                end

                S_RESP_WRAP: begin
                    if (seq_wrap_pending) begin
                        wrap_seq_response();
                        seq_wrap_pending <= 1'b0;
                    end
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
