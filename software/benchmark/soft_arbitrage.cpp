// Software HFT pipeline baseline parsing MoldUDP64/ITCH-5.0 feeds and evaluating triangular arbitrage.

#include <iostream>
#include <vector>
#include <string>
#include <unordered_map>
#include <chrono>
#include <cstring>
#include <iomanip>

struct Order {
    uint64_t order_ref_id;
    char buy_sell;
    uint32_t shares;
    char symbol[8];
    uint32_t price;
};

struct BBOBook {
    char symbol[8];
    uint32_t bid_price = 0;
    uint32_t bid_size = 0;
    uint32_t ask_price = 0xFFFFFFFF;
    uint32_t ask_size = 0;
};

class SoftArbitrageEngine {
private:
    std::unordered_map<uint64_t, Order> order_store;
    std::unordered_map<std::string, BBOBook> book_store;
    
    // Exchange rates in Q8.24 fixed-point format
    uint32_t rate_ab = 0;
    uint32_t rate_bc = 0;
    uint32_t rate_ca = 0;
    const uint64_t threshold = 0x010013aa; // 1.0003 in Q8.24 (product threshold: 1.0003 * 2^24)

public:
    SoftArbitrageEngine() {}

    void set_rates(uint32_t ab, uint32_t bc, uint32_t ca) {
        rate_ab = ab;
        rate_bc = bc;
        rate_ca = ca;
    }

