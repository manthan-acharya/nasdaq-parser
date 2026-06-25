# Low-Latency FPGA Trading Platform

An end-to-end, ultra-low latency High-Frequency Trading (HFT) accelerator pipeline implemented in synthesizable SystemVerilog. The project is designed to ingest raw network market feeds, parse updates on-the-fly, maintain a Limit Order Book, calculate arbitrage signals via hardware DSPs, and execute orders over an offloaded TCP session directly to the exchange.

---

## Project Status & Goals

> [!NOTE]
> **Active Development / Work in Progress**: The codebase is currently fully functional in cycle-accurate simulations.
>
> **Purpose**: This was developed as a hands-on project to learn FPGA design principles and bare-metal hardware-software co-design.
>
> **Next Steps**: The immediate plan is to synthesize, place-and-route, and test the design on a physical Xilinx UltraScale+ FPGA development board to measure real-world hardware latencies and transceiver integration.

---

## System Architecture

The platform consists of the following key subsystems:

1. **Inbound Market Data Handlers**: An IP/UDP parser with 2-byte alignment gearbox, supporting high-speed NASDAQ ITCH-5.0 and CME Globex SBE decoders.
2. **Limit Order Book (LOB)**: A 3-stage pipelined book tracking Level-1 Best Bid/Offer (BBO). Utilizes a zero-latency 10-bit XOR ticker hashing algorithm mapped to dual-port BRAM blocks.
3. **Execution Logic (DSP Math)**: Pipelined Q8.24 fixed-point multipliers optimized for FPGA DSP slices that check triangular arbitrage loops ($Rate_{A/B} \times Rate_{B/C} \times Rate_{C/A} > 1.0003$) in exactly 2 clock cycles.
4. **TCP Offload Engine (TOE)**: An RFC 793 compliant TCP state machine and outbound FIX New Order Single compiler running entirely in hardware to bypass OS network stack overhead.
5. **PCIe DMA Controller**: Custom Transaction Layer Packet (TLP) generator that writes BBO updates and arbitrage alerts directly to physical buffers in host RAM using zero-copy coherent ring memory.

---

## Directory Structure

```
nasdaq_parser/
├── rtl/                        # Synthesizable SystemVerilog RTL
│   ├── network/                # UDP parser, SBE/ITCH decoders, and TCP Offload Engine
│   ├── lob/                    # Limit Order Book and dual-port BRAM wrappers
│   ├── execution/              # Q8.24 DSP math and triangular arbitrage logic
│   └── pcie/                   # PCIe DMA controller and TLP compiler
├── sim/                        # Verification and Verilator Simulation Suite
│   ├── dpi/                    # C++ DPI-C helpers for hardware driver injection
│   └── tb/                     # Flattened testbench wrappers and test runners
└── software/                   # C++ software baseline and Linux kernel PCIe driver
```

---

## Getting Started

### Prerequisites

To compile and run the cycle-accurate simulator:
* **Verilog Simulator**: Verilator (v5.0+)
* **C++ Compiler**: GCC/Clang with C++17 support
* **Build System**: GNU Make

### Running Simulation and Benchmarks

1. **Run the Integrated HFT Simulation**:
   ```bash
   cd sim
   make clean && make run
   ```
   This generates mock ITCH market data, performs the MMIO configuration, completes the 3-way TCP handshake, streams packet data, triggers the arbitrage engine, and asserts outbound PCIe DMA write TLPs.

2. **Run Latency and Jitter Benchmarks**:
   ```bash
   cd sim
   make run_benchmark
   ```
   Compares the cycle-accurate FPGA hardware pipeline latency (~25.6 ns at 156.25 MHz) against an optimized single-threaded C++ software baseline, highlighting the jitter-free performance of hardware.

---

## License

This project is licensed under the MIT License.
