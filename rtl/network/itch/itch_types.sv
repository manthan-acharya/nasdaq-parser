// Strongly-typed packed structures for NASDAQ ITCH-5.0 messages.

`timescale 1ns / 1ps

package itch_types;

    // Message Type 'A': Add Order (No MPID)
    typedef struct packed {
        logic [63:0] order_ref_id;
        logic [7:0]  buy_sell_indicator;  // 'B' = Buy, 'S' = Sell
        logic [31:0] shares;
        logic [63:0] stock;               // 8-byte ASCII ticker symbol (space-padded)
        logic [31:0] price;               // 32-bit fixed point price (4 decimal places)
    } add_order_msg_t;

    // Message Type 'E': Order Executed
    typedef struct packed {
        logic [63:0] order_ref_id;
        logic [31:0] shares;
    } exec_order_msg_t;

    // Message Type 'X': Order Cancel
    typedef struct packed {
        logic [63:0] order_ref_id;
        logic [31:0] shares;
    } cancel_order_msg_t;

    // Message Type 'D': Order Delete
    typedef struct packed {
        logic [63:0] order_ref_id;
    } delete_order_msg_t;

    // Message Type 'U': Order Replace
    typedef struct packed {
        logic [63:0] original_order_ref_id;
        logic [63:0] new_order_ref_id;
        logic [31:0] shares;
        logic [31:0] price;
    } replace_order_msg_t;

endpackage
