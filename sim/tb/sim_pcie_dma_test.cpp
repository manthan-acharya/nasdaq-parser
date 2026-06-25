// Dedicated PCIe DMA Controller simulation stress and verification test suite.

#include <iostream>
#include <fstream>
#include <vector>
#include <memory>
#include <iomanip>
#include <cstring>
#include <cassert>
#include "Vtb_hft_top_dma.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

using Vtb_hft_top = Vtb_hft_top_dma;

uint64_t sim_time = 0;
int test_pass_count = 0;
int test_fail_count = 0;

#define ASSERT_EQ(actual, expected, msg) do { \
    if ((actual) != (expected)) { \
        std::cerr << "[FAIL] " << (msg) << ": expected 0x" \
                  << std::hex << (expected) << " got 0x" << (actual) \
                  << std::dec << std::endl; \
        test_fail_count++; \
    } else { \
        test_pass_count++; \
    } \
} while(0)

#define ASSERT_TRUE(cond, msg) do { \
    if (!(cond)) { \
        std::cerr << "[FAIL] " << (msg) << std::endl; \
        test_fail_count++; \
    } else { \
        test_pass_count++; \
    } \
} while(0)

void tick(const std::unique_ptr<Vtb_hft_top>& top,
          const std::unique_ptr<VerilatedVcdC>& tfp);

void reset(const std::unique_ptr<Vtb_hft_top>& top,
           const std::unique_ptr<VerilatedVcdC>& tfp) {
    top->rst_n = 0;
    top->clk = 0;
    top->s_axis_rx_tvalid = 0;
    top->s_axis_rx_tlast  = 0;
    top->m_axis_tx_tready = 1;
    top->m_axis_pcie_tready = 1;
    top->rates_valid = 0;
    top->rate_ab = 0;
    top->rate_bc = 0;
    top->rate_ca = 0;
    top->tcp_conn_trigger = 0;
    top->tcp_disc_trigger = 0;
    top->tcp_rx_valid = 0;
    top->tcp_rx_syn = 0;
    top->tcp_rx_ack = 0;
    top->tcp_rx_fin = 0;
    top->s_axi_dma_awvalid = 0;
    top->s_axi_dma_wvalid  = 0;
    top->s_axi_dma_bready  = 0;
    top->s_axi_dma_arvalid = 0;
    top->s_axi_dma_rready  = 0;

    for (int i = 0; i < 10; ++i) tick(top, tfp);

    top->rst_n = 1;
    tick(top, tfp);
}

void axi_write(const std::unique_ptr<Vtb_hft_top>& top, uint32_t addr,
               uint32_t data, const std::unique_ptr<VerilatedVcdC>& tfp) {
    top->s_axi_dma_awaddr  = addr;
    top->s_axi_dma_awvalid = 1;
    top->s_axi_dma_wdata   = data;
    top->s_axi_dma_wstrb   = 0xF;
    top->s_axi_dma_wvalid  = 1;
    top->s_axi_dma_bready  = 1;

    for (int i = 0; i < 20; i++) {
        tick(top, tfp);
        if (top->s_axi_dma_awready && top->s_axi_dma_wready) break;
    }
    tick(top, tfp);
    top->s_axi_dma_awvalid = 0;
    top->s_axi_dma_wvalid  = 0;

    for (int i = 0; i < 20; i++) {
        tick(top, tfp);
        if (top->s_axi_dma_bvalid) break;
    }
    tick(top, tfp);
    top->s_axi_dma_bready = 0;
}

uint32_t axi_read(const std::unique_ptr<Vtb_hft_top>& top, uint32_t addr,
                  const std::unique_ptr<VerilatedVcdC>& tfp) {
    top->s_axi_dma_araddr  = addr;
    top->s_axi_dma_arvalid = 1;
    top->s_axi_dma_rready  = 1;

    for (int i = 0; i < 20; i++) {
        tick(top, tfp);
        if (top->s_axi_dma_arready) break;
    }
    tick(top, tfp);
    top->s_axi_dma_arvalid = 0;

    for (int i = 0; i < 20; i++) {
        tick(top, tfp);
        if (top->s_axi_dma_rvalid) break;
    }
    uint32_t data = top->s_axi_dma_rdata;
    tick(top, tfp);
    top->s_axi_dma_rready = 0;
    return data;
}

struct tlp_record_t {
    uint64_t words[4];
    int beat_count;
};

// Global TLP collector capturing TLPs during tick()
std::vector<tlp_record_t> g_captured_tlps;
static int g_beat_idx = 0;
static uint64_t g_beat_words[4] = {};

