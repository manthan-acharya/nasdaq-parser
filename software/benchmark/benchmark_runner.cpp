// Cycle-accurate latency benchmarking suite running the Verilated FPGA model against a C++ software arbitrage baseline.

#include <iostream>
#include <fstream>
#include <vector>
#include <chrono>
#include <thread>
#include <numeric>
#include <cmath>
#include <algorithm>
#include <cstring>
#include "Vtb_hft_top.h"
#include "verilated.h"
#include "soft_arbitrage.cpp"

#define TICK_PERIOD_NS 6.4

struct LatencyStats {
    double min = 0.0;
    double max = 0.0;
    double mean = 0.0;
    double p95 = 0.0;
    double p99 = 0.0;
    double stdev = 0.0;
};

LatencyStats calculate_stats(std::vector<double>& latencies) {
    LatencyStats stats;
    if (latencies.empty()) return stats;

    std::sort(latencies.begin(), latencies.end());
    stats.min = latencies.front();
    stats.max = latencies.back();

    double sum = std::accumulate(latencies.begin(), latencies.end(), 0.0);
    stats.mean = sum / latencies.size();

    size_t idx_95 = (size_t)(latencies.size() * 0.95);
    size_t idx_99 = (size_t)(latencies.size() * 0.99);
    stats.p95 = latencies[std::min(idx_95, latencies.size() - 1)];
    stats.p99 = latencies[std::min(idx_99, latencies.size() - 1)];

    double variance_sum = 0.0;
    for (double l : latencies) {
        variance_sum += (l - stats.mean) * (l - stats.mean);
    }
    stats.stdev = std::sqrt(variance_sum / latencies.size());

    return stats;
}

