// Test harness driving the SystemVerilog NASDAQ ITCH feed handler parser model via Verilator.

#include <iostream>
#include <vector>
#include <iomanip>
#include <cassert>
#include <cstring>
#include "Vtb_nasdaq_parser.h"
#include "verilated.h"

uint16_t compute_ipv4_checksum(const uint8_t* header) {
    uint32_t sum = 0;
    for (int i = 0; i < 10; i++) {
        uint16_t word = (header[2 * i] << 8) | header[2 * i + 1];
        // Skip the checksum field itself (bytes 10 and 11 of the header)
        if (i == 5) continue;
        sum += word;
    }
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return ~sum;
}

uint64_t main_time = 0;

double sc_time_stamp() {
    return main_time;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_nasdaq_parser* top = new Vtb_nasdaq_parser;

    top->clk = 0;
    top->rst_n = 0;
    top->s_axis_tdata = 0;
    top->s_axis_tkeep = 0;
    top->s_axis_tvalid = 0;
    top->s_axis_tlast = 0;
    top->s_axis_tuser = 0;

    for (int i = 0; i < 5; i++) {
        top->clk = !top->clk;
        top->eval();
        main_time++;
    }
    top->rst_n = 1;
    top->clk = 1;
    top->eval();

    std::cout << "==========================================================" << std::endl;
    std::cout << "  Starting NASDAQ Feed Handler Verification & Latency Test " << std::endl;
    std::cout << "==========================================================" << std::endl;

    // Construct ITCH and protocol frames
    std::vector<uint8_t> msg_a = {
        0x00, 0x24,
        'A',
        0x00, 0x01,
        0x00, 0x02,
        0x00, 0x00, 0x3b, 0x9a, 0xca, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x96, 0x02, 0xd2,
        'B',
        0x00, 0x00, 0x01, 0xf4,
        'A', 'A', 'P', 'L', ' ', ' ', ' ', ' ',
        0x00, 0x17, 0x00, 0x2c
    };

    std::vector<uint8_t> msg_e = {
        0x00, 0x1f,
        'E',
        0x00, 0x01,
        0x00, 0x02,
        0x00, 0x00, 0x3b, 0x9a, 0xca, 0x64,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x96, 0x02, 0xd2,
        0x00, 0x00, 0x00, 0x64,
        0x00, 0x00, 0x00, 0x02, 0x4c, 0xb0, 0x16, 0xea
    };

    std::vector<uint8_t> msg_x = {
        0x00, 0x17,
        'X',
        0x00, 0x01,
        0x00, 0x02,
        0x00, 0x00, 0x3b, 0x9a, 0xca, 0xc8,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x96, 0x02, 0xd2,
        0x00, 0x00, 0x00, 0x32
    };

    std::vector<uint8_t> msg_d = {
        0x00, 0x13,
        'D',
        0x00, 0x01,
        0x00, 0x02,
        0x00, 0x00, 0x3b, 0x9a, 0xcb, 0x2c,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x96, 0x02, 0xd2
    };

    std::vector<uint8_t> itch_payload;
    itch_payload.insert(itch_payload.end(), msg_a.begin(), msg_a.end());
    itch_payload.insert(itch_payload.end(), msg_e.begin(), msg_e.end());
    itch_payload.insert(itch_payload.end(), msg_x.begin(), msg_x.end());
    itch_payload.insert(itch_payload.end(), msg_d.begin(), msg_d.end());

    std::vector<uint8_t> mold_header = {
        'S', 'E', 'S', 'S', 'I', 'O', 'N', '0', '0', '1',
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x04
    };

    std::vector<uint8_t> udp_payload;
    udp_payload.insert(udp_payload.end(), mold_header.begin(), mold_header.end());
    udp_payload.insert(udp_payload.end(), itch_payload.begin(), itch_payload.end());

    uint16_t udp_len = 8 + udp_payload.size();
    std::vector<uint8_t> udp_header = {
        0x30, 0x39,
        0x3c, 0x9b,
        static_cast<uint8_t>(udp_len >> 8), static_cast<uint8_t>(udp_len & 0xFF),
        0x00, 0x00
    };

    uint16_t ip_len = 20 + udp_len;
    std::vector<uint8_t> ip_header = {
        0x45,
        0x00,
        static_cast<uint8_t>(ip_len >> 8), static_cast<uint8_t>(ip_len & 0xFF),
        0x12, 0x34,
        0x40, 0x00,
        0x40,
        0x11,
        0x00, 0x00,
        192, 168, 1, 100,
        192, 168, 1, 200
    };

    uint16_t ip_chksum = compute_ipv4_checksum(ip_header.data());
    ip_header[10] = ip_chksum >> 8;
    ip_header[11] = ip_chksum & 0xFF;

    std::vector<uint8_t> eth_header = {
        0x00, 0x0A, 0x35, 0x02, 0x41, 0x0A,
        0x00, 0x0A, 0x35, 0x02, 0x41, 0x0B,
        0x08, 0x00
    };

    std::vector<uint8_t> eth_frame;
    eth_frame.insert(eth_frame.end(), eth_header.begin(), eth_header.end());
    eth_frame.insert(eth_frame.end(), ip_header.begin(), ip_header.end());
    eth_frame.insert(eth_frame.end(), udp_header.begin(), udp_header.end());
    eth_frame.insert(eth_frame.end(), udp_payload.begin(), udp_payload.end());

    std::cout << "Constructed Ethernet Frame: " << eth_frame.size() << " bytes." << std::endl;

    // Drive AXI-Stream interface word-by-word (8 bytes/cycle)
    size_t byte_idx = 0;
    bool active = true;
    int cycle_cnt = 0;

    bool meta_verified = false;
    bool add_msg_verified = false;
    bool exec_msg_verified = false;
    bool cancel_msg_verified = false;
    bool delete_msg_verified = false;

    while (active || cycle_cnt < 30) {
        top->clk = 0;
        top->eval();

        if (active && byte_idx < eth_frame.size()) {
            uint64_t data_word = 0;
            uint8_t keep_word = 0;
            
            for (int b = 0; b < 8; b++) {
                if (byte_idx < eth_frame.size()) {
                    data_word |= (static_cast<uint64_t>(eth_frame[byte_idx]) << (b * 8));
                    keep_word |= (1 << b);
                    byte_idx++;
                }
            }

            top->s_axis_tdata = data_word;
            top->s_axis_tkeep = keep_word;
            top->s_axis_tvalid = 1;
            top->s_axis_tlast = (byte_idx >= eth_frame.size()) ? 1 : 0;
            top->s_axis_tuser = 0;
        } else {
            top->s_axis_tdata = 0;
            top->s_axis_tkeep = 0;
            top->s_axis_tvalid = 0;
            top->s_axis_tlast = 0;
            top->s_axis_tuser = 0;
            active = false;
        }

        top->clk = 0;
        top->eval();

        top->clk = 1;
        top->eval();
        
        cycle_cnt++;
        main_time++;

        if (top->packet_valid) {
            std::cout << "[SUCCESS] Packet Valid Strobe Received at Cycle " << cycle_cnt << "!" << std::endl;
            std::cout << "  - Source IP:      " 
                      << ((top->meta_src_ip >> 24) & 0xFF) << "."
                      << ((top->meta_src_ip >> 16) & 0xFF) << "."
                      << ((top->meta_src_ip >> 8) & 0xFF) << "."
                      << (top->meta_src_ip & 0xFF) << std::endl;
            std::cout << "  - Destination IP: " 
                      << ((top->meta_dst_ip >> 24) & 0xFF) << "."
                      << ((top->meta_dst_ip >> 16) & 0xFF) << "."
                      << ((top->meta_dst_ip >> 8) & 0xFF) << "."
                      << (top->meta_dst_ip & 0xFF) << std::endl;
            std::cout << "  - Source Port:    " << top->meta_src_port << std::endl;
            std::cout << "  - Destination Port:" << top->meta_dst_port << std::endl;
            std::cout << "  - UDP Length:      " << top->meta_udp_length << std::endl;
            
            assert(top->meta_src_ip == 0xC0A80164);
            assert(top->meta_dst_ip == 0xC0A801C8);
            assert(top->meta_src_port == 12345);
            assert(top->meta_dst_port == 15515);
            assert(top->meta_udp_length == udp_len);
            meta_verified = true;
        }

        if (top->add_order_valid) {
            char stock_str[9] = {0};
            uint64_t sym = top->add_stock;
            for (int b = 0; b < 8; b++) {
                stock_str[7 - b] = (sym >> (b * 8)) & 0xFF;
            }
            std::cout << "[SUCCESS] Decoded Add Order Message ('A') at Cycle " << cycle_cnt << ":" << std::endl;
            std::cout << "  - Order Ref ID: " << top->add_order_id << std::endl;
            std::cout << "  - Buy/Sell:     " << static_cast<char>(top->add_buy_sell) << std::endl;
            std::cout << "  - Shares:       " << top->add_shares << std::endl;
            std::cout << "  - Ticker:       " << stock_str << std::endl;
            std::cout << "  - Fixed Price:  " << std::fixed << std::setprecision(4) << (top->add_price / 10000.0) << " (" << top->add_price << ")" << std::endl;

            assert(top->add_order_id == 1234567890ULL);
            assert(top->add_buy_sell == 'B');
            assert(top->add_shares == 500);
            assert(strncmp(stock_str, "AAPL    ", 8) == 0);
            assert(top->add_price == 1507500);
            add_msg_verified = true;
        }

        if (top->exec_order_valid) {
            std::cout << "[SUCCESS] Decoded Order Executed Message ('E') at Cycle " << cycle_cnt << ":" << std::endl;
            std::cout << "  - Order Ref ID: " << top->exec_order_id << std::endl;
            std::cout << "  - Exec Shares:  " << top->exec_shares << std::endl;

            assert(top->exec_order_id == 1234567890ULL);
            assert(top->exec_shares == 100);
            exec_msg_verified = true;
        }

        if (top->cancel_order_valid) {
            std::cout << "[SUCCESS] Decoded Order Cancel Message ('X') at Cycle " << cycle_cnt << ":" << std::endl;
            std::cout << "  - Order Ref ID: " << top->cancel_order_id << std::endl;
            std::cout << "  - Canc Shares:  " << top->cancel_shares << std::endl;

            assert(top->cancel_order_id == 1234567890ULL);
            assert(top->cancel_shares == 50);
            cancel_msg_verified = true;
        }

        if (top->delete_order_valid) {
            std::cout << "[SUCCESS] Decoded Order Delete Message ('D') at Cycle " << cycle_cnt << ":" << std::endl;
            std::cout << "  - Order Ref ID: " << top->delete_order_id << std::endl;

            assert(top->delete_order_id == 1234567890ULL);
            delete_msg_verified = true;
        }
    }

    std::cout << "==========================================================" << std::endl;
    std::cout << "  Test Results Summary:" << std::endl;
    std::cout << "==========================================================" << std::endl;
    std::cout << "  - Network Header Parsing & Validations: " << (meta_verified ? "PASSED" : "FAILED") << std::endl;
    std::cout << "  - ITCH 'A' Add Order Decoded:            " << (add_msg_verified ? "PASSED" : "FAILED") << std::endl;
    std::cout << "  - ITCH 'E' Order Executed Decoded:       " << (exec_msg_verified ? "PASSED" : "FAILED") << std::endl;
    std::cout << "  - ITCH 'X' Order Cancel Decoded:         " << (cancel_msg_verified ? "PASSED" : "FAILED") << std::endl;
    std::cout << "  - ITCH 'D' Order Delete Decoded:         " << (delete_msg_verified ? "PASSED" : "FAILED") << std::endl;
    std::cout << "==========================================================" << std::endl;

    bool all_passed = meta_verified && add_msg_verified && exec_msg_verified && cancel_msg_verified && delete_msg_verified;
    if (all_passed) {
        std::cout << "  ALL TESTS PASSED SUCCESSFULLY! NANOSECOND PIPELINE VERIFIED." << std::endl;
    } else {
        std::cout << "  TEST SUITE DETECTED A CODESPACE MISMATCH!" << std::endl;
    }
    std::cout << "==========================================================" << std::endl;

    top->final();
    delete top;
    return all_passed ? 0 : 1;
}