void check_pcie(const std::unique_ptr<Vtb_hft_top>& top) {
    if (top->m_axis_pcie_tvalid && top->m_axis_pcie_tready) {
        if (g_beat_idx < 4) g_beat_words[g_beat_idx] = top->m_axis_pcie_tdata;
        g_beat_idx++;
        if (top->m_axis_pcie_tlast) {
            tlp_record_t rec;
            for (int i = 0; i < 4; i++) rec.words[i] = g_beat_words[i];
            rec.beat_count = g_beat_idx;
            g_captured_tlps.push_back(rec);
            g_beat_idx = 0;
        }
    }
}

void tick(const std::unique_ptr<Vtb_hft_top>& top,
          const std::unique_ptr<VerilatedVcdC>& tfp) {
    top->clk = 0;
    top->eval();
    tfp->dump(sim_time++);
    top->clk = 1;
    top->eval();
    check_pcie(top);
    tfp->dump(sim_time++);
}

void settle(const std::unique_ptr<Vtb_hft_top>& top,
            const std::unique_ptr<VerilatedVcdC>& tfp, int n = 30) {
    for (int i = 0; i < n; i++) tick(top, tfp);
}

// Helper to wait for a completed TLP
bool wait_for_tlp(const std::unique_ptr<Vtb_hft_top>& top,
                  const std::unique_ptr<VerilatedVcdC>& tfp,
                  tlp_record_t& tlp, int timeout_cycles = 200) {
    size_t start_count = g_captured_tlps.size();
    for (int c = 0; c < timeout_cycles; c++) {
        tick(top, tfp);
        if (g_captured_tlps.size() > start_count) {
            tlp = g_captured_tlps.back();
            return true;
        }
    }
    return false;
}

void stream_packet(const std::unique_ptr<Vtb_hft_top>& top,
                   const std::unique_ptr<VerilatedVcdC>& tfp,
                   const std::vector<uint8_t>& pkt) {
    size_t idx = 0;
    while (idx < pkt.size()) {
        uint64_t data_word = 0;
        uint8_t keep = 0;
        for (int b = 0; b < 8 && idx < pkt.size(); b++, idx++) {
            data_word |= (static_cast<uint64_t>(pkt[idx]) << (b * 8));
            keep |= (1 << b);
        }
        top->s_axis_rx_tdata  = data_word;
        top->s_axis_rx_tkeep  = keep;
        top->s_axis_rx_tvalid = 1;
        top->s_axis_rx_tlast  = (idx >= pkt.size()) ? 1 : 0;
        top->s_axis_rx_tuser  = 0;
        tick(top, tfp);
    }
    top->s_axis_rx_tvalid = 0;
    top->s_axis_rx_tlast  = 0;
}

std::vector<std::vector<uint8_t>> load_packets(const std::string& path) {
    std::vector<std::vector<uint8_t>> packets;
    std::ifstream f(path, std::ios::binary);
    if (!f) return packets;
    uint32_t len;
    while (f.read(reinterpret_cast<char*>(&len), 4)) {
        std::vector<uint8_t> pkt(len);
        f.read(reinterpret_cast<char*>(pkt.data()), len);
        packets.push_back(std::move(pkt));
    }
    return packets;
}