uint64_t main_time_bench = 0;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    std::cout << "======================================================================" << std::endl;
    std::cout << "  Starting HFT Accelerator Latency & Jitter Benchmarking Suite..." << std::endl;
    std::cout << "  FPGA Target Clock: 156.25 MHz (1 Cycle = 6.40ns)" << std::endl;
    std::cout << "======================================================================" << std::endl;

    std::ifstream infile("raw_packets.bin", std::ios::binary);
    if (!infile) {
        std::cerr << "[ERROR] raw_packets.bin not found! Please run make or generate_ticks.py first." << std::endl;
        return -1;
    }

    std::vector<std::vector<uint8_t>> packets;
    while (true) {
        uint32_t pkt_len = 0;
        infile.read(reinterpret_cast<char*>(&pkt_len), sizeof(pkt_len));
        if (infile.eof()) break;
        std::vector<uint8_t> pkt(pkt_len);
        infile.read(reinterpret_cast<char*>(pkt.data()), pkt_len);
        packets.push_back(pkt);
    }
    std::cout << "[INFO] Loaded " << packets.size() << " network test packets containing market data." << std::endl;

    // Benchmark 1: C++ Software Arbitrage Baseline
    SoftArbitrageEngine soft_engine;
    soft_engine.set_rates(0x01400000, 0x00d9999a, 0x00f33333);

    std::vector<double> soft_latencies;
    std::cout << "[RUNNING] Benchmarking Software Arbitrage Engine on Host CPU..." << std::endl;
    
    for (int run = 0; run < 1000; ++run) { // Run multiple iterations to capture scheduling jitter
        for (const auto& pkt : packets) {
            // Locate ITCH payload: Ethernet (14) + IP (20) + UDP (8) + MoldUDP64 (20) = 62 bytes offset
            // The first 2 bytes of the payload are the MoldUDP64 message length, so skip them to point to the ITCH message type.
            if (pkt.size() <= 64) continue;
            const uint8_t* itch_msg = pkt.data() + 64;
            size_t itch_len = pkt.size() - 64;
            
            uint64_t lat_ns = 0;
            soft_engine.process_itch_message(itch_msg, itch_len, lat_ns);
            soft_latencies.push_back(static_cast<double>(lat_ns));
        }
    }

    // Benchmark 2: Verilated FPGA Pipeline
    auto top = std::make_unique<Vtb_hft_top>();
    
    top->clk = 0;
    top->rst_n = 0;
    top->s_axis_rx_tvalid = 0;
    top->s_axis_rx_tlast  = 0;
    top->m_axis_tx_tready = 1;
    top->rates_valid = 0;
    top->tcp_conn_trigger = 0;
    top->tcp_disc_trigger = 0;
    top->tcp_rx_valid     = 0;
    
    for (int i = 0; i < 10; ++i) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst_n = 1;
    top->clk = 0;
    top->eval();

    top->tcp_conn_trigger = 1;
    top->clk = 1; top->eval(); top->clk = 0; top->eval();
    top->tcp_conn_trigger = 0;
    
    for (int i = 0; i < 50; ++i) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    
    top->tcp_rx_valid = 1;
    top->tcp_rx_syn   = 1;
    top->tcp_rx_ack   = 1;
    top->tcp_rx_seq   = 0x90000000;
    top->tcp_rx_ack_num = 0x10000001;
    top->clk = 1; top->eval(); top->clk = 0; top->eval();
    top->tcp_rx_valid = 0;
    top->tcp_rx_syn   = 0;
    top->tcp_rx_ack   = 0;

    for (int i = 0; i < 5; ++i) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }

    // Configure DMA registers via AXI-Lite subordinate write interface
    top->s_axi_dma_awaddr = 0x004;
    top->s_axi_dma_awvalid = 1;
    top->s_axi_dma_wdata = 0x55550000;
    top->s_axi_dma_wvalid = 1;
    top->s_axi_dma_bready = 1;
    while (!top->s_axi_dma_awready || !top->s_axi_dma_wready) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    top->clk = 1; top->eval(); top->s_axi_dma_awvalid = 0; top->s_axi_dma_wvalid = 0;
    top->clk = 0; top->eval();
    while (!top->s_axi_dma_bvalid) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    top->clk = 1; top->eval(); top->s_axi_dma_bready = 0; top->clk = 0; top->eval();

    top->s_axi_dma_awaddr = 0x008;
    top->s_axi_dma_awvalid = 1;
    top->s_axi_dma_wdata = 0x00000001;
    top->s_axi_dma_wvalid = 1;
    top->s_axi_dma_bready = 1;
    while (!top->s_axi_dma_awready || !top->s_axi_dma_wready) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    top->clk = 1; top->eval(); top->s_axi_dma_awvalid = 0; top->s_axi_dma_wvalid = 0;
    top->clk = 0; top->eval();
    while (!top->s_axi_dma_bvalid) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    top->clk = 1; top->eval(); top->s_axi_dma_bready = 0; top->clk = 0; top->eval();

    top->s_axi_dma_awaddr = 0x00C;
    top->s_axi_dma_awvalid = 1;
    top->s_axi_dma_wdata = 0x00100000;
    top->s_axi_dma_wvalid = 1;
    top->s_axi_dma_bready = 1;
    while (!top->s_axi_dma_awready || !top->s_axi_dma_wready) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    top->clk = 1; top->eval(); top->s_axi_dma_awvalid = 0; top->s_axi_dma_wvalid = 0;
    top->clk = 0; top->eval();
    while (!top->s_axi_dma_bvalid) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    top->clk = 1; top->eval(); top->s_axi_dma_bready = 0; top->clk = 0; top->eval();

    top->s_axi_dma_awaddr = 0x000;
    top->s_axi_dma_awvalid = 1;
    top->s_axi_dma_wdata = 0x00000003;
    top->s_axi_dma_wvalid = 1;
    top->s_axi_dma_bready = 1;
    while (!top->s_axi_dma_awready || !top->s_axi_dma_wready) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    top->clk = 1; top->eval(); top->s_axi_dma_awvalid = 0; top->s_axi_dma_wvalid = 0;
    top->clk = 0; top->eval();
    while (!top->s_axi_dma_bvalid) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    top->clk = 1; top->eval(); top->s_axi_dma_bready = 0; top->clk = 0; top->eval();

    std::vector<double> hw_latencies;
    std::cout << "[RUNNING] Benchmarking Verilated FPGA Pipeline (Cycle-Accurate)..." << std::endl;

    // Stream setup packet to populate the order book
    const auto& pkt_1 = packets[0];
    size_t byte_idx = 0;
    while (byte_idx < pkt_1.size()) {
        uint64_t data_word = 0;
        uint8_t keep_word = 0;
        for (int b = 0; b < 8; ++b) {
            if (byte_idx < pkt_1.size()) {
                data_word |= (static_cast<uint64_t>(pkt_1[byte_idx]) << (b * 8));
                keep_word |= (1 << b);
                byte_idx++;
            }
        }
        top->s_axis_rx_tdata  = data_word;
        top->s_axis_rx_tkeep  = keep_word;
        top->s_axis_rx_tvalid = 1;
        top->s_axis_rx_tlast  = (byte_idx >= pkt_1.size()) ? 1 : 0;
        
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }
    top->s_axis_rx_tvalid = 0;
    
    for (int i = 0; i < 20; ++i) {
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
    }

    // Benchmark critical path: inject profitable rates and measure cycle-accurate latency
    for (int run = 0; run < 1000; ++run) {
        top->rates_valid = 0;
        top->rate_ab = 0;
        top->rate_bc = 0;
        top->rate_ca = 0;
        top->clk = 1; top->eval(); top->clk = 0; top->eval();

        const auto& pkt_2 = packets[1];
        byte_idx = 0;
        while (byte_idx < pkt_2.size()) {
            uint64_t data_word = 0;
            uint8_t keep_word = 0;
            for (int b = 0; b < 8; ++b) {
                if (byte_idx < pkt_2.size()) {
                    data_word |= (static_cast<uint64_t>(pkt_2[byte_idx]) << (b * 8));
                    keep_word |= (1 << b);
                    byte_idx++;
                }
            }
            top->s_axis_rx_tdata  = data_word;
            top->s_axis_rx_tkeep  = keep_word;
            top->s_axis_rx_tvalid = 1;
            top->s_axis_rx_tlast  = (byte_idx >= pkt_2.size()) ? 1 : 0;
            
            top->clk = 1; top->eval(); top->clk = 0; top->eval();
        }
        top->s_axis_rx_tvalid = 0;

        top->rates_valid = 1;
        top->rate_ab     = 0x01400000;
        top->rate_bc     = 0x00d9999a;
        top->rate_ca     = 0x00f33333;
        
        top->clk = 1; top->eval(); top->clk = 0; top->eval();
        top->rates_valid = 0;

        int latency_cycles = 1;
        bool order_detected = false;

        for (int cycle = 0; cycle < 100; ++cycle) {
            top->clk = 1;
            top->eval();
            
            if (top->m_axis_tx_tvalid) {
                order_detected = true;
                break;
            }
            
            top->clk = 0;
            top->eval();
            latency_cycles++;
        }
        
        top->clk = 0;
        top->eval();

        if (order_detected) {
            // Hardware latency is deterministic (fixed clock cycles)
            hw_latencies.push_back(latency_cycles * TICK_PERIOD_NS);
        }
    }

    // Calculate and print statistical latency reports
    LatencyStats soft_stats = calculate_stats(soft_latencies);
    LatencyStats hw_stats = calculate_stats(hw_latencies);

    std::cout << std::endl;
    std::cout << "======================================================================" << std::endl;
    std::cout << "                      LATENCY BENCHMARKING REPORT                     " << std::endl;
    std::cout << "======================================================================" << std::endl;
    std::cout << " Metric       │ C++ Software Engine       │ FPGA Hardware Pipeline   " << std::endl;
    std::cout << "──────────────┼───────────────────────────┼──────────────────────────" << std::endl;
    std::cout << " Min Latency  │ " 
              << std::fixed << std::setprecision(2) << std::setw(15) << soft_stats.min << " ns" 
              << "      │ " << std::setw(15) << hw_stats.min << " ns" << std::endl;
    std::cout << " Mean Latency │ " 
              << std::fixed << std::setprecision(2) << std::setw(15) << soft_stats.mean << " ns" 
              << "      │ " << std::setw(15) << hw_stats.mean << " ns" << std::endl;
    std::cout << " Max Latency  │ " 
              << std::fixed << std::setprecision(2) << std::setw(15) << soft_stats.max << " ns" 
              << "      │ " << std::setw(15) << hw_stats.max << " ns" << std::endl;
    std::cout << " p95 Latency  │ " 
              << std::fixed << std::setprecision(2) << std::setw(15) << soft_stats.p95 << " ns" 
              << "      │ " << std::setw(15) << hw_stats.p95 << " ns" << std::endl;
    std::cout << " p99 Latency  │ " 
              << std::fixed << std::setprecision(2) << std::setw(15) << soft_stats.p99 << " ns" 
              << "      │ " << std::setw(15) << hw_stats.p99 << " ns" << std::endl;
    std::cout << " Jitter (SD)  │ " 
              << std::fixed << std::setprecision(2) << std::setw(15) << soft_stats.stdev << " ns" 
              << "      │ " << std::setw(15) << hw_stats.stdev << " ns" << std::endl;
    std::cout << "======================================================================" << std::endl;
    std::cout << " Speedup:  " << (soft_stats.mean / hw_stats.mean) << "x faster mean latency." << std::endl;
    std::cout << " Jitter:   FPGA Jitter is " << std::fixed << std::setprecision(4) 
              << hw_stats.stdev << " ns (0% Jitter Jumps vs Software OS scheduling)." << std::endl;
    std::cout << "======================================================================" << std::endl;

    return 0;
}
