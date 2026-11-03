cmake_minimum_required(VERSION 3.0)
project(oasis)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../parcore/libstf/coyote)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)

find_package(CoyoteHW REQUIRED)

# Number of ColumnChunkDecoders. The number of streams with an input side is equal to this in local
# mode. If RDMA is enabled, there will be an additional RDMA bypass stream for the RDMAFileSystem
set(N_DECODERS 1 CACHE STRING "Number of ColumnChunkDecoders (default=1)")

# Include Coyote's RDMA stack during synthesis (disable with -DENABLE_RDMA=OFF)
option(ENABLE_RDMA "Enable RDMA stack" ON)

# The Bloom filter has its own host output streams (kept keys, mask and materialized columns), so
# they are read in parallel. They have no input side, and come on top of the streams above. See
# BF_NUM_OUT_CHANNELS in src/vfpga_top.svh.
set(N_BLOOM_OUT_STREAMS 3)

# Number of vFPGAs (user applications)
set(N_REGIONS 1)
set(EN_STRM 1)

if(ENABLE_RDMA)
    math(EXPR N_STREAMS "${N_DECODERS} + 1")
    set(EN_RDMA 1)
    # The RDMA streams are the ones with an input side
    set(N_RDMA_AXI ${N_STREAMS})
    math(EXPR N_STRM_AXI "${N_STREAMS} + ${N_BLOOM_OUT_STREAMS}")
else()
    set(EN_RDMA 0)
    math(EXPR N_STRM_AXI "${N_DECODERS} + ${N_BLOOM_OUT_STREAMS}")
endif()

# The interrupt carries 3 bits of host stream id (libstf::FPGA_INTERRUPT_STREAM_ID_BITS)
if(N_STRM_AXI GREATER 8)
    message(FATAL_ERROR "At most 8 host streams are supported, but ${N_DECODERS} decoder(s) and the "
                        "Bloom filter's ${N_BLOOM_OUT_STREAMS} output streams need ${N_STRM_AXI}.")
endif()

# Build with optimization, since timing closure can be difficult
set(COMP_CORES 64)
set(BUILD_OPT 1)

# Target FPGA device (override with -DFDEV_NAME=v80 for the Alveo V80)
set(FDEV_NAME u55c CACHE STRING "Target FPGA device (u55c, v80, ...)")

# Enable 1 GiB huge pages in the TLB
set(TLBL_BITS 30)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src ../parcore/libstf/hardware/src ../parcore/vhsnunzip/src ../parcore/hardware/src ../celeris/hardware/src"
)

create_hw()
