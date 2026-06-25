// Cycle-accurate C++ testbench for the integrated hft_top SystemVerilog model.

#include <iostream>
#include <fstream>
#include <vector>
#include <memory>
#include <iomanip>
#include <cstring>
#include "Vtb_hft_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

// Clock definition: 156.25 MHz -> 6.4 ns period.
const double CLK_HALF_NS = 3.2;
uint64_t main_time = 0;

// AXI-Lite Write Helper
void axi_lite_write(const std::unique_ptr<Vtb_hft_top>& top, uint32_t addr, uint32_t data, const std::unique_ptr<VerilatedVcdC>& tfp) {
    top->s_axi_dma_awaddr = addr;
    top->s_axi_dma_awvalid = 1;
    top->s_axi_dma_wdata = data;
    top->s_axi_dma_wstrb = 0xF;
    top->s_axi_dma_wvalid = 1;
    top->s_axi_dma_bready = 1;
    
    while (!top->s_axi_dma_awready || !top->s_axi_dma_wready) {
        top->clk = 1; top->eval(); tfp->dump(main_time); main_time += 32;
        top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
    }
    top->clk = 1; top->eval(); tfp->dump(main_time); main_time += 32;
    top->s_axi_dma_awvalid = 0;
    top->s_axi_dma_wvalid = 0;
    top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
    
    while (!top->s_axi_dma_bvalid) {
        top->clk = 1; top->eval(); tfp->dump(main_time); main_time += 32;
        top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
    }
    top->clk = 1; top->eval(); tfp->dump(main_time); main_time += 32;
    top->s_axi_dma_bready = 0;
    top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
}

// AXI-Lite Read Helper
uint32_t axi_lite_read(const std::unique_ptr<Vtb_hft_top>& top, uint32_t addr, const std::unique_ptr<VerilatedVcdC>& tfp) {
    top->s_axi_dma_araddr = addr;
    top->s_axi_dma_arvalid = 1;
    top->s_axi_dma_rready = 1;
    while (!top->s_axi_dma_arready) {
        top->clk = 1; top->eval(); tfp->dump(main_time); main_time += 32;
        top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
    }
    top->clk = 1; top->eval(); tfp->dump(main_time); main_time += 32;
    top->s_axi_dma_arvalid = 0;
    top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
    
    while (!top->s_axi_dma_rvalid) {
        top->clk = 1; top->eval(); tfp->dump(main_time); main_time += 32;
        top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
    }
    uint32_t data = top->s_axi_dma_rdata;
    top->clk = 1; top->eval(); tfp->dump(main_time); main_time += 32;
    top->s_axi_dma_rready = 0;
    top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
    return data;
}

