`timescale 1ns / 1ps

`ifndef TB_DATA_W
`define TB_DATA_W 16
`endif

`ifndef TB_ADDR_W
`define TB_ADDR_W 15
`endif

`ifndef TB_ROM_ADDR_W
`define TB_ROM_ADDR_W 15
`endif

`ifndef TB_SCREEN_ADDR_W
`define TB_SCREEN_ADDR_W 13
`endif

`ifndef TB_USE_SCREEN_BRAM
`define TB_USE_SCREEN_BRAM 1
`endif

module hack_runner_tb;
    localparam integer DATA_W = `TB_DATA_W;
    localparam integer ADDR_W = `TB_ADDR_W;
    localparam integer ROM_ADDR_W = `TB_ROM_ADDR_W;
    localparam integer SCREEN_ADDR_W = `TB_SCREEN_ADDR_W;
    localparam integer USE_SCREEN_BRAM = `TB_USE_SCREEN_BRAM;

    localparam integer ROM_WORDS = (1 << ROM_ADDR_W);
    localparam integer RAM16K_WORDS = (1 << 14);
    localparam integer SCREEN_WORDS_MAX = (1 << SCREEN_ADDR_W);

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg step = 1'b0;

    reg rom_prog_we = 1'b0;
    reg [ADDR_W-1:0] rom_prog_addr = {ADDR_W{1'b0}};
    reg [DATA_W-1:0] rom_prog_data = {DATA_W{1'b0}};

    reg [DATA_W-1:0] prog_img [0:ROM_WORDS-1];

    wire [DATA_W-1:0] instr;
    wire [DATA_W-1:0] mem_q;
    wire [DATA_W-1:0] cpu_outM;
    wire cpu_writeM;
    wire [ADDR_W-1:0] cpu_addressM;
    wire [ADDR_W-1:0] cpu_pc;
    wire [ADDR_W-1:0] cpu_a_dbg;
    wire [DATA_W-1:0] cpu_d_dbg;
    wire [DATA_W-1:0] kbd_in = {DATA_W{1'b0}};

    integer cycles = 1000;
    integer prog_words = ROM_WORDS;
    integer ram_base = 0;
    integer ram_words = 256;
    integer screen_words = SCREEN_WORDS_MAX;

    // Keep path buffers large enough for long Windows absolute paths.
    reg [4095:0] hack_file = "";
    reg [4095:0] ram_init_file = "";
    reg [4095:0] pc_dump_file = "pc_dump.txt";
    reg [4095:0] ram_dump_file = "ram_dump.txt";
    reg [4095:0] screen_dump_file = "screen_dump.txt";

    integer fd_pc;
    integer fd_ram;
    integer fd_screen;
    integer fd_hack;
    integer fd_init;
    integer plusarg_ok;
    integer parsed;
    integer loaded_words;
    integer init_addr;
    integer init_data;
    integer i;
    reg [DATA_W-1:0] file_word;
    reg [1023:0] line_buf;

    rom32k_prog #(
        .WIDTH(DATA_W),
        .ROM_ADDR_W(ROM_ADDR_W)
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
        .USE_SCREEN_BRAM(USE_SCREEN_BRAM),
        .SCREEN_ADDR_W(SCREEN_ADDR_W)
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

    task write_rom_word;
        input [ADDR_W-1:0] addr;
        input [DATA_W-1:0] data;
        begin
            rom_prog_we = 1'b1;
            rom_prog_addr = addr;
            rom_prog_data = data;
            @(posedge clk);
            #1;
            rom_prog_we = 1'b0;
        end
    endtask

    initial begin
        if (!$value$plusargs("hack=%s", hack_file)) begin
            $display("ERROR: +hack=<program.hack> is required");
            $fatal(1);
        end

        plusarg_ok = $value$plusargs("cycles=%d", cycles);
        plusarg_ok = $value$plusargs("prog_words=%d", prog_words);
        plusarg_ok = $value$plusargs("ram_base=%d", ram_base);
        plusarg_ok = $value$plusargs("ram_words=%d", ram_words);
        plusarg_ok = $value$plusargs("screen_words=%d", screen_words);
        plusarg_ok = $value$plusargs("ram_init=%s", ram_init_file);
        plusarg_ok = $value$plusargs("pc_dump=%s", pc_dump_file);
        plusarg_ok = $value$plusargs("ram_dump=%s", ram_dump_file);
        plusarg_ok = $value$plusargs("screen_dump=%s", screen_dump_file);

        if (prog_words < 0) prog_words = 0;
        if (prog_words > ROM_WORDS) prog_words = ROM_WORDS;
        if (cycles < 0) cycles = 0;

        if (ram_base < 0) ram_base = 0;
        if (ram_base > RAM16K_WORDS) ram_base = RAM16K_WORDS;
        if (ram_words < 0) ram_words = 0;
        if (ram_base + ram_words > RAM16K_WORDS) ram_words = RAM16K_WORDS - ram_base;

        if (screen_words < 0) screen_words = 0;
        if (screen_words > SCREEN_WORDS_MAX) screen_words = SCREEN_WORDS_MAX;

        $display("INFO: hack=%0s", hack_file);
        $display("INFO: cycles=%0d, prog_words=%0d", cycles, prog_words);
        $display("INFO: ram_base=%0d, ram_words=%0d, screen_words=%0d", ram_base, ram_words, screen_words);

        for (i = 0; i < ROM_WORDS; i = i + 1) begin
            prog_img[i] = {DATA_W{1'b0}};
        end

        fd_hack = $fopen(hack_file, "r");
        if (fd_hack == 0) begin
            $display("ERROR: failed to open hack file: %0s", hack_file);
            $fatal(1);
        end

        loaded_words = 0;
        while (!$feof(fd_hack) && (loaded_words < ROM_WORDS)) begin
            line_buf = "";
            parsed = 0;
            file_word = {DATA_W{1'b0}};
            plusarg_ok = $fgets(line_buf, fd_hack);
            parsed = $sscanf(line_buf, "%b", file_word);
            if (parsed == 1) begin
                prog_img[loaded_words] = file_word;
                loaded_words = loaded_words + 1;
            end
        end
        $fclose(fd_hack);

        if (prog_words > loaded_words) begin
            prog_words = loaded_words;
        end

        // Deterministic zeroed RAM/screen state for reproducible test results.
        for (i = 0; i < RAM16K_WORDS; i = i + 1) begin
            u_mem.u_ram16k.g_bram.u_bram.mem[i] = {DATA_W{1'b0}};
        end
        if (USE_SCREEN_BRAM != 0) begin
            for (i = 0; i < SCREEN_WORDS_MAX; i = i + 1) begin
                u_mem.g_screen_bram.u_screen.mem[i] = {DATA_W{1'b0}};
            end
        end

        if (ram_init_file != "") begin
            fd_init = $fopen(ram_init_file, "r");
            if (fd_init == 0) begin
                $display("ERROR: failed to open ram init file: %0s", ram_init_file);
                $fatal(1);
            end

            while (!$feof(fd_init)) begin
                line_buf = "";
                plusarg_ok = $fgets(line_buf, fd_init);
                parsed = $sscanf(line_buf, "%h %h", init_addr, init_data);
                if (parsed == 2) begin
                    if ((init_addr >= 0) && (init_addr < RAM16K_WORDS)) begin
                        u_mem.u_ram16k.g_bram.u_bram.mem[init_addr] = init_data[DATA_W-1:0];
                    end else if (
                        (USE_SCREEN_BRAM != 0) &&
                        (init_addr >= 16'h4000) &&
                        (init_addr < (16'h4000 + SCREEN_WORDS_MAX))
                    ) begin
                        u_mem.g_screen_bram.u_screen.mem[init_addr - 16'h4000] = init_data[DATA_W-1:0];
                    end
                end
            end

            $fclose(fd_init);
        end

        // Load ROM through the programming port.
        for (i = 0; i < prog_words; i = i + 1) begin
            write_rom_word(i[ADDR_W-1:0], prog_img[i]);
        end

        // Deterministic boot sequence.
        step = 1'b0;
        reset = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        reset = 1'b0;

        // Prime synchronous ROM fetch for PC=0.
        @(posedge clk);
        #1;

        // Run requested number of CPU steps.
        step = 1'b1;
        for (i = 0; i < cycles; i = i + 1) begin
            @(posedge clk);
            #1;
        end
        step = 1'b0;
        @(posedge clk);
        #1;

        fd_pc = $fopen(pc_dump_file, "w");
        if (fd_pc == 0) begin
            $display("ERROR: failed to open pc dump file: %0s", pc_dump_file);
            $fatal(1);
        end
        $fdisplay(fd_pc, "PC %0d 0x%04x", cpu_pc, cpu_pc);
        $fdisplay(fd_pc, "A  %0d 0x%04x", cpu_a_dbg, cpu_a_dbg);
        $fdisplay(fd_pc, "D  %0d 0x%04x", cpu_d_dbg, cpu_d_dbg);
        $fclose(fd_pc);

        fd_ram = $fopen(ram_dump_file, "w");
        if (fd_ram == 0) begin
            $display("ERROR: failed to open ram dump file: %0s", ram_dump_file);
            $fatal(1);
        end
        for (i = 0; i < ram_words; i = i + 1) begin
            $fdisplay(
                fd_ram,
                "%04x %04x",
                ((ram_base + i) & 16'hffff),
                u_mem.u_ram16k.g_bram.u_bram.mem[ram_base + i]
            );
        end
        $fclose(fd_ram);

        fd_screen = $fopen(screen_dump_file, "w");
        if (fd_screen == 0) begin
            $display("ERROR: failed to open screen dump file: %0s", screen_dump_file);
            $fatal(1);
        end

        if (USE_SCREEN_BRAM != 0) begin
            for (i = 0; i < screen_words; i = i + 1) begin
                $fdisplay(fd_screen, "%04x %04x", (i & 16'hffff), u_mem.g_screen_bram.u_screen.mem[i]);
            end
        end
        $fclose(fd_screen);

        $display("PASS: hack_runner_tb");
        $finish;
    end
endmodule
