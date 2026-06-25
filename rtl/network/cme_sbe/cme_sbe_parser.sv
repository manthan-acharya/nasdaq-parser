// Synthesizable CME Globex SBE parser for extracting BBO tick data on-the-fly.

`timescale 1ns / 1ps
`default_nettype none

module cme_sbe_parser (
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream Input
    input  logic [63:0] s_axis_tdata,
    input  logic [7:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,

    // Decoded CME SBE Book Update outputs
    output logic        book_update_valid,
    output logic [31:0] security_id,
    output logic        entry_type,        // 0 = Bid, 1 = Offer
    output logic [7:0]  price_level,
    output logic [63:0] price,
    output logic [31:0] size
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_BODY_0,   // Word 1: sendingTime
        ST_BODY_1,   // Word 2: securityId, entryType, priceLevel, size[15:0]
        ST_BODY_2,   // Word 3: size[31:16], price[47:0]
        ST_BODY_3,   // Word 4: price[63:48]
        ST_WAIT_EOF
    } state_t;

    state_t state, next_state;

    logic [15:0] r_block_length;
    logic [15:0] r_template_id;
    logic [15:0] r_schema_id;
    logic [15:0] r_version;

    logic [31:0] r_security_id;
    logic        r_entry_type;
    logic [7:0]  r_price_level;
    logic [63:0] r_price;
    logic [31:0] r_size;

    logic [15:0] size_low_buf;
    logic [47:0] price_low_buf;

    logic        s_axis_tready_int;

    assign s_axis_tready_int = 1'b1;
    assign s_axis_tready     = s_axis_tready_int;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else if (s_axis_tvalid && s_axis_tready_int) begin
            state <= next_state;
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (s_axis_tvalid) begin
                    next_state = ST_BODY_0;
                end
            end
            ST_BODY_0: begin
                if (s_axis_tlast) next_state = ST_IDLE;
                else              next_state = ST_BODY_1;
            end
            ST_BODY_1: begin
                if (s_axis_tlast) next_state = ST_IDLE;
                else              next_state = ST_BODY_2;
            end
            ST_BODY_2: begin
                if (s_axis_tlast) next_state = ST_IDLE;
                else              next_state = ST_BODY_3;
            end
            ST_BODY_3: begin
                if (s_axis_tlast) next_state = ST_IDLE;
                else              next_state = ST_WAIT_EOF;
            end
            ST_WAIT_EOF: begin
                if (s_axis_tlast) begin
                    next_state = ST_IDLE;
                end
            end
            default: next_state = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_block_length    <= 16'h0;
            r_template_id     <= 16'h0;
            r_schema_id       <= 16'h0;
            r_version         <= 16'h0;
            r_security_id     <= 32'h0;
            r_entry_type      <= 1'b0;
            r_price_level     <= 8'h0;
            r_price           <= 64'h0;
            r_size            <= 32'h0;
            size_low_buf      <= 16'h0;
            price_low_buf     <= 48'h0;
            book_update_valid <= 1'b0;
        end else begin
            book_update_valid <= 1'b0;

            if (s_axis_tvalid && s_axis_tready_int) begin
                case (state)
                    ST_IDLE: begin
                        // Word 0: CME SBE Header (Little-endian)
                        r_block_length <= s_axis_tdata[15:0];
                        r_template_id  <= s_axis_tdata[31:16];
                        r_schema_id    <= s_axis_tdata[47:32];
                        r_version      <= s_axis_tdata[63:48];
                    end

                    ST_BODY_0: begin
                        // Word 1: sendingTime (ignored for LOB updates)
                    end

                    ST_BODY_1: begin
                        // Word 2: security_id, entry_type (0x31='1'=Offer), price_level, size[15:0]
                        r_security_id  <= s_axis_tdata[31:0];
                        r_entry_type   <= (s_axis_tdata[39:32] == 8'h31);
                        r_price_level  <= s_axis_tdata[47:40];
                        size_low_buf   <= s_axis_tdata[63:48];
                    end

                    ST_BODY_2: begin
                        // Word 3: size[31:16], price[47:0]
                        r_size[15:0]  <= size_low_buf;
                        r_size[31:16] <= s_axis_tdata[15:0];
                        price_low_buf <= s_axis_tdata[63:16];
                    end

                    ST_BODY_3: begin
                        // Word 4: price[63:48]
                        r_price[47:0]  <= price_low_buf;
                        r_price[63:48] <= s_axis_tdata[15:0];

                        // Pulse valid if this is the CME Book Update template (42 or 46)
                        if (r_template_id == 16'd42 || r_template_id == 16'd46) begin
                            book_update_valid <= 1'b1;
                        end
                    end

                    default: ;
                endcase
            end
        end
    end

    assign security_id = r_security_id;
    assign entry_type  = r_entry_type;
    assign price_level = r_price_level;
    assign price       = r_price;
    assign size        = r_size;

endmodule

`default_nettype wire