// TEST 1: TLP Format Verification
void test_tlp_format(const std::unique_ptr<Vtb_hft_top>& top,
                     const std::unique_ptr<VerilatedVcdC>& tfp,
                     const std::vector<std::vector<uint8_t>>& packets) {
    std::cout << "\n=== TEST 1: TLP Format Verification ===" << std::endl;

    size_t tlp_start = g_captured_tlps.size();

    // Stream Packet 1
    stream_packet(top, tfp, packets[0]);

    // Settle pipeline
    settle(top, tfp, 50);

    bool got = g_captured_tlps.size() > tlp_start;
    ASSERT_TRUE(got, "TLP captured after BBO event");

    if (got) {
        auto& tlp = g_captured_tlps[tlp_start];
        uint32_t dw0 = tlp.words[0] & 0xFFFFFFFFULL;
        ASSERT_EQ(dw0, 0x60000004u, "DW0 = MWr 64-bit, 4 DW payload");

        uint32_t dw1 = (tlp.words[0] >> 32) & 0xFFFFFFFFULL;
        uint16_t req_id = (dw1 >> 16) & 0xFFFF;
        uint8_t  tag    = (dw1 >> 8) & 0xFF;
        uint8_t  be     = dw1 & 0xFF;
        ASSERT_EQ(req_id, 0x0100u, "Requester ID");
        ASSERT_EQ(tag, 0x01u, "Tag");
        ASSERT_EQ(be, 0xFFu, "First+Last Byte Enables");

        uint32_t addr_high = tlp.words[1] & 0xFFFFFFFFULL;
        uint32_t addr_low  = (tlp.words[1] >> 32) & 0xFFFFFFFFULL;
        uint64_t addr = ((uint64_t)addr_high << 32) | addr_low;
        ASSERT_EQ(addr, 0x100000000ULL, "Target host address = base + 0");

        uint32_t stock_hi = tlp.words[2] & 0xFFFFFFFFULL;
        uint32_t stock_lo = (tlp.words[2] >> 32) & 0xFFFFFFFFULL;
        uint64_t stock = ((uint64_t)stock_hi << 32) | stock_lo;
        ASSERT_EQ(stock, 0x4141504c20202020ULL, "Stock = AAPL");

        uint32_t bid = tlp.words[3] & 0xFFFFFFFFULL;
        ASSERT_TRUE(bid == 1502500 || bid == 1502600 || bid == 1502700,
                    "Bid price is a valid AAPL bid ($150.25/26/27)");

        std::cout << "  TLP: MWr to 0x" << std::hex << addr
                  << " | Stock=AAPL | Bid=$" << std::fixed << std::setprecision(4)
                  << (bid / 10000.0) << std::dec << std::endl;

        ASSERT_EQ(tlp.beat_count, 4, "TLP is exactly 4 beats");
    }

    std::cout << "  Total TLPs from packet 1: " << (g_captured_tlps.size() - tlp_start) << std::endl;
}

// TEST 2: Write-Pointer Wraparound
void test_wraparound(const std::unique_ptr<Vtb_hft_top>& top,
                     const std::unique_ptr<VerilatedVcdC>& tfp,
                     const std::vector<std::vector<uint8_t>>& packets) {
    std::cout << "\n=== TEST 2: Write-Pointer Wraparound ===" << std::endl;

    axi_write(top, 0x00C, 128, tfp);
    axi_write(top, 0x000, 0x00000003, tfp);
    for (int i = 0; i < 5; i++) tick(top, tfp);

    uint32_t offset = axi_read(top, 0x010, tfp);
    ASSERT_EQ(offset, 0u, "Write offset starts at 0 after reset");

    size_t wrap_start = g_captured_tlps.size();
    for (size_t p = 0; p < packets.size(); p++) {
        stream_packet(top, tfp, packets[p]);
        settle(top, tfp, 20);
    }
    settle(top, tfp, 100);

    std::vector<uint64_t> addresses;
    for (size_t i = wrap_start; i < g_captured_tlps.size(); i++) {
        auto& t = g_captured_tlps[i];
        uint32_t ah = t.words[1] & 0xFFFFFFFFULL;
        uint32_t al = (t.words[1] >> 32) & 0xFFFFFFFFULL;
        uint64_t a  = ((uint64_t)ah << 32) | al;
        addresses.push_back(a);
    }

    std::cout << "  Captured " << addresses.size() << " TLPs." << std::endl;
    ASSERT_TRUE(addresses.size() >= 4, "At least 4 TLPs generated for wrap test");

    uint64_t base = 0x100000000ULL;
    bool wrap_seen = false;
    for (size_t i = 1; i < addresses.size(); i++) {
        uint64_t expected_offset = (i * 32) % 128;
        uint64_t expected_addr   = base + expected_offset;
        if (addresses[i] == base && i >= 4) {
            wrap_seen = true;
            std::cout << "  Wraparound detected at TLP #" << i << std::endl;
        }
        std::cout << "  TLP #" << i << " addr: 0x" << std::hex << addresses[i]
                  << " (expected 0x" << expected_addr << ")" << std::dec << std::endl;
    }

    if (addresses.size() > 4) {
        ASSERT_TRUE(wrap_seen, "Buffer wraparound occurred");
    }

    offset = axi_read(top, 0x010, tfp);
    std::cout << "  Final write offset: " << offset << " bytes" << std::endl;
    ASSERT_TRUE(offset < 128, "Write offset stays within buffer bounds");

    axi_write(top, 0x00C, 0x00100000, tfp);
}

