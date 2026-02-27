`timescale 1ns / 1ps

module cpu_memory_timing_tb;
    localparam integer DATA_W = 16;
    localparam integer ADDR_W = 15;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg step = 1'b0;

    reg rom_prog_we = 1'b0;
    reg [ADDR_W-1:0] rom_prog_addr = {ADDR_W{1'b0}};
    reg [DATA_W-1:0] rom_prog_data = {DATA_W{1'b0}};

    wire [DATA_W-1:0] instr;
    wire [DATA_W-1:0] mem_q;
    wire [DATA_W-1:0] cpu_outM;
    wire cpu_writeM;
    wire [ADDR_W-1:0] cpu_addressM;
    wire [ADDR_W-1:0] cpu_pc;
    wire [ADDR_W-1:0] cpu_a_dbg;
    wire [DATA_W-1:0] cpu_d_dbg;

    // No keyboard activity in this test.
    wire [DATA_W-1:0] kbd_in = {DATA_W{1'b0}};

    rom32k_prog #(
        .WIDTH(DATA_W),
        .ROM_ADDR_W(15)
    ) u_rom (
        .clk(clk),
        .prog_we(rom_prog_we),
        .prog_addr(rom_prog_addr),
        .prog_data(rom_prog_data),
        .rd_addr(cpu_pc),
        .q(instr)
    );

    memory_map #(
        .WIDTH(DATA_W),
        .RAM16K_USE_BRAM(1),
        .RAM16K_RAM4K_USE_BRAM(1),
        .USE_SCREEN_BRAM(0),
        .SCREEN_ADDR_W(13)
    ) u_mem (
        .clk(clk),
        .load(cpu_writeM),
        .addr(cpu_addressM),
        .d(cpu_outM),
        .kbd_in(kbd_in),
        .q(mem_q)
    );

    cpu_core #(
        .DATA_W(DATA_W),
        .ADDR_W(ADDR_W)
    ) u_cpu (
        .clk(clk),
        .reset(reset),
        .step(step),
        .instr(instr),
        .inM(mem_q),
        .outM(cpu_outM),
        .writeM(cpu_writeM),
        .addressM(cpu_addressM),
        .pc(cpu_pc),
        .a_dbg(cpu_a_dbg),
        .d_dbg(cpu_d_dbg)
    );

    always #5 clk = ~clk;

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

    task rom_write_word;
        input [ADDR_W-1:0] addr;
        input [DATA_W-1:0] data;
        begin
            rom_prog_addr = addr;
            rom_prog_data = data;
            rom_prog_we = 1'b1;
            @(posedge clk);
            #1;
            rom_prog_we = 1'b0;
        end
    endtask

    task cpu_step_once;
        begin
            step = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        // Program:
        //   @21
        //   D=A
        //   @100
        //   M=D
        //   @100
        //   D=M
        rom_write_word(15'd0, 16'h0015);               // @21
        rom_write_word(15'd1, 16'b1110110000010000);   // D=A
        rom_write_word(15'd2, 16'h0064);               // @100
        rom_write_word(15'd3, 16'b1110001100001000);   // M=D
        rom_write_word(15'd4, 16'h0064);               // @100
        rom_write_word(15'd5, 16'b1111110000010000);   // D=M

        // Hold reset for deterministic boot.
        step = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        expect_true(cpu_pc == 0, "PC must start at 0");
        expect_true(cpu_a_dbg == 0, "A must start at 0");
        expect_true(cpu_d_dbg == 0, "D must start at 0");

        // Release reset and do one fetch-prime cycle (step=0).
        // With synchronous ROM read, this loads instruction at PC=0 into instr.
        reset = 1'b0;
        @(posedge clk);
        #1;

        // Execute 6 instructions.
        repeat (6) begin
            cpu_step_once();
        end
        step = 1'b0;

        // Expected final state after D=M:
        // - D == 21
        // - RAM[100] was written with 21
        // - PC == 6
        expect_true(cpu_d_dbg == 16'd21, "D must be 21 after D=M");
        expect_true(cpu_pc == 15'd6, "PC must be 6 after 6 instructions");
        expect_true(mem_q == 16'd21, "Memory read path must return written value 21");

        $display("PASS: cpu_memory_timing_tb");
        $finish;
    end
endmodule
