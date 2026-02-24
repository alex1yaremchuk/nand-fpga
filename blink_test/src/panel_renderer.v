module panel_renderer(
    input  wire        clk,
    input  wire        busy,
    input  wire        start,
    input  wire [63:0] digits,   // 8 digits x 8 bits, digit i at bits [i*8 +: 8]
    input  wire [7:0]  leds,     // one bit per led position
    output reg         frame_busy = 0,
    output reg         refresh_req = 0,
    output reg         ram_we = 0,
    output reg [3:0]   ram_waddr = 0,
    output reg [7:0]   ram_wdata = 0
);

    reg [4:0] sub = 17;
    reg [63:0] digits_latched = 0;
    reg [7:0] leds_latched = 0;

    task write_digit;
        input [2:0] idx;
        input [7:0] seg;
        begin
            ram_we    <= 1'b1;
            ram_waddr <= {idx, 1'b0};
            ram_wdata <= seg;
        end
    endtask

    task write_led;
        input [2:0] idx;
        input on;
        begin
            ram_we    <= 1'b1;
            ram_waddr <= {idx, 1'b0} + 1;
            ram_wdata <= on ? 8'h01 : 8'h00;
        end
    endtask

    always @(posedge clk) begin
        refresh_req <= 1'b0;
        ram_we <= 1'b0;

        if (start && !frame_busy) begin
            digits_latched <= digits;
            leds_latched <= leds;
            sub <= 0;
            frame_busy <= 1'b1;
        end

        if (frame_busy && !busy) begin
            if (sub < 8) begin
                write_digit(sub[2:0], digits_latched[sub*8 +: 8]);
                sub <= sub + 1'b1;
            end else if (sub < 16) begin
                write_led(sub[2:0], leds_latched[sub-8]);
                sub <= sub + 1'b1;
            end else if (sub == 16) begin
                refresh_req <= 1'b1;
                sub <= 17;
                frame_busy <= 1'b0;
            end
        end
    end

endmodule
