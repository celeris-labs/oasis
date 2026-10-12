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
# The 42-probe TCP/HTTP performance ILA in vfpga_top.svh. OFF by default: it costs ~13.2k LUTs and
# ~114.5 BRAM of debug logic in the user region, which a 1- or 2-lane build can afford and a 4-lane
# build cannot (build-110 missed timing at WNS -7.43 ns with it in). Enable for a receive-path
# investigation, not for a build anyone is going to measure.
option(ENABLE_PERF_ILA "Include the TCP/HTTP performance ILA" OFF)
# Per-connection receive slots in card memory (HBM) instead of a BRAM fifo per decoder lane:
# rx_dispatch -> slot_writer -> one 4 MiB slot per TCP connection -> slot_reader per decoder.
# ARCHITECTURE.md ADR-5. Requires ENABLE_HTTP_MULTI. OFF by default so the tree still configures
# exactly as build-119, which is the sealed control arm every measurement on record was taken on.
#
# Turning it ON is not free in the shell: it sets EN_MEM, which adds N_CARD_AXI cdma engines and
# that many more HBM crossbar ports (see the N_MEM_CHAN arithmetic in Coyote's FindCoyoteHW.cmake).
option(ENABLE_HTTP_SLOTS "Per-connection HBM receive slots (handler_slots)" OFF)
# Number of TCP connections. Stage 1 of ADR-5 pairs one connection with one decoder; stage 2 (CSR
# revision 5) gives the decoders a shared pool of up to 32, placed by the host per GET.
set(N_HTTP_CONNS 0 CACHE STRING "TCP connections for handler_slots (0 = same as N_DECODERS)")
# The TOE keeps the receive buffer itself: TCP_STACK_RX_DDR_BYPASS_EN = 0, a 1 MiB ring per session
# in card memory (the TCP stack's existing HBM channel, shared 2:1 with the transmit rings by
# Coyote's tcp_mem_mux; hardware/patches/0008), notifications only after the bytes have landed, and
# readPkg for any session in any order. Replaces the shared 1 MiB rx FIFO of the bypass build and,
# with it, both the arrival-order coupling (rx_dispatch) and the HBM slot buffer (ENABLE_HTTP_SLOTS),
# with which it is mutually exclusive. Needs patches 0007 (network submodule) and 0008 (Coyote), which
# hardware/patches/apply.sh puts in; configure refuses to run without them. EN_MEM stays 0: no card
# AXI stream, no driver card pool.
option(ENABLE_HTTP_TOE_BUFFER "TOE receive rings in card memory (RX_DDR_BYPASS = 0)" OFF)

if(ENABLE_HTTP AND ENABLE_RDMA)
    message(FATAL_ERROR "ENABLE_HTTP and ENABLE_RDMA are mutually exclusive")
endif()

if(ENABLE_HTTP_MULTI AND NOT ENABLE_HTTP)
    message(FATAL_ERROR "ENABLE_HTTP_MULTI needs ENABLE_HTTP -- there is no HTTP client to give sessions to")
endif()

if(ENABLE_HTTP_SLOTS AND NOT ENABLE_HTTP_MULTI)
    message(FATAL_ERROR "ENABLE_HTTP_SLOTS needs ENABLE_HTTP_MULTI -- handler_slots keeps handler_multi's session side, one TCP connection per slot")
endif()

if(ENABLE_HTTP_TOE_BUFFER AND NOT ENABLE_HTTP_MULTI)
    message(FATAL_ERROR "ENABLE_HTTP_TOE_BUFFER needs ENABLE_HTTP_MULTI -- the TOE's receive rings are per session, and the session side is handler_multi's")
endif()

if(ENABLE_HTTP_TOE_BUFFER AND ENABLE_HTTP_SLOTS)
    message(FATAL_ERROR "ENABLE_HTTP_TOE_BUFFER and ENABLE_HTTP_SLOTS are mutually exclusive -- two receive buffers in HBM, and the slot one would add EN_MEM's card stream back")
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

