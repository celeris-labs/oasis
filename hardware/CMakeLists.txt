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
# One TCP session PER DECODER LANE instead of one shared session (handler_multi). Requires
# ENABLE_HTTP. The ceiling being escaped is the single connection: measured against MinIO, one TCP
# session delivers ~0.46 GB/s however deeply pipelined and sixteen deliver 4.60, with the FPGA at
# 0.33 -- so the session count is worth more than anything inside the decoder.
option(ENABLE_HTTP_MULTI "One TCP session per decoder lane" OFF)

if(ENABLE_HTTP AND ENABLE_RDMA)
    message(FATAL_ERROR "ENABLE_HTTP and ENABLE_RDMA are mutually exclusive")
endif()

if(ENABLE_HTTP_MULTI AND NOT ENABLE_HTTP)
    message(FATAL_ERROR "ENABLE_HTTP_MULTI needs ENABLE_HTTP -- there is no HTTP client to give sessions to")
endif()

# Coyote generates lynx_pkg.sv from its own template, so oasis cannot add a `define there without
# editing the submodule. This generated header is oasis's own, included by vfpga_top.svh.
if(ENABLE_HTTP_MULTI)
    set(OASIS_DEF_EN_TCP_MULTI "`define EN_TCP_MULTI")
else()
    set(OASIS_DEF_EN_TCP_MULTI "// EN_TCP_MULTI off: one shared TCP session for all decoder lanes")
endif()
# Generated into src/hdl/, NOT src/ -- Coyote's cr_user.tcl copies `src/hdl/*` and `vfpga_top.svh`
# into the Vivado project and nothing else, so a header generated one level up never reaches
# synthesis. Until 2026-08-28 an untracked hand-copy at src/hdl/oasis_defines.svh was covering for
# that; it was deleted along with a vfpga_top.svh edit and build-111 failed elaboration with
# "cannot open include file 'oasis_defines.svh'". Keep this path in step with the glob.
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/src/oasis_defines.svh.in
    ${CMAKE_CURRENT_SOURCE_DIR}/src/hdl/oasis_defines.svh
    @ONLY
)

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
    VFPGA_C0_0 "src ../parcore/libstf/hardware/src ../parcore/vhsnunzip/src ../parcore/hardware/src"
)

create_hw()
