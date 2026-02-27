`timescale 1ns / 1ps

module cpu_core_reset_boot_tb;
    localparam integer DATA_W = 16;
    localparam integer ADDR_W = 15;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg step = 1'b0;
    reg [DATA_W-1:0] instr = {DATA_W{1'b0}};
    reg [DATA_W-1:0] inM = {DATA_W{1'b0}};

    wire [DATA_W-1:0] outM;
    wire writeM;
    wire [ADDR_W-1:0] addressM;
    wire [ADDR_W-1:0] pc;
    wire [ADDR_W-1:0] a_dbg;
    wire [DATA_W-1:0] d_dbg;

    cpu_core #(
        .DATA_W(DATA_W),
        .ADDR_W(ADDR_W)
    ) dut (
        .clk(clk),
        .reset(reset),
        .step(step),
        .instr(instr),
        .inM(inM),
        .outM(outM),
        .writeM(writeM),
        .addressM(addressM),
        .pc(pc),
        .a_dbg(a_dbg),
        .d_dbg(d_dbg)
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

    initial begin
        // Keep reset high and prove state is deterministic even if step=1.
        step = 1'b1;
        instr = 16'h0001; // @1
        repeat (2) @(posedge clk);
        #1;
        expect_true(pc == 0, "PC must be 0 during reset");
        expect_true(a_dbg == 0, "A must be 0 during reset");
        expect_true(d_dbg == 0, "D must be 0 during reset");

        // Release reset and execute @1.
        reset = 1'b0;
        instr = 16'h0001; // @1
        @(posedge clk);
        #1;
        expect_true(pc == 1, "PC must increment after first step");
        expect_true(a_dbg == 1, "A must load immediate 1");
        expect_true(d_dbg == 0, "D must remain 0");

        // Execute D=A.
        instr = 16'b1110110000010000; // D=A
        @(posedge clk);
        #1;
        expect_true(pc == 2, "PC must increment after second step");
        expect_true(a_dbg == 1, "A must stay 1");
        expect_true(d_dbg == 1, "D must load A");
        expect_true(writeM == 1'b0, "D=A must not assert writeM");

        // Stop stepping and ensure state holds.
        step = 1'b0;
        instr = 16'h0005; // would be @5 if stepped
        repeat (2) @(posedge clk);
        #1;
        expect_true(pc == 2, "PC must hold when step=0");
        expect_true(a_dbg == 1, "A must hold when step=0");
        expect_true(d_dbg == 1, "D must hold when step=0");

        // Execute 0;JMP, should jump to A (=1).
        step = 1'b1;
        instr = 16'b1110101010000111; // 0;JMP
        @(posedge clk);
        #1;
        expect_true(pc == 1, "0;JMP must load PC from A");

        // Assert reset again and verify deterministic boot state.
        reset = 1'b1;
        @(posedge clk);
        #1;
        expect_true(pc == 0, "PC must clear on reset");
        expect_true(a_dbg == 0, "A must clear on reset");
        expect_true(d_dbg == 0, "D must clear on reset");

        $display("PASS: cpu_core_reset_boot_tb");
        $finish;
    end
endmodule
