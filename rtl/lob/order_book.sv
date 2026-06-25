// Parameterized hardware Limit Order Book LOB tracking Level 1 BBO

`timescale 1ns / 1ps
`default_nettype none

module order_book #(
    parameter int ORDER_ADDR_WIDTH = 12,
    parameter int BOOK_ADDR_WIDTH  = 10
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic                         add_order_valid,
    input  itch_types::add_order_msg_t   add_order_data,

    input  logic                         exec_order_valid,
    input  itch_types::exec_order_msg_t  exec_order_data,

    input  logic                         cancel_order_valid,
    input  itch_types::cancel_order_msg_t cancel_order_data,

    input  logic                         delete_order_valid,
    input  itch_types::delete_order_msg_t delete_order_data,

    input  logic                         replace_order_valid,
    input  itch_types::replace_order_msg_t replace_order_data,

    output logic                         bbo_valid,
    output logic [63:0]                  bbo_stock,
    output logic [31:0]                  bbo_best_bid_price,
    output logic [31:0]                  bbo_best_bid_size,
    output logic [31:0]                  bbo_best_ask_price,
    output logic [31:0]                  bbo_best_ask_size
);

    typedef struct packed {
        logic [63:0] stock;
        logic [9:0]  stock_hash;
        logic        side;               // 0 = Buy ('B'), 1 = Sell ('S')
        logic [31:0] price;
        logic [31:0] shares;
        logic        valid;
    } order_rec_t;

    typedef struct packed {
        logic [63:0] stock;
        logic [31:0] best_bid_price;
        logic [31:0] best_bid_size;
        logic [31:0] best_ask_price;
        logic [31:0] best_ask_size;
    } book_rec_t;

    // 10-bit XOR ticker hashing algorithm
    function automatic logic [9:0] get_stock_hash(input logic [63:0] sym);
        return sym[9:0] ^ sym[19:10] ^ sym[29:20] ^ sym[39:30] ^ sym[49:40] ^ sym[59:50];
    endfunction

    // --- STAGE 0 -> STAGE 1 Registers ---
    logic        s1_add_valid;
    logic        s1_exec_valid;
    logic        s1_cancel_valid;
    logic        s1_delete_valid;
    logic        s1_replace_valid;

    itch_types::add_order_msg_t     s1_add_data;
    itch_types::exec_order_msg_t    s1_exec_data;
    itch_types::cancel_order_msg_t  s1_cancel_data;
    itch_types::delete_order_msg_t  s1_delete_data;
    itch_types::replace_order_msg_t s1_replace_data;

    // --- STAGE 1 -> STAGE 2 Registers ---
    logic        s2_add_valid;
    logic        s2_exec_valid;
    logic        s2_cancel_valid;
    logic        s2_delete_valid;
    logic        s2_replace_valid;

    itch_types::add_order_msg_t     s2_add_data;
    itch_types::exec_order_msg_t    s2_exec_data;
    itch_types::cancel_order_msg_t  s2_cancel_data;
    itch_types::delete_order_msg_t  s2_delete_data;
    itch_types::replace_order_msg_t s2_replace_data;

    logic [9:0]  s2_stock_hash;
    logic [63:0] s2_stock_symbol;
    logic [ORDER_ADDR_WIDTH-1:0] s1_order_ram_addr;
    logic [ORDER_ADDR_WIDTH-1:0] s2_order_ram_addr;

    // Order Store Block RAM
    logic [ORDER_ADDR_WIDTH-1:0] order_ram_addr_a;
    logic                        order_ram_we_a;
    logic [143:0]                order_ram_din_a;
    logic [143:0]                order_ram_dout_a;

    logic [ORDER_ADDR_WIDTH-1:0] order_ram_addr_b;
    logic [ORDER_ADDR_WIDTH-1:0] order_ram_addr_b_mux;
    logic                        order_ram_we_b;
    logic [143:0]                order_ram_din_b;
    logic [143:0]                order_ram_dout_b;

    assign order_ram_addr_b = order_ram_addr_b_mux;

    order_rec_t s1_retrieved_order;
    assign s1_retrieved_order = order_rec_t'(order_ram_dout_a);

    lob_bram #(
        .DATA_WIDTH (144),
        .ADDR_WIDTH (ORDER_ADDR_WIDTH)
    ) u_order_store (
        .clk    (clk),
        .we_a   (order_ram_we_a),
        .addr_a (order_ram_addr_a),
        .din_a  (order_ram_din_a),
        .dout_a (order_ram_dout_a),

        .we_b   (order_ram_we_b),
        .addr_b (order_ram_addr_b),
        .din_b  (order_ram_din_b),
        .dout_b (order_ram_dout_b)
    );

    // Book Store Block RAM
    logic [BOOK_ADDR_WIDTH-1:0]  book_ram_addr_a;
    logic                        book_ram_we_a;
    logic [191:0]                book_ram_din_a;
    logic [191:0]                book_ram_dout_a;

    logic [BOOK_ADDR_WIDTH-1:0]  book_ram_addr_b;
    logic                        book_ram_we_b;
    logic [191:0]                book_ram_din_b;
    logic [191:0]                book_ram_dout_b;

    book_rec_t s2_retrieved_book;
    assign s2_retrieved_book = book_rec_t'(book_ram_dout_a);

    lob_bram #(
        .DATA_WIDTH (192),
        .ADDR_WIDTH (BOOK_ADDR_WIDTH)
    ) u_book_store (
        .clk    (clk),
        .we_a   (book_ram_we_a),
        .addr_a (book_ram_addr_a),
        .din_a  (book_ram_din_a),
        .dout_a (book_ram_dout_a),

        .we_b   (book_ram_we_b),
        .addr_b (book_ram_addr_b),
        .din_b  (book_ram_din_b),
        .dout_b (book_ram_dout_b)
    );

    // Stage 0: Address Decoders & BRAM Read Request
    always_comb begin
        order_ram_addr_a = '0;
        if (add_order_valid) begin
            order_ram_addr_a = add_order_data.order_ref_id[ORDER_ADDR_WIDTH-1:0];
        end else if (exec_order_valid) begin
            order_ram_addr_a = exec_order_data.order_ref_id[ORDER_ADDR_WIDTH-1:0];
        end else if (cancel_order_valid) begin
            order_ram_addr_a = cancel_order_data.order_ref_id[ORDER_ADDR_WIDTH-1:0];
        end else if (delete_order_valid) begin
            order_ram_addr_a = delete_order_data.order_ref_id[ORDER_ADDR_WIDTH-1:0];
        end else if (replace_order_valid) begin
            order_ram_addr_a = replace_order_data.original_order_ref_id[ORDER_ADDR_WIDTH-1:0];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_add_valid      <= 1'b0;
            s1_exec_valid     <= 1'b0;
            s1_cancel_valid   <= 1'b0;
            s1_delete_valid   <= 1'b0;
            s1_replace_valid  <= 1'b0;
            s1_add_data       <= '0;
            s1_exec_data      <= '0;
            s1_cancel_data    <= '0;
            s1_delete_data    <= '0;
            s1_replace_data   <= '0;
            s1_order_ram_addr <= '0;
        end else begin
            s1_add_valid      <= add_order_valid;
            s1_exec_valid     <= exec_order_valid;
            s1_cancel_valid   <= cancel_order_valid;
            s1_delete_valid   <= delete_order_valid;
            s1_replace_valid  <= replace_order_valid;
            s1_add_data       <= add_order_data;
            s1_exec_data      <= exec_order_data;
            s1_cancel_data    <= cancel_order_data;
            s1_delete_data    <= delete_order_data;
            s1_replace_data   <= replace_order_data;
            s1_order_ram_addr <= order_ram_addr_a;
        end
    end

    // Stage 1: Order Retrieval & Book Store Read Request
    logic [9:0] s1_target_hash;
    logic [63:0] s1_target_symbol;

    always_comb begin
        s1_target_hash = '0;
        s1_target_symbol = '0;
        if (s1_add_valid) begin
            s1_target_hash   = get_stock_hash(s1_add_data.stock);
            s1_target_symbol = s1_add_data.stock;
        end else if (s1_retrieved_order.valid) begin
            s1_target_hash   = s1_retrieved_order.stock_hash;
            s1_target_symbol = s1_retrieved_order.stock;
        end
    end

    assign book_ram_addr_a = s1_target_hash;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_add_valid      <= 1'b0;
            s2_exec_valid     <= 1'b0;
            s2_cancel_valid   <= 1'b0;
            s2_delete_valid   <= 1'b0;
            s2_replace_valid  <= 1'b0;
            s2_add_data       <= '0;
            s2_exec_data      <= '0;
            s2_cancel_data    <= '0;
            s2_delete_data    <= '0;
            s2_replace_data   <= '0;
            s2_stock_hash     <= '0;
            s2_stock_symbol   <= '0;
            s2_order_ram_addr <= '0;
        end else begin
            s2_add_valid      <= s1_add_valid;
            s2_exec_valid     <= s1_exec_valid;
            s2_cancel_valid   <= s1_cancel_valid;
            s2_delete_valid   <= s1_delete_valid;
            s2_replace_valid  <= s1_replace_valid;
            s2_add_data       <= s1_add_data;
            s2_exec_data      <= s1_exec_data;
            s2_cancel_data    <= s1_cancel_data;
            s2_delete_data    <= s1_delete_data;
            s2_replace_data   <= s1_replace_data;
            s2_stock_hash     <= s1_target_hash;
            s2_stock_symbol   <= s1_target_symbol;
            s2_order_ram_addr <= s1_order_ram_addr;
        end
    end

    // Stage 2: Book Retrieval, Arithmetic computation, and BRAM Writes
    order_rec_t s2_retrieved_order;
    book_rec_t  s2_updated_book;
    order_rec_t s2_updated_order;

    // Deferred Delete Registers for double-write structural hazard on Replace
    logic [ORDER_ADDR_WIDTH-1:0] pending_delete_addr;
    logic                        pending_delete_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_delete_addr  <= '0;
            pending_delete_valid <= 1'b0;
        end else begin
            order_rec_t fwd;
            fwd = s2_retrieved_order;
            if (s2_replace_valid && fwd.valid) begin
                pending_delete_addr  <= s2_replace_data.original_order_ref_id[ORDER_ADDR_WIDTH-1:0];
                pending_delete_valid <= 1'b1;
            end else if (pending_delete_valid && order_ram_we_b && (order_ram_addr_b == pending_delete_addr)) begin
                pending_delete_valid <= 1'b0;
            end
        end
    end

    order_rec_t r_s2_order_rec;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_s2_order_rec <= '0;
        end else begin
            r_s2_order_rec <= s1_retrieved_order;
        end
    end

    assign s2_retrieved_order = r_s2_order_rec;

    // RAW Data Hazard Forwarding Registers
    logic [ORDER_ADDR_WIDTH-1:0] r_last_order_write_addr_1;
    order_rec_t                  r_last_order_write_data_1;
    logic                        r_last_order_write_valid_1;

    logic [ORDER_ADDR_WIDTH-1:0] r_last_order_write_addr_2;
    order_rec_t                  r_last_order_write_data_2;
    logic                        r_last_order_write_valid_2;

    logic [BOOK_ADDR_WIDTH-1:0]  r_last_book_write_hash;
    book_rec_t                   r_last_book_write_book;
    logic                        r_last_book_write_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_last_order_write_addr_1  <= '0;
            r_last_order_write_data_1  <= '0;
            r_last_order_write_valid_1 <= 1'b0;
            r_last_order_write_addr_2  <= '0;
            r_last_order_write_data_2  <= '0;
            r_last_order_write_valid_2 <= 1'b0;
            r_last_book_write_hash     <= '0;
            r_last_book_write_book     <= '0;
            r_last_book_write_valid    <= 1'b0;
        end else begin
            r_last_order_write_addr_1  <= order_ram_addr_b;
            r_last_order_write_data_1  <= s2_updated_order;
            r_last_order_write_valid_1 <= order_ram_we_b;
            r_last_order_write_addr_2  <= r_last_order_write_addr_1;
            r_last_order_write_data_2  <= r_last_order_write_data_1;
            r_last_order_write_valid_2 <= r_last_order_write_valid_1;
            r_last_book_write_hash     <= book_ram_addr_b;
            r_last_book_write_book     <= s2_updated_book;
            r_last_book_write_valid    <= book_ram_we_b;
        end
    end

    // Combinational Order Book Update Logic with Bypass Forwarding
    order_rec_t s2_forwarded_order;
    book_rec_t  s2_forwarded_book;

    always_comb begin
        s2_forwarded_order = s2_retrieved_order;
        if (r_last_order_write_valid_1 && (s2_order_ram_addr == r_last_order_write_addr_1)) begin
            s2_forwarded_order = r_last_order_write_data_1;
        end else if (r_last_order_write_valid_2 && (s2_order_ram_addr == r_last_order_write_addr_2)) begin
            s2_forwarded_order = r_last_order_write_data_2;
        end

        s2_forwarded_book = s2_retrieved_book;
        if (r_last_book_write_valid && (s2_stock_hash == r_last_book_write_hash)) begin
            s2_forwarded_book = r_last_book_write_book;
        end

        s2_updated_book  = s2_forwarded_book;
        s2_updated_order = s2_forwarded_order;

        order_ram_we_b   = 1'b0;
        order_ram_din_b  = '0;
        book_ram_we_b    = 1'b0;
        book_ram_din_b   = '0;

        order_ram_addr_b_mux = s2_order_ram_addr;

        s2_updated_book.stock = s2_stock_symbol;

        // Flush deferred delete if Stage 2 is idle and there is no active write
        if (pending_delete_valid && !s2_add_valid && !s2_exec_valid && !s2_cancel_valid && !s2_delete_valid && !s2_replace_valid) begin
            order_ram_we_b       = 1'b1;
            order_ram_din_b      = '0;
            order_ram_addr_b_mux = pending_delete_addr;
        end

        // 1. ADD ORDER ('A')
        if (s2_add_valid) begin
            order_ram_we_b  = 1'b1;
            s2_updated_order.stock               = s2_add_data.stock;
            s2_updated_order.stock_hash          = s2_stock_hash;
            s2_updated_order.side                = (s2_add_data.buy_sell_indicator == "S");
            s2_updated_order.price               = s2_add_data.price;
            s2_updated_order.shares              = s2_add_data.shares;
            s2_updated_order.valid               = 1'b1;
            order_ram_din_b                      = 144'(s2_updated_order);

            book_ram_we_b = 1'b1;
            if (s2_add_data.buy_sell_indicator == "B") begin
                if (s2_add_data.price > s2_forwarded_book.best_bid_price || s2_forwarded_book.best_bid_price == 0) begin
                    s2_updated_book.best_bid_price = s2_add_data.price;
                    s2_updated_book.best_bid_size  = s2_add_data.shares;
                end else if (s2_add_data.price == s2_forwarded_book.best_bid_price) begin
                    s2_updated_book.best_bid_size  = s2_forwarded_book.best_bid_size + s2_add_data.shares;
                end
            end else begin
                if (s2_add_data.price < s2_forwarded_book.best_ask_price || s2_forwarded_book.best_ask_price == 0) begin
                    s2_updated_book.best_ask_price = s2_add_data.price;
                    s2_updated_book.best_ask_size  = s2_add_data.shares;
                end else if (s2_add_data.price == s2_forwarded_book.best_ask_price) begin
                    s2_updated_book.best_ask_size  = s2_forwarded_book.best_ask_size + s2_add_data.shares;
                end
            end
            book_ram_din_b = 192'(s2_updated_book);
        end

        // 2. ORDER EXECUTED ('E')
        else if (s2_exec_valid && s2_forwarded_order.valid) begin
            order_ram_we_b = 1'b1;
            book_ram_we_b  = 1'b1;

            if (s2_forwarded_order.shares > s2_exec_data.shares) begin
                s2_updated_order.shares = s2_forwarded_order.shares - s2_exec_data.shares;
                order_ram_din_b         = 144'(s2_updated_order);
            end else begin
                s2_updated_order        = '0;
                order_ram_din_b         = '0;
            end

            if (s2_forwarded_order.side == 1'b0) begin
                if (s2_forwarded_order.price == s2_forwarded_book.best_bid_price) begin
                    if (s2_forwarded_book.best_bid_size <= s2_exec_data.shares) begin
                        s2_updated_book.best_bid_price = '0;
                        s2_updated_book.best_bid_size  = '0;
                    end else begin
                        s2_updated_book.best_bid_size = s2_forwarded_book.best_bid_size - s2_exec_data.shares;
                    end
                end
            end else begin
                if (s2_forwarded_order.price == s2_forwarded_book.best_ask_price) begin
                    if (s2_forwarded_book.best_ask_size <= s2_exec_data.shares) begin
                        s2_updated_book.best_ask_price = '0;
                        s2_updated_book.best_ask_size  = '0;
                    end else begin
                        s2_updated_book.best_ask_size = s2_forwarded_book.best_ask_size - s2_exec_data.shares;
                    end
                end
            end
            book_ram_din_b = 192'(s2_updated_book);
        end

        // 3. ORDER CANCEL ('X')
        else if (s2_cancel_valid && s2_forwarded_order.valid) begin
            order_ram_we_b = 1'b1;
            book_ram_we_b  = 1'b1;

            if (s2_forwarded_order.shares > s2_cancel_data.shares) begin
                s2_updated_order.shares = s2_forwarded_order.shares - s2_cancel_data.shares;
                order_ram_din_b         = 144'(s2_updated_order);
            end else begin
                s2_updated_order        = '0;
                order_ram_din_b         = '0;
            end

            if (s2_forwarded_order.side == 1'b0) begin
                if (s2_forwarded_order.price == s2_forwarded_book.best_bid_price) begin
                    if (s2_forwarded_book.best_bid_size <= s2_cancel_data.shares) begin
                        s2_updated_book.best_bid_price = '0;
                        s2_updated_book.best_bid_size  = '0;
                    end else begin
                        s2_updated_book.best_bid_size = s2_forwarded_book.best_bid_size - s2_cancel_data.shares;
                    end
                end
            end else begin
                if (s2_forwarded_order.price == s2_forwarded_book.best_ask_price) begin
                    if (s2_forwarded_book.best_ask_size <= s2_cancel_data.shares) begin
                        s2_updated_book.best_ask_price = '0;
                        s2_updated_book.best_ask_size  = '0;
                    end else begin
                        s2_updated_book.best_ask_size = s2_forwarded_book.best_ask_size - s2_cancel_data.shares;
                    end
                end
            end
            book_ram_din_b = 192'(s2_updated_book);
        end

        // 4. ORDER DELETE ('D')
        else if (s2_delete_valid && s2_forwarded_order.valid) begin
            order_ram_we_b = 1'b1;
            book_ram_we_b  = 1'b1;

            s2_updated_order = '0;
            order_ram_din_b  = '0;

            if (s2_forwarded_order.side == 1'b0) begin
                if (s2_forwarded_order.price == s2_forwarded_book.best_bid_price) begin
                    if (s2_forwarded_book.best_bid_size <= s2_forwarded_order.shares) begin
                        s2_updated_book.best_bid_price = '0;
                        s2_updated_book.best_bid_size  = '0;
                    end else begin
                        s2_updated_book.best_bid_size = s2_forwarded_book.best_bid_size - s2_forwarded_order.shares;
                    end
                end
            end else begin
                if (s2_forwarded_order.price == s2_forwarded_book.best_ask_price) begin
                    if (s2_forwarded_book.best_ask_size <= s2_forwarded_order.shares) begin
                        s2_updated_book.best_ask_price = '0;
                        s2_updated_book.best_ask_size  = '0;
                    end else begin
                        s2_updated_book.best_ask_size = s2_forwarded_book.best_ask_size - s2_forwarded_order.shares;
                    end
                end
            end
            book_ram_din_b = 192'(s2_updated_book);
        end

        // 5. ORDER REPLACE ('U')
        else if (s2_replace_valid && s2_forwarded_order.valid) begin
            order_ram_we_b       = 1'b1;
            order_ram_addr_b_mux = s2_replace_data.new_order_ref_id[ORDER_ADDR_WIDTH-1:0];
            s2_updated_order.stock               = s2_forwarded_order.stock;
            s2_updated_order.stock_hash          = s2_forwarded_order.stock_hash;
            s2_updated_order.side                = s2_forwarded_order.side;
            s2_updated_order.price               = s2_replace_data.price;
            s2_updated_order.shares              = s2_replace_data.shares;
            s2_updated_order.valid               = 1'b1;
            order_ram_din_b                      = 144'(s2_updated_order);

            book_ram_we_b = 1'b1;
            // Subtract the original order size from the book at the old price
            if (s2_forwarded_order.side == 1'b0) begin
                if (s2_forwarded_order.price == s2_forwarded_book.best_bid_price) begin
                    if (s2_forwarded_book.best_bid_size <= s2_forwarded_order.shares) begin
                        s2_updated_book.best_bid_price = '0;
                        s2_updated_book.best_bid_size  = '0;
                    end else begin
                        s2_updated_book.best_bid_size = s2_forwarded_book.best_bid_size - s2_forwarded_order.shares;
                    end
                end
            end else begin
                if (s2_forwarded_order.price == s2_forwarded_book.best_ask_price) begin
                    if (s2_forwarded_book.best_ask_size <= s2_forwarded_order.shares) begin
                        s2_updated_book.best_ask_price = '0;
                        s2_updated_book.best_ask_size  = '0;
                    end else begin
                        s2_updated_book.best_ask_size = s2_forwarded_book.best_ask_size - s2_forwarded_order.shares;
                    end
                end
            end

            // Add the new replaced order size to the book at the new price
            if (s2_forwarded_order.side == 1'b0) begin
                if (s2_replace_data.price > s2_updated_book.best_bid_price || s2_updated_book.best_bid_price == 0) begin
                    s2_updated_book.best_bid_price = s2_replace_data.price;
                    s2_updated_book.best_bid_size  = s2_replace_data.shares;
                end else if (s2_replace_data.price == s2_updated_book.best_bid_price) begin
                    s2_updated_book.best_bid_size  = s2_updated_book.best_bid_size + s2_replace_data.shares;
                end
            end else begin
                if (s2_replace_data.price < s2_updated_book.best_ask_price || s2_updated_book.best_ask_price == 0) begin
                    s2_updated_book.best_ask_price = s2_replace_data.price;
                    s2_updated_book.best_ask_size  = s2_replace_data.shares;
                end else if (s2_replace_data.price == s2_updated_book.best_ask_price) begin
                    s2_updated_book.best_ask_size  = s2_updated_book.best_ask_size + s2_replace_data.shares;
                end
            end
            book_ram_din_b = 192'(s2_updated_book);
        end
    end

    assign order_ram_we_a   = 1'b0;
    assign order_ram_din_a  = '0;
    assign book_ram_we_a    = 1'b0;
    assign book_ram_din_a   = '0;

    assign book_ram_addr_b  = s2_stock_hash;

    // Output Generation (Strobed on BBO changes in Cycle 2)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bbo_valid          <= 1'b0;
            bbo_stock          <= '0;
            bbo_best_bid_price <= '0;
            bbo_best_bid_size  <= '0;
            bbo_best_ask_price <= '0;
            bbo_best_ask_size  <= '0;
        end else begin
            bbo_valid <= 1'b0;

            if (book_ram_we_b) begin
                bbo_valid          <= 1'b1;
                bbo_stock          <= s2_stock_symbol;
                bbo_best_bid_price <= s2_updated_book.best_bid_price;
                bbo_best_bid_size  <= s2_updated_book.best_bid_size;
                bbo_best_ask_price <= s2_updated_book.best_ask_price;
                bbo_best_ask_size  <= s2_updated_book.best_ask_size;
            end
        end
    end

endmodule

`default_nettype wire