    bool process_itch_message(const uint8_t* msg, size_t len, uint64_t& latency_ns) {
        auto start_time = std::chrono::high_resolution_clock::now();
        
        if (len < 1) return false;
        uint8_t type = msg[0];

        bool bbo_changed = false;
        std::string target_symbol = "";

        if (type == 'A') {
            if (len < 36) return false;
            
            Order ord;
            ord.order_ref_id = ((uint64_t)msg[11] << 56) | ((uint64_t)msg[12] << 48) |
                               ((uint64_t)msg[13] << 40) | ((uint64_t)msg[14] << 32) |
                               ((uint64_t)msg[15] << 24) | ((uint64_t)msg[16] << 16) |
                               ((uint64_t)msg[17] << 8)  | msg[18];
            
            ord.buy_sell = msg[19];
            ord.shares = ((uint32_t)msg[20] << 24) | ((uint32_t)msg[21] << 16) |
                         ((uint32_t)msg[22] << 8)  | msg[23];
            
            std::memcpy(ord.symbol, &msg[24], 8);
            ord.price = ((uint32_t)msg[32] << 24) | ((uint32_t)msg[33] << 16) |
                        ((uint32_t)msg[34] << 8)  | msg[35];

            order_store[ord.order_ref_id] = ord;
            target_symbol = std::string(ord.symbol, 8);
            
            BBOBook& book = book_store[target_symbol];
            std::memcpy(book.symbol, ord.symbol, 8);
            if (ord.buy_sell == 'B') {
                if (ord.price > book.bid_price) {
                    book.bid_price = ord.price;
                    book.bid_size = ord.shares;
                    bbo_changed = true;
                }
            } else if (ord.buy_sell == 'S') {
                if (ord.price < book.ask_price) {
                    book.ask_price = ord.price;
                    book.ask_size = ord.shares;
                    bbo_changed = true;
                }
            }
        }
        else if (type == 'E') {
            if (len < 31) return false;
            uint64_t ref_id = ((uint64_t)msg[11] << 56) | ((uint64_t)msg[12] << 48) |
                              ((uint64_t)msg[13] << 40) | ((uint64_t)msg[14] << 32) |
                              ((uint64_t)msg[15] << 24) | ((uint64_t)msg[16] << 16) |
                              ((uint64_t)msg[17] << 8)  | msg[18];
            uint32_t exec_shares = ((uint32_t)msg[19] << 24) | ((uint32_t)msg[20] << 16) |
                                   ((uint32_t)msg[21] << 8)  | msg[22];

            auto it = order_store.find(ref_id);
            if (it != order_store.end()) {
                Order& ord = it->second;
                if (ord.shares >= exec_shares) {
                    ord.shares -= exec_shares;
                    target_symbol = std::string(ord.symbol, 8);
                    BBOBook& book = book_store[target_symbol];
                    if (ord.buy_sell == 'B' && ord.price == book.bid_price) {
                        book.bid_size = (book.bid_size > exec_shares) ? (book.bid_size - exec_shares) : 0;
                        bbo_changed = true;
                    }
                }
            }
        }
        else if (type == 'X') {
            if (len < 23) return false;
            uint64_t ref_id = ((uint64_t)msg[11] << 56) | ((uint64_t)msg[12] << 48) |
                              ((uint64_t)msg[13] << 40) | ((uint64_t)msg[14] << 32) |
                              ((uint64_t)msg[15] << 24) | ((uint64_t)msg[16] << 16) |
                              ((uint64_t)msg[17] << 8)  | msg[18];
            uint32_t cancel_shares = ((uint32_t)msg[19] << 24) | ((uint32_t)msg[20] << 16) |
                                     ((uint32_t)msg[21] << 8)  | msg[22];

            auto it = order_store.find(ref_id);
            if (it != order_store.end()) {
                Order& ord = it->second;
                if (ord.shares >= cancel_shares) {
                    ord.shares -= cancel_shares;
                    target_symbol = std::string(ord.symbol, 8);
                    BBOBook& book = book_store[target_symbol];
                    if (ord.buy_sell == 'B' && ord.price == book.bid_price) {
                        book.bid_size = (book.bid_size > cancel_shares) ? (book.bid_size - cancel_shares) : 0;
                        bbo_changed = true;
                    }
                }
            }
        }
        else if (type == 'D') {
            if (len < 19) return false;
            uint64_t ref_id = ((uint64_t)msg[11] << 56) | ((uint64_t)msg[12] << 48) |
                              ((uint64_t)msg[13] << 40) | ((uint64_t)msg[14] << 32) |
                              ((uint64_t)msg[15] << 24) | ((uint64_t)msg[16] << 16) |
                              ((uint64_t)msg[17] << 8)  | msg[18];

            auto it = order_store.find(ref_id);
            if (it != order_store.end()) {
                auto ord = it->second;
                target_symbol = std::string(ord.symbol, 8);
                order_store.erase(it);
                
                BBOBook& book = book_store[target_symbol];
                if (ord.buy_sell == 'B' && ord.price == book.bid_price) {
                    book.bid_price = 0;
                    book.bid_size = 0;
                    bbo_changed = true;
                } else if (ord.buy_sell == 'S' && ord.price == book.ask_price) {
                    book.ask_price = 0xFFFFFFFF;
                    book.ask_size = 0;
                    bbo_changed = true;
                }
            }
        }
        else if (type == 'U') {
            if (len < 35) return false;
            uint64_t orig_ref_id = ((uint64_t)msg[11] << 56) | ((uint64_t)msg[12] << 48) |
                                   ((uint64_t)msg[13] << 40) | ((uint64_t)msg[14] << 32) |
                                   ((uint64_t)msg[15] << 24) | ((uint64_t)msg[16] << 16) |
                                   ((uint64_t)msg[17] << 8)  | msg[18];
            uint64_t new_ref_id  = ((uint64_t)msg[19] << 56) | ((uint64_t)msg[20] << 48) |
                                   ((uint64_t)msg[21] << 40) | ((uint64_t)msg[22] << 32) |
                                   ((uint64_t)msg[23] << 24) | ((uint64_t)msg[24] << 16) |
                                   ((uint64_t)msg[25] << 8)  | msg[26];
            uint32_t new_shares  = ((uint32_t)msg[27] << 24) | ((uint32_t)msg[28] << 16) |
                                   ((uint32_t)msg[29] << 8)  | msg[30];
            uint32_t new_price   = ((uint32_t)msg[31] << 24) | ((uint32_t)msg[32] << 16) |
                                   ((uint32_t)msg[33] << 8)  | msg[34];

            auto it = order_store.find(orig_ref_id);
            if (it != order_store.end()) {
                // Copy side and stock from the original order before erasing
                auto old_ord = it->second;
                order_store.erase(it);

                target_symbol = std::string(old_ord.symbol, 8);
                BBOBook& book = book_store[target_symbol];
                if (old_ord.buy_sell == 'B' && old_ord.price == book.bid_price) {
                    book.bid_price = 0;
                    book.bid_size = 0;
                }
                if (old_ord.buy_sell == 'S' && old_ord.price == book.ask_price) {
                    book.ask_price = 0xFFFFFFFF;
                    book.ask_size = 0;
                }

                Order new_ord;
                new_ord.order_ref_id = new_ref_id;
                new_ord.buy_sell     = old_ord.buy_sell;
                new_ord.shares       = new_shares;
                std::memcpy(new_ord.symbol, old_ord.symbol, 8);
                new_ord.price        = new_price;
                order_store[new_ref_id] = new_ord;

                if (new_ord.buy_sell == 'B') {
                    if (new_price > book.bid_price) {
                        book.bid_price = new_price;
                        book.bid_size = new_shares;
                        bbo_changed = true;
                    }
                } else if (new_ord.buy_sell == 'S') {
                    if (new_price < book.ask_price) {
                        book.ask_price = new_price;
                        book.ask_size = new_shares;
                        bbo_changed = true;
                    }
                }
            }
        }

        bool arb_detected = false;
        if (bbo_changed && rate_ab > 0 && rate_bc > 0 && rate_ca > 0) {
            // Q8.24 multiplication: product = (ab * bc * ca) >> 48
            uint64_t temp_prod = ((uint64_t)rate_ab * rate_bc) >> 24;
            uint64_t final_prod = (temp_prod * rate_ca) >> 24;
            
            if (final_prod > threshold) {
                arb_detected = true;
            }
        }

        auto end_time = std::chrono::high_resolution_clock::now();
        latency_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(end_time - start_time).count();
        return arb_detected;
    }
};
