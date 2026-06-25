// High-performance NASDAQ ITCH-5.0 parser featuring a sliding-window byte accumulator.

`timescale 1ns / 1ps
`default_nettype none

module itch_parser #(
    parameter bit MOLDUDP64_SUPPORT = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream Input
    input  logic [63:0] s_axis_tdata,
    input  logic [7:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,

    // Decoded ITCH-5.0 Messages
    output logic                         add_order_valid,
    output itch_types::add_order_msg_t   add_order_data,

    output logic                         exec_order_valid,
    output itch_types::exec_order_msg_t  exec_order_data,

    output logic                         cancel_order_valid,
    output itch_types::cancel_order_msg_t cancel_order_data,

    output logic                         delete_order_valid,
    output itch_types::delete_order_msg_t delete_order_data,

    output logic                         replace_order_valid,
    output itch_types::replace_order_msg_t replace_order_data
);

    typedef enum logic {
        ST_PARSE_LEN,
        ST_PARSE_MSG
    } parser_state_t;

    parser_state_t parser_state, next_parser_state;

    logic [127:0][7:0] byte_buf;
    logic [7:0]        buf_bytes;
    logic [15:0]       r_msg_length;
    logic [15:0]       next_r_msg_length;

    logic [15:0]       packet_byte_cnt;
    logic              s_axis_tready_int;

    // Flow Control: always ready
    assign s_axis_tready_int = 1'b1;
    assign s_axis_tready     = s_axis_tready_int;

    logic [3:0] num_new_bytes;
    always_comb begin
        case (s_axis_tkeep)
            8'h01: num_new_bytes = 4'd1;
            8'h03: num_new_bytes = 4'd2;
            8'h07: num_new_bytes = 4'd3;
            8'h0f: num_new_bytes = 4'd4;
            8'h1f: num_new_bytes = 4'd5;
            8'h3f: num_new_bytes = 4'd6;
            8'h7f: num_new_bytes = 4'd7;
            8'hff: num_new_bytes = 4'd8;
            default: num_new_bytes = 4'd0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            packet_byte_cnt <= 16'd0;
        end else if (s_axis_tvalid && s_axis_tready_int) begin
            if (s_axis_tlast) begin
                packet_byte_cnt <= 16'd0;
            end else begin
                packet_byte_cnt <= packet_byte_cnt + 16'(num_new_bytes);
            end
        end
    end

    // Skip MoldUDP64 header if enabled
    logic [7:0] filtered_new_bytes [7:0];
    logic [3:0] filtered_num_new_bytes;

    always_comb begin
        filtered_num_new_bytes = 4'd0;
        for (int j = 0; j < 8; j = j + 1) begin
            filtered_new_bytes[j] = 8'h0;
        end

        if (s_axis_tvalid) begin
            for (int k = 0; k < 8; k = k + 1) begin
                if (k < int'(num_new_bytes)) begin
                    automatic int abs_byte_idx = int'(packet_byte_cnt) + k;
                    if (!MOLDUDP64_SUPPORT || (abs_byte_idx >= 20)) begin
                        filtered_new_bytes[filtered_num_new_bytes[2:0]] = s_axis_tdata[k*8 +: 8];
                        filtered_num_new_bytes = filtered_num_new_bytes + 4'd1;
                    end
                end
            end
        end
    end

    logic [7:0]        consume_bytes;
    logic [7:0]        next_buf_bytes;
    logic [127:0][7:0] next_byte_buf;
    logic [127:0][7:0] next_byte_buf_first;

    always_comb begin
        next_byte_buf_first = '0;
        for (int k = 0; k < 8; k = k + 1) begin
            if (k < int'(filtered_num_new_bytes)) begin
                next_byte_buf_first[k] = filtered_new_bytes[k[2:0]];
            end
        end
    end

    // Shift existing contents and append incoming bytes
    always_comb begin
        automatic int write_pos = 0;
        next_byte_buf = '0;

        for (int i = 0; i < 128; i = i + 1) begin
            if (i < 128 - int'(consume_bytes)) begin
                next_byte_buf[i] = byte_buf[i + int'(consume_bytes)];
            end else begin
                next_byte_buf[i] = 8'h0;
            end
        end

        if (s_axis_tvalid) begin
            write_pos = int'(buf_bytes) - int'(consume_bytes);
            for (int i = 0; i < 128; i = i + 1) begin
                for (int k = 0; k < 8; k = k + 1) begin
                    if (k < int'(filtered_num_new_bytes)) begin
                        if (i == (write_pos + k)) begin
                            next_byte_buf[i] = filtered_new_bytes[k[2:0]];
                        end
                    end
                end
            end
        end
    end

    assign next_buf_bytes = buf_bytes + (s_axis_tvalid ? 8'(filtered_num_new_bytes) : 8'd0) - consume_bytes;

    logic is_first_word;
    assign is_first_word = (packet_byte_cnt == 16'd0) && s_axis_tvalid && s_axis_tready_int;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_buf     <= '0;
            buf_bytes    <= 8'd0;
            parser_state <= ST_PARSE_LEN;
            r_msg_length <= 16'd0;
        end else begin
            if (is_first_word) begin
                byte_buf     <= next_byte_buf_first;
                buf_bytes    <= 8'(filtered_num_new_bytes);
                parser_state <= ST_PARSE_LEN;
                r_msg_length <= 16'd0;
            end else begin
                byte_buf     <= next_byte_buf;
                buf_bytes    <= next_buf_bytes;
                parser_state <= next_parser_state;
                r_msg_length <= next_r_msg_length;
            end
        end
    end

    always_comb begin
        add_order_valid    = 1'b0;
        exec_order_valid   = 1'b0;
        cancel_order_valid = 1'b0;
        delete_order_valid = 1'b0;
        replace_order_valid = 1'b0;

        add_order_data     = '0;
        exec_order_data    = '0;
        cancel_order_data  = '0;
        delete_order_data  = '0;
        replace_order_data = '0;

        consume_bytes      = 8'd0;
        next_parser_state  = parser_state;
        next_r_msg_length  = r_msg_length;

        case (parser_state)
            ST_PARSE_LEN: begin
                if (buf_bytes >= 8'd2) begin
                    automatic logic [15:0] msg_len = {byte_buf[0], byte_buf[1]};
                    if (16'(buf_bytes) >= msg_len + 16'd2) begin
                        consume_bytes = 8'(msg_len + 16'd2);
                        // Byte 2 is Message Type (first byte of ITCH message)
                        case (byte_buf[2])
                            8'h41: begin // Message Type 'A' (Add Order)
                                add_order_valid = 1'b1;
                                // Decode fields (Big-endian unpack)
                                add_order_data.order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                               byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                                add_order_data.buy_sell_indicator = byte_buf[21];
                                add_order_data.shares = {byte_buf[22], byte_buf[23], byte_buf[24], byte_buf[25]};
                                add_order_data.stock = {byte_buf[26], byte_buf[27], byte_buf[28], byte_buf[29],
                                                        byte_buf[30], byte_buf[31], byte_buf[32], byte_buf[33]};
                                add_order_data.price = {byte_buf[34], byte_buf[35], byte_buf[36], byte_buf[37]};
                            end

                            8'h45: begin // Message Type 'E' (Order Executed)
                                exec_order_valid = 1'b1;
                                exec_order_data.order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                                byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                                exec_order_data.shares = {byte_buf[21], byte_buf[22], byte_buf[23], byte_buf[24]};
                            end

                            8'h58: begin // Message Type 'X' (Order Cancel)
                                cancel_order_valid = 1'b1;
                                cancel_order_data.order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                                  byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                                cancel_order_data.shares = {byte_buf[21], byte_buf[22], byte_buf[23], byte_buf[24]};
                            end

                            8'h44: begin // Message Type 'D' (Order Delete)
                                delete_order_valid = 1'b1;
                                delete_order_data.order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                                  byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                            end

                            8'h55: begin // Message Type 'U' (Order Replace)
                                replace_order_valid = 1'b1;
                                replace_order_data.original_order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                                            byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                                replace_order_data.new_order_ref_id = {byte_buf[21], byte_buf[22], byte_buf[23], byte_buf[24],
                                                                       byte_buf[25], byte_buf[26], byte_buf[27], byte_buf[28]};
                                replace_order_data.shares = {byte_buf[29], byte_buf[30], byte_buf[31], byte_buf[32]};
                                replace_order_data.price = {byte_buf[33], byte_buf[34], byte_buf[35], byte_buf[36]};
                            end

                            default: ;
                        endcase
                        next_parser_state = ST_PARSE_LEN;
                    end else begin
                        next_r_msg_length = msg_len;
                        next_parser_state = ST_PARSE_MSG;
                    end
                end
            end

            ST_PARSE_MSG: begin
                if (16'(buf_bytes) >= r_msg_length + 16'd2) begin
                    consume_bytes = 8'(r_msg_length + 16'd2);
                    case (byte_buf[2])
                        8'h41: begin // Message Type 'A'
                            add_order_valid = 1'b1;
                            add_order_data.order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                           byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                            add_order_data.buy_sell_indicator = byte_buf[21];
                            add_order_data.shares = {byte_buf[22], byte_buf[23], byte_buf[24], byte_buf[25]};
                            add_order_data.stock = {byte_buf[26], byte_buf[27], byte_buf[28], byte_buf[29],
                                                    byte_buf[30], byte_buf[31], byte_buf[32], byte_buf[33]};
                            add_order_data.price = {byte_buf[34], byte_buf[35], byte_buf[36], byte_buf[37]};
                        end

                        8'h45: begin // Message Type 'E'
                            exec_order_valid = 1'b1;
                            exec_order_data.order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                            byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                            exec_order_data.shares = {byte_buf[21], byte_buf[22], byte_buf[23], byte_buf[24]};
                        end

                        8'h58: begin // Message Type 'X'
                            cancel_order_valid = 1'b1;
                            cancel_order_data.order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                              byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                            cancel_order_data.shares = {byte_buf[21], byte_buf[22], byte_buf[23], byte_buf[24]};
                        end

                        8'h44: begin // Message Type 'D'
                            delete_order_valid = 1'b1;
                            delete_order_data.order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                              byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                        end

                        8'h55: begin // Message Type 'U'
                            replace_order_valid = 1'b1;
                            replace_order_data.original_order_ref_id = {byte_buf[13], byte_buf[14], byte_buf[15], byte_buf[16],
                                                                        byte_buf[17], byte_buf[18], byte_buf[19], byte_buf[20]};
                            replace_order_data.new_order_ref_id = {byte_buf[21], byte_buf[22], byte_buf[23], byte_buf[24],
                                                                   byte_buf[25], byte_buf[26], byte_buf[27], byte_buf[28]};
                            replace_order_data.shares = {byte_buf[29], byte_buf[30], byte_buf[31], byte_buf[32]};
                            replace_order_data.price = {byte_buf[33], byte_buf[34], byte_buf[35], byte_buf[36]};
                        end

                        default: ;
                    endcase
                    next_parser_state = ST_PARSE_LEN;
                end
            end

            default: next_parser_state = ST_PARSE_LEN;
        endcase
    end

endmodule

`default_nettype wire