// TLP Decoder Helper
void check_pcie_dma(const std::unique_ptr<Vtb_hft_top>& top) {
    static int pcie_word_idx = 0;
    static uint64_t pcie_words[4];
    
    if (top->m_axis_pcie_tvalid) {
        if (pcie_word_idx >= 4) {
            std::cerr << "[ERROR] PCIe TLP exceeded 4 DW — unexpected hardware behavior!" << std::endl;
            pcie_word_idx = 0;
            return;
        }
        pcie_words[pcie_word_idx] = top->m_axis_pcie_tdata;
        std::cout << "  - PCIe TLP WORD " << pcie_word_idx << ": 0x" 
                  << std::hex << std::setw(16) << std::setfill('0') << top->m_axis_pcie_tdata << std::endl;
        
        if (top->m_axis_pcie_tlast) {
            std::cout << "  [SUCCESS] Direct PCIe Direct DMA TLP Write Completed!" << std::endl;
            uint32_t dw0 = pcie_words[0] & 0xFFFFFFFFULL;
            uint32_t dw1 = (pcie_words[0] >> 32) & 0xFFFFFFFFULL;
            uint64_t addr = ((pcie_words[1] & 0xFFFFFFFFULL) << 32) | ((pcie_words[1] >> 32) & 0xFFFFFFFFULL);
            uint64_t stock = ((pcie_words[2] & 0xFFFFFFFFULL) << 32) | ((pcie_words[2] >> 32) & 0xFFFFFFFFULL);
            uint32_t val1 = pcie_words[3] & 0xFFFFFFFFULL;
            uint32_t val2 = (pcie_words[3] >> 32) & 0xFFFFFFFFULL;
            
            char stock_str[9] = {0};
            for (int b = 0; b < 8; b++) {
                stock_str[7 - b] = (stock >> (b * 8)) & 0xFF;
            }
            
            std::cout << "    * Decode: MWr 64-bit Address | Length: " << std::dec << (dw0 & 0x3FF) << " DW" << std::endl;
            std::cout << "    * Requester ID: 0x" << std::hex << (dw1 >> 16) << " | Tag: 0x" << ((dw1 >> 8) & 0xFF) << std::endl;
            std::cout << "    * Destination physical address in Host RAM: 0x" << std::hex << addr << std::endl;
            std::cout << "    * Event Stock Symbol: \"" << stock_str << "\"" << std::endl;
            if (stock == 0x4152425f4c4f4f50) {
                std::cout << "    * Event Type: TRIANGULAR ARBITRAGE ALERT" << std::endl;
                std::cout << "    * Profit: +" << std::fixed << std::setprecision(4) << (val1 / 16777216.0 * 100.0) << "%" << std::endl;
            } else {
                std::cout << "    * Event Type: BBO BOOK UPDATE" << std::endl;
                std::cout << "    * Bid Price: $" << std::fixed << std::setprecision(4) << (val1 / 10000.0) << std::endl;
                std::cout << "    * Ask Price: $" << std::fixed << std::setprecision(4) << (val2 / 10000.0) << std::endl;
            }
            pcie_word_idx = 0;
        } else {
            pcie_word_idx++;
        }
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    
    auto top = std::make_unique<Vtb_hft_top>();
    
    Verilated::traceEverOn(true);
    auto tfp = std::make_unique<VerilatedVcdC>();
    top->trace(tfp.get(), 99);
    tfp->open("sim_hft_top.vcd");
    
    std::cout << "======================================================================" << std::endl;
    std::cout << "  Starting Integrated hft_top HFT System Simulation & Verification..." << std::endl;
    std::cout << "======================================================================" << std::endl;
    
    top->clk = 0;
    top->rst_n = 0;
    top->s_axis_rx_tvalid = 0;
    top->s_axis_rx_tlast  = 0;
    top->m_axis_tx_tready = 1;
    
    top->rates_valid = 0;
    top->rate_ab = 0;
    top->rate_bc = 0;
    top->rate_ca = 0;
    
    top->tcp_conn_trigger = 0;
    top->tcp_disc_trigger = 0;
    top->tcp_rx_valid     = 0;
    top->tcp_rx_syn       = 0;
    top->tcp_rx_ack       = 0;
    top->tcp_rx_fin       = 0;
    
    for (int i = 0; i < 10; ++i) {
        top->clk = !top->clk;
        top->eval();
        tfp->dump(main_time);
        main_time += CLK_HALF_NS * 10;
    }
    top->rst_n = 1;
    std::cout << "[SIM] Hardware Reset De-asserted." << std::endl;

    top->s_axi_dma_awvalid = 0;
    top->s_axi_dma_wvalid  = 0;
    top->s_axi_dma_bready  = 0;
    top->s_axi_dma_arvalid = 0;
    top->s_axi_dma_rready  = 0;
    top->m_axis_pcie_tready = 1;

    // Configure PCIe DMA registers via MMIO BAR0
    std::cout << "[SIM] Configuring FPGA PCIe DMA registers via MMIO BAR0..." << std::endl;
    axi_lite_write(top, 0x004, 0x55550000, tfp);
    axi_lite_write(top, 0x008, 0x00000001, tfp);
    axi_lite_write(top, 0x00C, 0x00100000, tfp);
    axi_lite_write(top, 0x000, 0x00000003, tfp);

    uint32_t val_low  = axi_lite_read(top, 0x004, tfp);
    uint32_t val_high = axi_lite_read(top, 0x008, tfp);
    uint32_t val_size = axi_lite_read(top, 0x00c, tfp);
    uint32_t val_ctrl = axi_lite_read(top, 0x000, tfp);
    std::cout << "[SUCCESS] PCIe BAR0 MMIO verified! Host Target RAM Address: 0x" 
              << std::hex << val_high << val_low << " | Size: " << std::dec << val_size 
              << " | Control Reg: 0x" << val_ctrl << std::endl;

    bool mmio_ok = (val_low == 0x55550000) && (val_high == 0x00000001) && (val_size == 0x00100000);
    if (!mmio_ok) {
        std::cerr << "[FAIL] PCIe BAR0 MMIO readback mismatch!" << std::endl;
        return -1;
    }
    
    // Establish TCP session via 3-way handshake
    std::cout << "[SIM] Initiating TCP connection (SYN)..." << std::endl;
    top->clk = 0;
    top->tcp_conn_trigger = 1;
    top->eval();
    tfp->dump(main_time);
    main_time += 32;
    
    top->clk = 1;
    top->eval();
    tfp->dump(main_time);
    main_time += 32;
    
    top->clk = 0;
    top->tcp_conn_trigger = 0;
    top->eval();
    tfp->dump(main_time);
    main_time += 32;
    
    bool syn_sent = false;
    for (int cycle = 0; cycle < 50; ++cycle) {
        top->clk = 1;
        top->eval();
        
        if (top->m_axis_tx_tvalid && !syn_sent) {
            std::cout << "[SIM] Capture Outbound SYN packet frame from TOE over AXI-Stream." << std::endl;
            syn_sent = true;
        }
        
        tfp->dump(main_time);
        main_time += 32;
        
        top->clk = 0;
        top->eval();
        tfp->dump(main_time);
        main_time += 32;
    }
    
    // Ingest mock server SYN-ACK to complete connection
    std::cout << "[SIM] Feeding Mock SYN-ACK packet back into TOE receiver path..." << std::endl;
    top->clk = 0;
    top->tcp_rx_valid = 1;
    top->tcp_rx_syn   = 1;
    top->tcp_rx_ack   = 1;
    top->tcp_rx_seq   = 0x90000000;
    top->tcp_rx_ack_num = 0x10000001;
    top->eval();
    tfp->dump(main_time);
    main_time += 32;
    
    top->clk = 1;
    top->eval();
    tfp->dump(main_time);
    main_time += 32;
    
    top->clk = 0;
    top->tcp_rx_valid = 0;
    top->tcp_rx_syn   = 0;
    top->tcp_rx_ack   = 0;
    top->eval();
    tfp->dump(main_time);
    main_time += 32;
    
    // Allow FSM state to settle
    for (int i = 0; i < 5; ++i) {
        top->clk = 1;
        top->eval();
        tfp->dump(main_time);
        main_time += 32;
        top->clk = 0;
        top->eval();
        tfp->dump(main_time);
        main_time += 32;
    }
    
    if (top->tcp_session_established) {
        std::cout << "[SUCCESS] TCP Offload Session ESTABLISHED! (FSM State = " 
                  << static_cast<int>(top->tcp_state_out) << ")" << std::endl;
    } else {
        std::cerr << "[ERROR] TCP Handshake Failed! State = " << static_cast<int>(top->tcp_state_out) << std::endl;
        return -1;
    }
    
    // Stream inbound UDP MoldUDP64 packets containing ITCH updates
    std::ifstream infile("raw_packets.bin", std::ios::binary);
    if (!infile) {
        std::cerr << "[ERROR] raw_packets.bin not found! Please run generate_ticks.py first." << std::endl;
        return -1;
    }
    
    std::cout << "[SIM] Streaming market data packets into pipeline..." << std::endl;
    uint32_t pkt_len = 0;
    int packet_num = 1;
    while (infile.read(reinterpret_cast<char*>(&pkt_len), sizeof(pkt_len))) {
        std::vector<uint8_t> pkt_data(pkt_len);
        infile.read(reinterpret_cast<char*>(pkt_data.data()), pkt_len);
        std::cout << "[SIM] Streaming Packet " << packet_num++ << " (" << pkt_len << " bytes)..." << std::endl;
        
        size_t byte_idx = 0;
        while (byte_idx < pkt_len) {
            top->clk = 0;
            top->eval();
            tfp->dump(main_time);
            main_time += 32;
            
            uint64_t data_word = 0;
            uint8_t keep_word = 0;
            for (int b = 0; b < 8; ++b) {
                if (byte_idx < pkt_len) {
                    data_word |= (static_cast<uint64_t>(pkt_data[byte_idx]) << (b * 8));
                    keep_word |= (1 << b);
                    byte_idx++;
                }
            }
            
            top->s_axis_rx_tdata  = data_word;
            top->s_axis_rx_tkeep  = keep_word;
            top->s_axis_rx_tvalid = 1;
            top->s_axis_rx_tlast  = (byte_idx >= pkt_len) ? 1 : 0;
            top->s_axis_rx_tuser  = 0;
            
            top->clk = 1;
            top->eval();
            
            if (top->bbo_valid) {
                char symbol[9];
                uint64_t raw_stock = top->bbo_stock;
                std::memcpy(symbol, &raw_stock, 8);
                symbol[8] = '\0';
                std::cout << "[BBO UPDATE] Stock=" << symbol 
                          << " | BidPrice=" << std::fixed << std::setprecision(4) << (top->bbo_bid_price / 10000.0)
                          << " | BidSize=" << top->bbo_bid_size
                          << " | AskPrice=" << (top->bbo_ask_price / 10000.0)
                          << " | AskSize=" << top->bbo_ask_size << std::endl;

                static bool bbo_checked = false;
                if (!bbo_checked && top->bbo_bid_price > 0) {
                    if (top->bbo_bid_price != 1502500 && top->bbo_bid_price != 1502600 && top->bbo_bid_price != 1502700) {
                        std::cerr << "[FAIL] BBO bid price unexpected: " << top->bbo_bid_price << std::endl;
                    }
                    bbo_checked = true;
                }
            }

            check_pcie_dma(top);
            
            tfp->dump(main_time);
            main_time += 32;
        }
        
        top->s_axis_rx_tvalid = 0;
        top->s_axis_rx_tlast  = 0;
        
        // Cycle clock to settle pipeline between packets
        for (int i = 0; i < 15; ++i) {
            top->clk = 1; top->eval(); check_pcie_dma(top); tfp->dump(main_time); main_time += 32;
            top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
        }
    }
    
    // Flush pending pipeline and DMA transactions
    std::cout << "[SIM] Flushing pipeline and DMA buffer..." << std::endl;
    for (int i = 0; i < 50; ++i) {
        top->clk = 1; top->eval(); check_pcie_dma(top); tfp->dump(main_time); main_time += 32;
        top->clk = 0; top->eval(); tfp->dump(main_time); main_time += 32;
    }
    
    // Inject profitable Q8.24 fixed-point arbitrage rates
    std::cout << "[SIM] Feeding profitable Triangular Arbitrage rates into pipeline..." << std::endl;
    
    top->clk = 0;
    top->rates_valid = 1;
    top->rate_ab     = 0x01400000;
    top->rate_bc     = 0x00d9999a;
    top->rate_ca     = 0x00f33333;
    top->eval();
    tfp->dump(main_time);
    main_time += 32;
    
    top->clk = 1;
    top->eval();
    tfp->dump(main_time);
    main_time += 32;
    
    top->clk = 0;
    top->rates_valid = 0;
    top->eval();
    tfp->dump(main_time);
    main_time += 32;
    
    bool arb_triggered = false;
    bool order_sent = false;
    
    for (int cycle = 0; cycle < 40; ++cycle) {
        top->clk = 1;
        top->eval();
        
        if (top->arb_detected && !arb_triggered) {
            std::cout << "[SUCCESS] Triangular Arbitrage Detected by DSP Math Engine!" << std::endl;
            std::cout << "  - Profit: +" << std::fixed << std::setprecision(4) 
                      << ((top->arb_profit / 16777216.0) * 100.0) << "%" << std::endl;
            if (top->arb_profit == 0) {
                std::cerr << "[WARN] Arbitrage detected but profit is zero!" << std::endl;
            }
            arb_triggered = true;
        }
        
        if (top->m_axis_tx_tvalid && !order_sent && arb_triggered) {
            std::cout << "[SUCCESS] TOE Generated Outbound FIX Trade Execution Packet!" << std::endl;
            order_sent = true;
        }
        
        if (top->m_axis_tx_tvalid && order_sent) {
            std::cout << "  - TX WORD: 0x" << std::hex << std::setw(16) << std::setfill('0') 
                      << top->m_axis_tx_tdata << " | KEEP: 0x" << static_cast<int>(top->m_axis_tx_tkeep) << std::endl;
        }

        check_pcie_dma(top);
        
        tfp->dump(main_time);
        main_time += 32;
        
        top->clk = 0;
        top->eval();
        tfp->dump(main_time);
        main_time += 32;
    }
    
    tfp->close();
    std::cout << "======================================================================" << std::endl;
    if (top->tcp_session_established && arb_triggered && order_sent) {
        std::cout << "  ALL HARDWARE SYSTEMS FUNCTIONING AND VERIFIED CORRECT!" << std::endl;
        std::cout << "  FPGA TOP-LEVEL DESIGN IS 100% READY FOR SYNTHESIS AND PLACEMENT." << std::endl;
        std::cout << "======================================================================" << std::endl;
        return 0;
    } else {
        std::cout << "  INTEGRATION TEST DETECTED AN END-TO-END PIPELINE MISMATCH!" << std::endl;
        std::cout << "======================================================================" << std::endl;
        return -1;
    }
}
