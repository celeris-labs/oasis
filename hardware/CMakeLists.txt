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
# FPGA HTTP ranged-GET client feeding the decoders (mutually exclusive with RDMA): one TCP session
# per decoder lane (handler_multi, or handler_toe with ENABLE_HTTP_TOE_BUFFER).
option(ENABLE_HTTP "Enable HTTP stack" OFF)
# The TOE keeps the receive buffer itself: TCP_STACK_RX_DDR_BYPASS_EN = 0, a 1 MiB ring per session
# in card memory (the TCP stack's existing HBM channel, shared 2:1 with the transmit rings by
# Coyote's tcp_mem_mux; hardware/patches/0008), notifications only after the bytes have landed, and
# readPkg for any session in any order. Replaces the shared 1 MiB rx FIFO of the bypass build and,
# with it, the arrival-order coupling (rx_dispatch). Needs patches 0007 (network submodule) and 0008
# (Coyote), which hardware/patches/apply.sh puts in; configure refuses to run without them. EN_MEM
# stays 0: no card AXI stream, no driver card pool.
option(ENABLE_HTTP_TOE_BUFFER "TOE receive rings in card memory (RX_DDR_BYPASS = 0)" OFF)

if(ENABLE_HTTP AND ENABLE_RDMA)
    message(FATAL_ERROR "ENABLE_HTTP and ENABLE_RDMA are mutually exclusive")
endif()

if(ENABLE_HTTP_TOE_BUFFER AND NOT ENABLE_HTTP)
    message(FATAL_ERROR "ENABLE_HTTP_TOE_BUFFER needs ENABLE_HTTP -- the TOE's receive rings are per session, and the session side is the HTTP client's")
endif()

# The one knob for both halves: Coyote derives the TOE's toe_config.hpp (HLS) AND the shell's
# tcp_stack parameter + memory mux (lynx_pkg EN_TCP_RX_DDR) from this cache variable, and checks it is
# 0 or 1. FORCE in both directions, so a reconfigured build directory cannot keep a stale value. This
# runs before validation_checks_hw() and create_hw() below, which is where Coyote reads it and adds
# the network subproject (hls/toe/CMakeLists.txt's own set(CACHE) default is then a no-op).
if(ENABLE_HTTP_TOE_BUFFER)
    # Without 0008 the shell would stay in bypass while the TOE's HLS does not (a port mismatch that
    # synthesis only reports half an hour in); without 0007 the TOE's receive ring is broken.
    if(NOT EXISTS ${CYT_DIR}/hw/hdl/network/tcp/tcp_mem_mux.sv)
        message(FATAL_ERROR "ENABLE_HTTP_TOE_BUFFER: patch 0008 is not applied to ${CYT_DIR} -- run hardware/patches/apply.sh")
    endif()
    file(READ ${CYT_DIR}/hw/services/network/hls/toe/toe.cpp OASIS_TOE_CPP)
    string(FIND "${OASIS_TOE_CPP}" "rxAppReadRelease" OASIS_TOE_0007)
    if(OASIS_TOE_0007 EQUAL -1)
        message(FATAL_ERROR "ENABLE_HTTP_TOE_BUFFER: patch 0007 is not applied to the network submodule -- run hardware/patches/apply.sh")
    endif()
    set(TCP_STACK_RX_DDR_BYPASS_EN 0 CACHE BOOL "Enabling DDR bypass on the RX path" FORCE)
else()
    set(TCP_STACK_RX_DDR_BYPASS_EN 1 CACHE BOOL "Enabling DDR bypass on the RX path" FORCE)
endif()

# Coyote generates lynx_pkg.sv from its own template, so oasis cannot add a `define there without
# editing the submodule. This generated header is oasis's own, included by vfpga_top.svh.
# vfpga_top.svh instantiates handler_toe (toe_rx: readPkg for any session, any order) instead of
# handler_multi when the TOE keeps the receive rings.
if(ENABLE_HTTP_TOE_BUFFER)
    set(OASIS_DEF_HTTP_TOE_BUF "`define HTTP_TOE_BUF")
else()
    set(OASIS_DEF_HTTP_TOE_BUF "// HTTP_TOE_BUF off: TOE in bypass mode (one shared rx fifo), handler_multi's rx_dispatch")
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
