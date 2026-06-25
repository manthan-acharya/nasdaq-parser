// End-to-end simulation driver streaming Python-generated packets into the Verilator model.

#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <iomanip>
#include <cstdlib>
#include <cassert>
#include <cstring>
#include "Vtb_nasdaq_parser.h"
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    std::ifstream check_file("raw_packets.bin");
    if (!check_file.good()) {
        std::cout << "[INFO] raw_packets.bin not found. Running generate_ticks.py..." << std::endl;
        int status = std::system("python3 generate_ticks.py");
        (void)status;
    }
    check_file.close();

    std::ifstream infile("raw_packets.bin", std::ios::binary);
    if (!infile.good()) {
        std::cerr << "[ERROR] Could not open raw_packets.bin!" << std::endl;
        return 1;
    }

    Vtb_nasdaq_parser* top = new Vtb_nasdaq_parser;

    top->clk = 0;
    top->rst_n = 0;
    top->s_axis_tdata = 0;
    top->s_axis_tkeep = 0;
    top->s_axis_tvalid = 0;
    top->s_axis_tlast = 0;
    top->s_axis_tuser = 0;

    for (int i = 0; i < 10; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst_n = 1;
    top->clk = 1;
    top->eval();

    std::cout << "=======================================================================" << std::endl;
    std::cout << "  Starting NASDAQ Pipeline End-to-End Feed Handler Simulation" << std::endl;
    std::cout << "=======================================================================" << std::endl;

    uint64_t main_time = 0;
    int packet_num = 1;

    int add_count = 0;
    int exec_count = 0;
    int cancel_count = 0;
    int delete_count = 0;
    int replace_count = 0;
    int valid_pkts = 0;

    while (infile.peek() != EOF) {
        uint32_t pkt_len = 0;
        infile.read(reinterpret_cast<char*>(&pkt_len), sizeof(pkt_len));
        if (infile.gcount() != sizeof(pkt_len)) break;

        std::vector<uint8_t> pkt(pkt_len);
        infile.read(reinterpret_cast<char*>(pkt.data()), pkt_len);
        if (infile.gcount() != pkt_len) {
            std::cerr << "[ERROR] Premature end of file reading packet data!" << std::endl;
            break;
        }

        std::cout << "\n--- Streaming Packet " << packet_num++ << " (" << pkt_len << " bytes) ---" << std::endl;

        size_t byte_idx = 0;
        bool active = true;
        uint64_t start_cycle = main_time;

        while (active || byte_idx < pkt.size()) {
            top->clk = 0;

            if (byte_idx < pkt.size()) {
                uint64_t data_word = 0;
                uint8_t keep_word = 0;
                for (int b = 0; b < 8; b++) {
                    if (byte_idx < pkt.size()) {
                        data_word |= (static_cast<uint64_t>(pkt[byte_idx]) << (b * 8));
                        keep_word |= (1 << b);
                        byte_idx++;
                    }
                }
                top->s_axis_tdata = data_word;
                top->s_axis_tkeep = keep_word;
                top->s_axis_tvalid = 1;
                top->s_axis_tlast = (byte_idx >= pkt.size()) ? 1 : 0;
            } else {
                top->s_axis_tvalid = 0;
                top->s_axis_tkeep = 0;
                top->s_axis_tlast = 0;
                active = false;
            }

            top->eval();
            top->clk = 1;
            top->eval();
            
            main_time++;
            uint64_t curr_cycle = main_time;

            if (top->packet_valid) {
                valid_pkts++;
                std::cout << "[NET] Packet Header Decoded at Cycle " << curr_cycle << ":" << std::endl;
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
                std::cout << "  - Src Port:       " << top->meta_src_port << std::endl;
                std::cout << "  - Dst Port:       " << top->meta_dst_port << std::endl;
                std::cout << "  - UDP Length:     " << top->meta_udp_length << std::endl;
            }

            if (top->add_order_valid) {
                add_count++;
                char stock_str[9] = {0};
                uint64_t sym = top->add_stock;
                for (int b = 0; b < 8; b++) {
                    stock_str[7 - b] = (sym >> (b * 8)) & 0xFF;
                }
                uint64_t latency = curr_cycle - start_cycle;
                std::cout << "[ITCH] ADD ORDER Decoded (Latency: " << latency << " cycles):" << std::endl;
                std::cout << "  - Order Ref ID: " << top->add_order_id << std::endl;
                std::cout << "  - Buy/Sell:     " << static_cast<char>(top->add_buy_sell) << std::endl;
                std::cout << "  - Shares:       " << top->add_shares << std::endl;
                std::cout << "  - Ticker:       " << stock_str << std::endl;
                std::cout << "  - Price:        " << std::fixed << std::setprecision(4) << (top->add_price / 10000.0) 
                          << " (Fixed: " << top->add_price << ")" << std::endl;
            }

            if (top->exec_order_valid) {
                exec_count++;
                uint64_t latency = curr_cycle - start_cycle;
                std::cout << "[ITCH] ORDER EXECUTED Decoded (Latency: " << latency << " cycles):" << std::endl;
                std::cout << "  - Order Ref ID: " << top->exec_order_id << std::endl;
                std::cout << "  - Shares:       " << top->exec_shares << std::endl;
            }

            if (top->cancel_order_valid) {
                cancel_count++;
                uint64_t latency = curr_cycle - start_cycle;
                std::cout << "[ITCH] ORDER CANCEL Decoded (Latency: " << latency << " cycles):" << std::endl;
                std::cout << "  - Order Ref ID: " << top->cancel_order_id << std::endl;
                std::cout << "  - Shares:       " << top->cancel_shares << std::endl;
            }

            if (top->delete_order_valid) {
                delete_count++;
                uint64_t latency = curr_cycle - start_cycle;
                std::cout << "[ITCH] ORDER DELETE Decoded (Latency: " << latency << " cycles):" << std::endl;
                std::cout << "  - Order Ref ID: " << top->delete_order_id << std::endl;
            }

            if (top->replace_order_valid) {
                replace_count++;
                uint64_t latency = curr_cycle - start_cycle;
                std::cout << "[ITCH] ORDER REPLACE Decoded (Latency: " << latency << " cycles):" << std::endl;
                std::cout << "  - Original Order ID: " << top->replace_original_order_id << std::endl;
                std::cout << "  - New Order ID:      " << top->replace_new_order_id << std::endl;
                std::cout << "  - Shares:            " << top->replace_shares << std::endl;
                std::cout << "  - Price:             " << std::fixed << std::setprecision(4) << (top->replace_price / 10000.0) 
                          << " (Fixed: " << top->replace_price << ")" << std::endl;
            }
        }
    }

    std::cout << "\n=======================================================================" << std::endl;
    std::cout << "  Simulation Results Summary:" << std::endl;
    std::cout << "=======================================================================" << std::endl;
    std::cout << "  - Total Valid IP/UDP Packets: " << valid_pkts << " / 5" << std::endl;
    std::cout << "  - Total ITCH Add Orders:      " << add_count << " / 3" << std::endl;
    std::cout << "  - Total ITCH Order Executions:" << exec_count << " / 1" << std::endl;
    std::cout << "  - Total ITCH Order Cancels:   " << cancel_count << " / 1" << std::endl;
    std::cout << "  - Total ITCH Order Deletes:   " << delete_count << " / 1" << std::endl;
    std::cout << "  - Total ITCH Order Replaces:  " << replace_count << " / 1" << std::endl;
    std::cout << "=======================================================================" << std::endl;

    bool all_passed = (valid_pkts == 5) && (add_count == 3) && (exec_count == 1) && 
                      (cancel_count == 1) && (delete_count == 1) && (replace_count == 1);

    if (all_passed) {
        std::cout << "  [STATUS] ALL END-TO-END TESTS PASSED SUCCESSFULLY!" << std::endl;
    } else {
        std::cout << "  [STATUS] COMPILATION COMPLETED BUT LOB PIPELINE HAS INTEGRATION ERRORS." << std::endl;
    }
    std::cout << "=======================================================================" << std::endl;

    top->final();
    delete top;
    return all_passed ? 0 : 1;
}