if(ENABLE_HTTP_SLOTS)
    if(N_HTTP_CONNS EQUAL 0)
        set(N_HTTP_CONNS ${N_DECODERS})
    endif()
    # 1..32 (the CSR words address 32 connections) and at least one per decoder: a decoder with no
    # connection of its own to start on would be armable only by stealing a drained one, which works
    # but is never what was meant. handler_slots checks the same at elaboration; here it costs a
    # second instead of a Vivado run.
    if(N_HTTP_CONNS LESS ${N_DECODERS} OR N_HTTP_CONNS GREATER 32)
        message(FATAL_ERROR "N_HTTP_CONNS must be ${N_DECODERS}..32 (N_DECODERS..32), got ${N_HTTP_CONNS}")
    endif()
endif()

# Coyote generates lynx_pkg.sv from its own template, so oasis cannot add a `define there without
# editing the submodule. This generated header is oasis's own, included by vfpga_top.svh.
if(ENABLE_HTTP_MULTI)
    set(OASIS_DEF_EN_TCP_MULTI "`define EN_TCP_MULTI")
else()
    set(OASIS_DEF_EN_TCP_MULTI "// EN_TCP_MULTI off: one shared TCP session for all decoder lanes")
endif()
if(ENABLE_PERF_ILA)
    set(OASIS_DEF_EN_PERF_ILA "`define EN_PERF_ILA")
else()
    set(OASIS_DEF_EN_PERF_ILA "// EN_PERF_ILA off: no performance ILA instantiated (--perf-ila to add it)")
endif()
if(ENABLE_HTTP_SLOTS)
    set(OASIS_DEF_HTTP_SLOTS "`define HTTP_SLOTS\n`define N_HTTP_CONNS ${N_HTTP_CONNS}")
else()
    set(OASIS_DEF_HTTP_SLOTS "// HTTP_SLOTS off: build-119's per-lane BRAM fifos, no card memory")
endif()
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
    if(ENABLE_HTTP_SLOTS)
        # ONE card AXI stream, shared: slot_writer drives its write half (axis_card_send[0], sq_wr
        # dest 0) and every decoder's slot_reader shares the read half (axis_card_recv[0], sq_rd)
        # through slot_rd_share. A Coyote cdma has independent read and write engines on one channel
        # (cdma_u/cdma.sv:167,226), 16 GB/s per direction, and ADR-5 targets 2-4 GB/s.
        #
        # It was N_DECODERS+1 (1 write + 1 read per decoder) until 2026-09-22. build-123 was built
        # that way, placed at WNS -1.53 ns and then FAILED route_design on congestion (34,111
        # unroutable signals). One card AXI stream costs ~25k LUT / ~42k FF / ~32 RAMB36 of SHELL
        # (3-stage 577-bit register arrays, a cdma, an HBM path_i, mmu queues, card credits), 79% of
        # the growth landed in SLR0 next to the HBM controller, and SLR0 went from 76.2% to 99.6%
        # CLB occupancy. Our own logic was not the problem: handler_slots is 22.2k LUT against
        # handler_multi's 21.3k and it FREED 112 RAMB36. See
        # oasis-debug/2026-09-22/build-123-postmortem/deltas.txt. At 1 stream the prediction is
        # 727k LUT total against 823.6k and a PR pblock back at ~87% CLB (build-119: 85.5%).
        #
        # EN_MEM is what instantiates the stream; on the u55c the HBM controller itself is already in
        # the design because the TCP stack needs a card channel, so what this adds is one more cdma
        # engine and one more RAMA/HBM crossbar port. N_CARD_AXI 1 also means MULT_CARD_AXI 0
        # (FindCoyoteHW.cmake:771), under which the shell ignores a descriptor's `dest` for routing
        # and the user-side credit mux indexes a one-entry array with it
        # (dest_req_mux.sv:68) -- so every card descriptor this design issues must carry dest 0.
        set(EN_MEM 1)
        set(N_CARD_AXI 1)
    endif()
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
