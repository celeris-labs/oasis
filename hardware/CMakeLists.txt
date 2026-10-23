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
# 0 or 1. vfpga_top.svh picks handler_toe over handler_multi on the same EN_TCP_RX_DDR, which lives in
# each build directory's own lynx_pkg.sv, so build directories of both configurations can be
# configured from one tree. FORCE in both directions, so a reconfigured build directory cannot keep a
# stale value. This runs before validation_checks_hw() and create_hw() below, which is where Coyote
# reads it and adds the network subproject (hls/toe/CMakeLists.txt's own set(CACHE) default is then a
# no-op).
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

# Decoder floorplan. With four decoders the placer's own SLR split leaves more logic in SLR1 than its
# routing can carry, so whole decoders are pinned to SLRs by pblocks (constraints/, one file per
# configuration). Coyote's flow reads no user implementation constraints, so the hook is a line added
# to this build directory's generated pnr_shell.tcl: it sources decoder_pblocks.tcl on the opened
# design right after opt_design, before place_design. Directives and every other step are Coyote's.
option(ENABLE_DECODER_PBLOCKS "Pin the HTTP decoders to SLRs (hardware/constraints, 4 decoders)" ON)
if(ENABLE_HTTP AND ENABLE_DECODER_PBLOCKS AND N_DECODERS EQUAL 4)
    if(ENABLE_HTTP_TOE_BUFFER)
        set(OASIS_PBLOCK_XDC ${CMAKE_CURRENT_SOURCE_DIR}/constraints/decoder_pblocks_toe_buffer.xdc)
    else()
        set(OASIS_PBLOCK_XDC ${CMAKE_CURRENT_SOURCE_DIR}/constraints/decoder_pblocks_bypass.xdc)
    endif()
    configure_file(${CMAKE_CURRENT_SOURCE_DIR}/constraints/decoder_pblocks.tcl.in
                   ${CMAKE_BINARY_DIR}/decoder_pblocks.tcl @ONLY)
    file(READ ${CMAKE_BINARY_DIR}/pnr_shell.tcl OASIS_PNR)
    set(OASIS_PNR_AT "write_checkpoint -force \"$dcp_dir/shell_opted.dcp\"\n")
    set(OASIS_PNR_HOOK "source \"${CMAKE_BINARY_DIR}/decoder_pblocks.tcl\"\n")
    string(FIND "${OASIS_PNR}" "${OASIS_PNR_AT}" OASIS_PNR_POS)
    if(OASIS_PNR_POS EQUAL -1)
        message(FATAL_ERROR "decoder pblocks: pnr_shell.tcl has no line `write_checkpoint ... shell_opted.dcp` to hook after")
    endif()
    string(FIND "${OASIS_PNR}" "${OASIS_PNR_HOOK}" OASIS_PNR_HOOKED)
    if(OASIS_PNR_HOOKED EQUAL -1)
        string(REPLACE "${OASIS_PNR_AT}" "${OASIS_PNR_AT}${OASIS_PNR_HOOK}" OASIS_PNR "${OASIS_PNR}")
        file(WRITE ${CMAKE_BINARY_DIR}/pnr_shell.tcl "${OASIS_PNR}")
    endif()
    message(STATUS "Decoder pblocks: ${OASIS_PBLOCK_XDC}")
elseif(ENABLE_HTTP)
    message(STATUS "Decoder pblocks: none (${N_DECODERS} decoders; the floorplans are for 4)")
endif()
