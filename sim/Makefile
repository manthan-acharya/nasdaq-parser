# =============================================================================
# Company:        Ultra-Low Latency HFT Systems
# Engineer:       Senior FPGA Hardware-Software Engineer
# 
# Create Date:    2026-05-31
# File Name:      Makefile
# Description:    GNU Makefile to automate Verilator compilation and cycle-accurate
#                 simulations for the HFT integrated pipeline.
# =============================================================================

# Tools
VERILATOR = verilator
RM = rm -rf

# Directory Paths
RTL_DIR = ../rtl
SIM_DIR = .
DPI_DIR = $(SIM_DIR)/dpi
TB_DIR = $(SIM_DIR)/tb

# Verilator Compilation Search Paths
VERILATOR_FLAGS = --cc --exe --build -Wall -j \
                  -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-DECLFILENAME -Wno-style \
                  -I$(RTL_DIR) \
                  -I$(RTL_DIR)/network \
                  -I$(RTL_DIR)/network/itch \
                  -I$(RTL_DIR)/network/cme_sbe \
                  -I$(RTL_DIR)/network/toe \
                  -I$(RTL_DIR)/lob \
                  -I$(RTL_DIR)/execution \
                  -I$(RTL_DIR)/pcie \
                  --x-assign unique --x-initial unique --trace --trace-structs

# =============================================================================
# Target 1: NASDAQ ITCH & LOB Parser Simulation
# =============================================================================
ITCH_SOURCES = $(RTL_DIR)/network/itch/itch_types.sv \
               $(RTL_DIR)/network/udp_parser.sv \
               $(RTL_DIR)/network/itch/itch_parser.sv \
               $(RTL_DIR)/lob/lob_bram.sv \
               $(RTL_DIR)/lob/order_book.sv \
               $(TB_DIR)/tb_nasdaq_parser.sv

ITCH_CPP = $(DPI_DIR)/market_data_sim.cpp
ITCH_EXE = obj_dir/Vtb_nasdaq_parser

# =============================================================================
# Target 2: Integrated hft_top System Simulation (Arbitrage & TOE)
# =============================================================================
TOP_SOURCES = $(RTL_DIR)/network/itch/itch_types.sv \
              $(RTL_DIR)/network/udp_parser.sv \
              $(RTL_DIR)/network/itch/itch_parser.sv \
              $(RTL_DIR)/lob/lob_bram.sv \
              $(RTL_DIR)/lob/order_book.sv \
              $(RTL_DIR)/execution/q8_24_mul.sv \
              $(RTL_DIR)/execution/arb_engine.sv \
              $(RTL_DIR)/network/toe/tcp_state_m.sv \
              $(RTL_DIR)/network/toe/tcp_tx_packet.sv \
              $(RTL_DIR)/network/toe/toe_top.sv \
              $(RTL_DIR)/pcie/dma_controller.sv \
              $(RTL_DIR)/pcie/pcie_dma_top.sv \
              $(RTL_DIR)/hft_top.sv \
              $(TB_DIR)/tb_hft_top.sv

TOP_CPP = $(TB_DIR)/sim_hft_top.cpp
TOP_EXE = obj_dir/Vtb_hft_top

BENCH_CPP = ../software/benchmark/benchmark_runner.cpp
BENCH_EXE = obj_dir/Vtb_hft_top_bench

DMA_CPP = $(TB_DIR)/sim_pcie_dma_test.cpp
DMA_EXE = obj_dir/Vtb_hft_top_dma

.PHONY: all compile_itch run_itch compile_top run_top compile_benchmark run_benchmark compile_dma_test run_dma_test clean run

all: run

# Default target runs the full HFT integrated design
run: run_top

compile_itch: $(ITCH_SOURCES) $(ITCH_CPP)
	@echo "======================================================================="
	@echo " Compiling Nasdaq & CME SBE & LOB Modules with Verilator..."
	@echo "======================================================================="
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_nasdaq_parser $(ITCH_SOURCES) $(ITCH_CPP)

run_itch: compile_itch
	@echo "======================================================================="
	@echo " Running Low-Latency Feed Handler End-to-End Simulation..."
	@echo "======================================================================="
	@if [ ! -f "raw_packets.bin" ]; then \
		echo "[INFO] raw_packets.bin not found. Running generate_ticks.py..."; \
		chmod +x generate_ticks.py && ./generate_ticks.py; \
	fi
	./$(ITCH_EXE)

compile_top: $(TOP_SOURCES) $(TOP_CPP)
	@echo "======================================================================="
	@echo " Compiling Complete Integrated hft_top System with Verilator..."
	@echo "======================================================================="
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_hft_top $(TOP_SOURCES) $(TOP_CPP)

run_top: compile_top
	@echo "======================================================================="
	@echo " Running Full hft_top Integrated HFT Simulation..."
	@echo "======================================================================="
	@if [ ! -f "raw_packets.bin" ]; then \
		echo "[INFO] raw_packets.bin not found. Running generate_ticks.py..."; \
		chmod +x generate_ticks.py && ./generate_ticks.py; \
	fi
	./$(TOP_EXE)

compile_benchmark: $(TOP_SOURCES) $(BENCH_CPP)
	@echo "======================================================================="
	@echo " Compiling HFT System Latency Benchmarking Suite with Verilator..."
	@echo "======================================================================="
	$(VERILATOR) $(VERILATOR_FLAGS) --top-module tb_hft_top $(TOP_SOURCES) $(BENCH_CPP)
	mv obj_dir/Vtb_hft_top obj_dir/Vtb_hft_top_bench

run_benchmark: compile_benchmark
	@echo "======================================================================="
	@echo " Running HFT System Latency Benchmarks..."
	@echo "======================================================================="
	@if [ ! -f "raw_packets.bin" ]; then \
		echo "[INFO] raw_packets.bin not found. Running generate_ticks.py..."; \
		chmod +x generate_ticks.py && ./generate_ticks.py; \
	fi
	./$(BENCH_EXE) --bench

compile_dma_test: $(TOP_SOURCES) $(DMA_CPP)
	@echo "======================================================================="
	@echo " Compiling PCIe DMA Stress Test Suite with Verilator..."
	@echo "======================================================================="
	$(VERILATOR) $(VERILATOR_FLAGS) --prefix Vtb_hft_top_dma --top-module tb_hft_top $(TOP_SOURCES) $(DMA_CPP)

run_dma_test: compile_dma_test
	@echo "======================================================================="
	@echo " Running PCIe DMA Stress Tests..."
	@echo "======================================================================="
	@if [ ! -f "raw_packets.bin" ]; then \
		echo "[INFO] raw_packets.bin not found. Running generate_ticks.py..."; \
		chmod +x generate_ticks.py && ./generate_ticks.py; \
	fi
	./$(DMA_EXE)

clean:
	@echo "Cleaning simulation build artifacts..."
	$(RM) obj_dir
	$(RM) *.bin
	$(RM) *.vcd
	$(RM) *.log