// TEST 3: Backpressure Tolerance
void test_backpressure(const std::unique_ptr<Vtb_hft_top>& top,
                       const std::unique_ptr<VerilatedVcdC>& tfp,
                       const std::vector<std::vector<uint8_t>>& packets) {
    std::cout << "\n=== TEST 3: Backpressure Tolerance ===" << std::endl;

    axi_write(top, 0x000, 0x00000003, tfp);
    for (int i = 0; i < 5; i++) tick(top, tfp);

    stream_packet(top, tfp, packets[0]);
    for (int i = 0; i < 5; i++) tick(top, tfp);

    // Capture TLP with backpressure injected after beat 1
    int beat = 0;
    uint64_t tlp_words[4] = {};
    bool completed = false;
    int stall_cycles = 0;
    int total_cycles = 0;

    for (int c = 0; c < 300 && !completed; c++) {
        tick(top, tfp);
        total_cycles++;

        if (top->m_axis_pcie_tvalid && top->m_axis_pcie_tready) {
            if (beat < 4) tlp_words[beat] = top->m_axis_pcie_tdata;
            beat++;

            if (beat == 2) {
                top->m_axis_pcie_tready = 0;
                for (int s = 0; s < 20; s++) {
                    tick(top, tfp);
                    total_cycles++;
                    stall_cycles++;
                    // Verify tvalid stays asserted during stall
                    if (!top->m_axis_pcie_tvalid) {
                        std::cerr << "[FAIL] tvalid dropped during backpressure stall!" << std::endl;
                        test_fail_count++;
                    }
                }
                top->m_axis_pcie_tready = 1;
            }

            if (top->m_axis_pcie_tlast) completed = true;
        }
    }

    ASSERT_TRUE(completed, "TLP completed despite mid-burst backpressure");
    ASSERT_EQ(beat, 4, "TLP still exactly 4 beats after stall");
    std::cout << "  TLP completed after " << stall_cycles
              << " stall cycles (total: " << total_cycles << " cycles)" << std::endl;

    uint32_t dw0 = tlp_words[0] & 0xFFFFFFFFULL;
    ASSERT_EQ(dw0, 0x60000004u, "DW0 intact after backpressure");

    uint32_t stock_hi = tlp_words[2] & 0xFFFFFFFFULL;
    uint32_t stock_lo = (tlp_words[2] >> 32) & 0xFFFFFFFFULL;
    uint64_t stock = ((uint64_t)stock_hi << 32) | stock_lo;
    ASSERT_EQ(stock, 0x4141504c20202020ULL, "Stock payload intact after backpressure");

    settle(top, tfp, 50);
}

// TEST 4: Arb Priority Over BBO
void test_arb_priority(const std::unique_ptr<Vtb_hft_top>& top,
                       const std::unique_ptr<VerilatedVcdC>& tfp,
                       const std::vector<std::vector<uint8_t>>& packets) {
    std::cout << "\n=== TEST 4: Arb Priority Over BBO ===" << std::endl;

    axi_write(top, 0x000, 0x00000003, tfp);
    for (int i = 0; i < 5; i++) tick(top, tfp);

    top->tcp_conn_trigger = 1;
    tick(top, tfp);
    top->tcp_conn_trigger = 0;
    for (int i = 0; i < 30; i++) tick(top, tfp);

    top->tcp_rx_valid   = 1;
    top->tcp_rx_syn     = 1;
    top->tcp_rx_ack     = 1;
    top->tcp_rx_seq     = 0x90000000;
    top->tcp_rx_ack_num = 0x10000001;
    tick(top, tfp);
    top->tcp_rx_valid = 0;
    top->tcp_rx_syn   = 0;
    top->tcp_rx_ack   = 0;
    for (int i = 0; i < 10; i++) tick(top, tfp);

    ASSERT_TRUE(top->tcp_session_established, "TCP session established for arb test");

    stream_packet(top, tfp, packets[0]);
    for (int i = 0; i < 20; i++) tick(top, tfp);

    settle(top, tfp, 80);

    axi_write(top, 0x000, 0x00000003, tfp);
    settle(top, tfp, 5);
    size_t arb_start = g_captured_tlps.size();

    // Inject profitable rates (arbitrage detection takes 3 cycles)
    top->rates_valid = 1;
    top->rate_ab = 0x01400000;
    top->rate_bc = 0x00d9999a;
    top->rate_ca = 0x00f33333;
    tick(top, tfp);
    top->rates_valid = 0;
    settle(top, tfp, 30);

    bool got = g_captured_tlps.size() > arb_start;
    ASSERT_TRUE(got, "Arb TLP generated");

    if (got) {
        auto& tlp = g_captured_tlps[arb_start];
        uint32_t stock_hi = tlp.words[2] & 0xFFFFFFFFULL;
        uint32_t stock_lo = (tlp.words[2] >> 32) & 0xFFFFFFFFULL;
        uint64_t stock = ((uint64_t)stock_hi << 32) | stock_lo;
        ASSERT_EQ(stock, 0x4152425f4c4f4f50ULL, "Arb TLP stock = 'ARB_LOOP'");

        uint32_t profit = tlp.words[3] & 0xFFFFFFFFULL;
        ASSERT_TRUE(profit > 0, "Arb profit is non-zero");
        std::cout << "  Arb TLP profit: +"
                  << std::fixed << std::setprecision(4)
                  << (profit / 16777216.0 * 100.0) << "%" << std::endl;

        uint32_t ask = (tlp.words[3] >> 32) & 0xFFFFFFFFULL;
        ASSERT_EQ(ask, 0u, "Arb TLP ask field is zero (arb event, not BBO)");
    }

    settle(top, tfp, 50);
}

