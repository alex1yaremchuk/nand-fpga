`timescale 1ns / 1ps

module uart_bridge_tb;
    localparam integer CLK_HZ = 1_000_000;
    localparam integer BAUD = 100_000;
    localparam integer BIT_NS = 10_000;

    reg clk = 1'b0;
    reg rst = 1'b1;

    reg host_start = 1'b0;
    reg [7:0] host_data = 8'h00;
    wire host_tx; // host -> DUT RX
    wire host_busy;
    wire dut_tx;        // DUT TX -> host
    wire [7:0] host_rx_data;
    wire host_rx_valid;

    reg [14:0] cpu_pc = 15'd0;
    reg [14:0] cpu_a = 15'd0;
    reg [15:0] cpu_d = 16'h0000;
    reg cpu_run_en = 1'b0;

    wire cpu_step_pulse;
    wire cpu_reset_pulse;
    wire cpu_run_set;
    wire cpu_run_clr;

    wire mem_req;
    wire mem_we;
    wire [14:0] mem_addr;
    wire [15:0] mem_wdata;
    reg  [15:0] mem_rdata = 16'h0000;

    wire rom_we;
    wire rom_rd_req;
    wire [14:0] rom_addr;
    wire [15:0] rom_wdata;
    reg  [15:0] rom_rdata = 16'h0000;

    wire kbd_we;
    wire [15:0] kbd_data;

    reg [15:0] mem [0:32767];
    reg [15:0] rom [0:32767];

    reg [7:0] rb0;
    reg [7:0] rb1;
    reg [7:0] rb2;
    reg [7:0] rb3;
    reg [7:0] rb4;
    reg [7:0] rb5;
    reg [7:0] rb6;
    reg [7:0] rb7;
    reg [7:0] rx_fifo [0:255];
    integer rx_wr = 0;
    integer rx_rd = 0;

    integer i;

    uart_bridge #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD),
        .DATA_W(16),
        .ADDR_W(15)
    ) dut (
        .clk(clk),
        .rst(rst),
        .uart_rx(host_tx),
        .uart_tx(dut_tx),
        .cpu_pc(cpu_pc),
        .cpu_a(cpu_a),
        .cpu_d(cpu_d),
        .cpu_run_en(cpu_run_en),
        .cpu_step_pulse(cpu_step_pulse),
        .cpu_reset_pulse(cpu_reset_pulse),
        .cpu_run_set(cpu_run_set),
        .cpu_run_clr(cpu_run_clr),
        .mem_req(mem_req),
        .mem_we(mem_we),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata),
        .rom_we(rom_we),
        .rom_rd_req(rom_rd_req),
        .rom_addr(rom_addr),
        .rom_wdata(rom_wdata),
        .rom_rdata(rom_rdata),
        .kbd_we(kbd_we),
        .kbd_data(kbd_data)
    );

    uart_tx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) u_host_tx (
        .clk(clk),
        .rst(rst),
        .start(host_start),
        .data(host_data),
        .tx(host_tx),
        .busy(host_busy)
    );

    uart_rx #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD)
    ) u_host_rx (
        .clk(clk),
        .rst(rst),
        .rx(dut_tx),
        .data(host_rx_data),
        .valid(host_rx_valid),
        .busy()
    );

    always #500 clk = ~clk; // 1MHz

    // Simple synchronous memory/ROM model.
    always @(posedge clk) begin
        if (mem_req) begin
            if (mem_we) begin
                mem[mem_addr] <= mem_wdata;
            end
            mem_rdata <= mem[mem_addr];
        end

        if (rom_we) begin
            rom[rom_addr] <= rom_wdata;
        end
        if (rom_rd_req) begin
            rom_rdata <= rom[rom_addr];
        end

        if (cpu_reset_pulse) begin
            cpu_pc <= 15'd0;
            cpu_a <= 15'd0;
            cpu_d <= 16'h0000;
            cpu_run_en <= 1'b0;
        end else begin
            if (cpu_run_set) cpu_run_en <= 1'b1;
            if (cpu_run_clr) cpu_run_en <= 1'b0;
            if (cpu_step_pulse) begin
                cpu_pc <= cpu_pc + 1'b1;
                cpu_a <= cpu_a + 1'b1;
                cpu_d <= cpu_d + 16'h0010;
            end
        end

        if (host_rx_valid) begin
            rx_fifo[rx_wr[7:0]] <= host_rx_data;
            rx_wr <= rx_wr + 1;
        end
    end

    task expect_true;
        input cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                $display("FAIL: %0s (t=%0t)", msg, $time);
                $fatal(1);
            end
        end
    endtask

    task uart_send_byte;
        input [7:0] b;
        begin
            @(posedge clk);
            host_data <= b;
            host_start <= 1'b1;
            @(posedge clk);
            host_start <= 1'b0;
            wait (host_busy == 1'b1);
            wait (host_busy == 1'b0);
        end
    endtask

    task uart_recv_byte;
        output [7:0] b;
        integer tmo;
        begin
            tmo = 0;
            while (rx_rd >= rx_wr) begin
                #(BIT_NS/8);
                tmo = tmo + 1;
                if (tmo > 2000) begin
                    $display("FAIL: UART RX timeout waiting for byte (t=%0t)", $time);
                    $fatal(1);
                end
            end
            b = rx_fifo[rx_rd[7:0]];
            rx_rd = rx_rd + 1;
        end
    endtask

    initial begin
        for (i = 0; i < 32768; i = i + 1) begin
            mem[i] = 16'h0000;
            rom[i] = 16'h0000;
        end

        #(BIT_NS * 4);
        rst = 1'b0;
        #(BIT_NS * 4);

        // POKE 0x0002 <- 0x1234
        uart_send_byte(8'h02);
        uart_send_byte(8'h00);
        uart_send_byte(8'h02);
        uart_send_byte(8'h12);
        uart_send_byte(8'h34);
        uart_recv_byte(rb0);
        expect_true(rb0 == 8'h82, "POKE response");
        expect_true(mem[15'h0002] == 16'h1234, "POKE write data");

        // PEEK 0x0002 -> 0x1234
        uart_send_byte(8'h01);
        uart_send_byte(8'h00);
        uart_send_byte(8'h02);
        uart_recv_byte(rb0);
        uart_recv_byte(rb1);
        uart_recv_byte(rb2);
        expect_true(rb0 == 8'h81, "PEEK rsp code");
        expect_true({rb1, rb2} == 16'h1234, "PEEK data");

        // STEP -> status, pc should become 1
        uart_send_byte(8'h03);
        uart_recv_byte(rb0);
        uart_recv_byte(rb1);
        uart_recv_byte(rb2);
        uart_recv_byte(rb3);
        uart_recv_byte(rb4);
        uart_recv_byte(rb5);
        uart_recv_byte(rb6);
        uart_recv_byte(rb7);
        expect_true(rb0 == 8'h83, "STEP rsp code");
        expect_true({rb1, rb2} == 16'h0001, "STEP pc");

        // RUN 3 cycles -> status, pc should become 4
        uart_send_byte(8'h04);
        uart_send_byte(8'h00);
        uart_send_byte(8'h00);
        uart_send_byte(8'h00);
        uart_send_byte(8'h03);
        uart_recv_byte(rb0);
        uart_recv_byte(rb1);
        uart_recv_byte(rb2);
        uart_recv_byte(rb3);
        uart_recv_byte(rb4);
        uart_recv_byte(rb5);
        uart_recv_byte(rb6);
        uart_recv_byte(rb7);
        expect_true(rb0 == 8'h84, "RUN rsp code");
        expect_true({rb1, rb2} == 16'h0004, "RUN pc");

        // ROM write + read
        uart_send_byte(8'h08);
        uart_send_byte(8'h00);
        uart_send_byte(8'h05);
        uart_send_byte(8'hbe);
        uart_send_byte(8'hef);
        uart_recv_byte(rb0);
        expect_true(rb0 == 8'h88, "ROMW rsp code");
        expect_true(rom[15'h0005] == 16'hbeef, "ROMW data");

        uart_send_byte(8'h09);
        uart_send_byte(8'h00);
        uart_send_byte(8'h05);
        uart_recv_byte(rb0);
        uart_recv_byte(rb1);
        uart_recv_byte(rb2);
        expect_true(rb0 == 8'h89, "ROMR rsp code");
        expect_true({rb1, rb2} == 16'hbeef, "ROMR data");

        // KBD set
        uart_send_byte(8'h07);
        uart_send_byte(8'haa);
        uart_send_byte(8'h55);
        uart_recv_byte(rb0);
        expect_true(rb0 == 8'h87, "KBD rsp code");
        expect_true(kbd_data == 16'haa55, "KBD data");

        // RESET + HALT acks
        uart_send_byte(8'h05);
        uart_recv_byte(rb0);
        expect_true(rb0 == 8'h85, "RESET rsp code");

        uart_send_byte(8'h0A);
        uart_recv_byte(rb0);
        expect_true(rb0 == 8'h8A, "HALT rsp code");

        $display("PASS: uart_bridge_tb");
        $finish;
    end
endmodule
