cmake_minimum_required(VERSION 3.0)
project(oasis)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../parcore/libstf/coyote)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)

find_package(CoyoteHW REQUIRED)

# Number of ColumnChunkDecoders. The number of streams is equal to this in local mode. If RDMA is 
# enabled, there will be an additional RDMA bypass stream for the RDMAFileSystem
set(N_DECODERS 1 CACHE STRING "Number of ColumnChunkDecoders (default=1)")

# Include Coyote's RDMA stack during synthesis (disable with -DENABLE_RDMA=OFF)
option(ENABLE_RDMA "Enable RDMA stack" ON)
# FPGA HTTP ranged-GET client on the bypass stream (mutually exclusive with RDMA)
option(ENABLE_HTTP "Enable HTTP stack" OFF)

if(ENABLE_HTTP AND ENABLE_RDMA)
    message(FATAL_ERROR "ENABLE_HTTP and ENABLE_RDMA are mutually exclusive")
endif()

# Number of vFPGAs (user applications)
set(N_REGIONS 1)
set(EN_STRM 1)


if(ENABLE_HTTP)
    math(EXPR N_STREAMS "${N_DECODERS} + 1")
    set(EN_TCP 1)
    set(N_TCP_AXI 1)
    set(N_STRM_AXI ${N_STREAMS})
elseif(ENABLE_RDMA)
    math(EXPR N_STREAMS "${N_DECODERS} + 1")
    set(EN_RDMA 1)
    set(N_RDMA_AXI ${N_STREAMS})
    set(N_STRM_AXI ${N_STREAMS})
else()
    set(EN_RDMA 0)
    set(N_STRM_AXI ${N_DECODERS})
endif()

# Build with optimization, since timing closure can be difficult
set(COMP_CORES 64)
set(BUILD_OPT 1)

set(FDEV_NAME u55c)

# Enable 1 GiB huge pages in the TLB
set(TLBL_BITS 30)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src ../parcore/libstf/hardware/src ../parcore/vhsnunzip/src ../parcore/hardware/src ../celeris/hardware/src"
)

create_hw()
