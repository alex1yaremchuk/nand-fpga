module panel_mapper(
    input  wire [31:0] keys_raw,
    output wire [7:0]  buttons
);

    function [7:0] decode_buttons;
        input [31:0] raw;
        integer k;
        begin
            decode_buttons = 8'h00;
            for (k = 0; k < 8; k = k + 1) begin
                decode_buttons[k] = raw[((7-k) * 4)];
            end
        end
    endfunction

    // Physical order measured on board:
    // button->indicator: 1->8,2->6,3->4,4->2,5->7,6->5,7->3,8->1
    function [7:0] to_board_order;
        input [7:0] d;
        begin
            to_board_order[0] = d[7];
            to_board_order[1] = d[5];
            to_board_order[2] = d[3];
            to_board_order[3] = d[1];
            to_board_order[4] = d[6];
            to_board_order[5] = d[4];
            to_board_order[6] = d[2];
            to_board_order[7] = d[0];
        end
    endfunction

    assign buttons = to_board_order(decode_buttons(keys_raw));

endmodule
