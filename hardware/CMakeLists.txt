cmake_minimum_required(VERSION 3.0)
project(oasis)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../parcore/libstf/coyote)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)

# Parallel Vivado jobs. Synthesis runs the decoders' IP out of context, one job each, and 64 jobs
# take ~170 GB; two builds on one host want -DCOMP_CORES=16 (synthesize.sh --cores 16). Set before
# find_package, so Coyote's own default of 8 does not apply.
set(COMP_CORES 64 CACHE STRING "Number of compilation cores")

find_package(CoyoteHW REQUIRED)

# Number of ColumnChunkDecoders. The number of streams is equal to this in local mode. If RDMA is 
# enabled, there will be an additional RDMA bypass stream for the RDMAFileSystem
set(N_DECODERS 1 CACHE STRING "Number of ColumnChunkDecoders (default=1)")

# Include Coyote's RDMA stack during synthesis (disable with -DENABLE_RDMA=OFF)
option(ENABLE_RDMA "Enable RDMA stack" ON)
# FPGA HTTP ranged-GET client feeding the decoders (mutually exclusive with RDMA): one TCP session
# per decoder lane (handler_multi).
option(ENABLE_HTTP "Enable HTTP stack" OFF)

if(ENABLE_HTTP AND ENABLE_RDMA)
    message(FATAL_ERROR "ENABLE_HTTP and ENABLE_RDMA are mutually exclusive")
endif()

# handler_multi reads the TOE's receive bypass stream (rx_dispatch), so the TOE is always built with
# the DDR bypass on the receive path. FORCE, so a cache entry set to 0 by hand cannot build a TOE the
# shell and the handler do not match. Set before create_hw() below, which adds the network
# subproject (hls/toe/CMakeLists.txt's own set(CACHE) default is then a no-op).
set(TCP_STACK_RX_DDR_BYPASS_EN 1 CACHE BOOL "Enabling DDR bypass on the RX path" FORCE)

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
# routing can carry, so whole decoders are pinned to SLRs by pblocks (constraints/decoder_pblocks.xdc).
# Coyote's flow reads no user implementation constraints, so the hook is a line added
# to this build directory's generated pnr_shell.tcl: it sources decoder_pblocks.tcl on the opened
# design right after opt_design, before place_design. Directives and every other step are Coyote's.
option(ENABLE_DECODER_PBLOCKS "Pin the HTTP decoders to SLRs (hardware/constraints, 4 decoders)" ON)
if(ENABLE_HTTP AND ENABLE_DECODER_PBLOCKS AND N_DECODERS EQUAL 4)
    set(OASIS_PBLOCK_XDC ${CMAKE_CURRENT_SOURCE_DIR}/constraints/decoder_pblocks.xdc)
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
    message(STATUS "Decoder pblocks: none (${N_DECODERS} decoders; the floorplan is for 4)")
endif()
