cmake_minimum_required(VERSION 3.0)
project(oasis)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../coyote)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)

find_package(CoyoteHW REQUIRED)

# Number of vFPGAs (user applications)
set(N_REGIONS 1)

# Enables four streams to host memory
set(EN_STRM 1)
set(N_STRM_AXI 4)

# Incldue Coyote's RDMA stack during synthesis
set(EN_RDMA 1)
set(N_RDMA_AXI 4)

# Build with optimization, since timing closure with RDMA can be difficult
set(COMP_CORES 64)
set(BUILD_OPT 1)

set(FDEV_NAME u55c)

# Enable 1 GiB huge pages in the TLB
set(TLBL_BITS 30)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src ../parcore/libstf/hardware/src ../parcore/vhsnunzip/src ../parcore/hardware/src"
)

create_hw()