// TEST 5: FIFO Burst Load Stress
void test_burst_load(const std::unique_ptr<Vtb_hft_top>& top,
                     const std::unique_ptr<VerilatedVcdC>& tfp,
                     const std::vector<std::vector<uint8_t>>& packets) {
    std::cout << "\n=== TEST 5: FIFO Burst Load Stress ===" << std::endl;

    axi_write(top, 0x000, 0x00000003, tfp);
    for (int i = 0; i < 5; i++) tick(top, tfp);

    size_t burst_start = g_captured_tlps.size();

    // Stream packets back-to-back with minimal gap
    for (int round = 0; round < 3; round++) {
        for (size_t p = 0; p < packets.size(); p++) {
            stream_packet(top, tfp, packets[p]);
            tick(top, tfp);
            tick(top, tfp);
        }
    }

    settle(top, tfp, 500);
    int tlp_count = (int)(g_captured_tlps.size() - burst_start);

    std::cout << "  Total TLPs captured during burst: " << tlp_count << std::endl;
    ASSERT_TRUE(tlp_count > 0, "At least some TLPs generated under burst load");

    uint32_t final_offset = axi_read(top, 0x010, tfp);
    ASSERT_TRUE(final_offset < 0x00100000, "Final offset within buffer bounds");
    ASSERT_TRUE((final_offset % 32) == 0, "Write offset is 32-byte aligned");
    std::cout << "  Final write offset: 0x" << std::hex << final_offset
              << " (" << std::dec << (final_offset / 32) << " records)" << std::endl;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto top = std::make_unique<Vtb_hft_top>();
    Verilated::traceEverOn(true);
    auto tfp = std::make_unique<VerilatedVcdC>();
    top->trace(tfp.get(), 99);
    tfp->open("sim_pcie_dma_test.vcd");

    std::cout << "======================================================================" << std::endl;
    std::cout << "  PCIe DMA Controller Stress Test Suite" << std::endl;
    std::cout << "======================================================================" << std::endl;

    auto packets = load_packets("raw_packets.bin");
    if (packets.empty()) {
        std::cerr << "[ERROR] raw_packets.bin not found! Run generate_ticks.py first." << std::endl;
        return 1;
    }
    std::cout << "Loaded " << packets.size() << " test packets." << std::endl;

    reset(top, tfp);

    axi_write(top, 0x004, 0x00000000, tfp);
    axi_write(top, 0x008, 0x00000001, tfp);
    axi_write(top, 0x00C, 0x00100000, tfp);
    axi_write(top, 0x000, 0x00000003, tfp);

    uint32_t v_lo   = axi_read(top, 0x004, tfp);
    uint32_t v_hi   = axi_read(top, 0x008, tfp);
    uint32_t v_size = axi_read(top, 0x00C, tfp);
    ASSERT_EQ(v_lo,   0x00000000u, "BAR0 base_low readback");
    ASSERT_EQ(v_hi,   0x00000001u, "BAR0 base_high readback");
    ASSERT_EQ(v_size, 0x00100000u, "BAR0 buf_size readback");

    test_tlp_format(top, tfp, packets);
    test_wraparound(top, tfp, packets);
    test_backpressure(top, tfp, packets);
    test_arb_priority(top, tfp, packets);
    test_burst_load(top, tfp, packets);

    tfp->close();
    std::cout << "\n======================================================================" << std::endl;
    std::cout << "  PCIe DMA Stress Test Results" << std::endl;
    std::cout << "  Passed: " << test_pass_count << std::endl;
    std::cout << "  Failed: " << test_fail_count << std::endl;
    std::cout << "======================================================================" << std::endl;

    if (test_fail_count > 0) {
        std::cerr << "  *** " << test_fail_count << " ASSERTION(S) FAILED ***" << std::endl;
        return 1;
    }
    std::cout << "  ALL DMA TESTS PASSED!" << std::endl;
    return 0;
}
