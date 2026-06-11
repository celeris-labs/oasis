cmake_minimum_required(VERSION 3.0)
project(oasis)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../parcore/coyote)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)

find_package(CoyoteHW REQUIRED)

# Number of vFPGAs (user applications)
set(N_REGIONS 1)

# Enables four streams to host memory
set(EN_STRM 1)
set(N_STRM_AXI 4)

# Include Coyote's RDMA stack during synthesis (disable with -DENABLE_RDMA=OFF)
option(ENABLE_RDMA "Enable RDMA stack" ON)
if(ENABLE_RDMA)
    set(EN_RDMA 1)
    set(N_RDMA_AXI 4)
else()
    set(EN_RDMA 0)
endif()

# Build with optimization, since timing closure with RDMA can be difficult
set(COMP_CORES 64)
set(BUILD_OPT 1)

set(FDEV_NAME u55c)

# Enable 1 GiB huge pages in the TLB
set(TLBL_BITS 30)

validation_checks_hw()

# Build only the Celeris sources needed by FilterOperator. Loading the entire
# Celeris RTL tree causes unrelated modules to interfere with Oasis dependencies.
set(CELERIS_HW_DIR ${CMAKE_SOURCE_DIR}/../celeris/hardware)
set(CELERIS_FILTER_BRIDGE_DIR ${CMAKE_BINARY_DIR}/celeris-filter-bridge)
file(RELATIVE_PATH CELERIS_FILTER_BRIDGE_APP_DIR ${CMAKE_SOURCE_DIR} ${CELERIS_FILTER_BRIDGE_DIR})

set(CELERIS_FILTER_SOURCES
    ${CELERIS_HW_DIR}/src/hdl/common.sv
    ${CELERIS_HW_DIR}/src/hdl/config/config_interfaces.sv
    ${CELERIS_HW_DIR}/src/hdl/config/filter_config.sv
    ${CELERIS_HW_DIR}/src/hdl/filter/filter_bitmask.sv
    ${CELERIS_HW_DIR}/src/hdl/filter/filter_double_comparator.sv
    ${CELERIS_HW_DIR}/src/hdl/filter/filter_int_comparator.sv
    ${CELERIS_HW_DIR}/src/hdl/filter/filter_layer_combiner.sv
    ${CELERIS_HW_DIR}/src/hdl/filter/filter_operator.sv
    ${CELERIS_HW_DIR}/src/hdl/filter/filter_stream_combiner.sv
    ${CELERIS_HW_DIR}/src/hdl/axi/axi_mask_macro.svh
    ${CELERIS_HW_DIR}/src/hdl/axi/axi_shift_register.sv
)

file(COPY
    ${CELERIS_FILTER_SOURCES}
    DESTINATION ${CELERIS_FILTER_BRIDGE_DIR}/hdl
)
file(COPY
    ${CELERIS_HW_DIR}/src/init_ip.tcl
    DESTINATION ${CELERIS_FILTER_BRIDGE_DIR}
)

load_apps (
    VFPGA_C0_0 "src ../parcore/libstf/hardware/src ../parcore/vhsnunzip/src ../parcore/hardware/src ${CELERIS_FILTER_BRIDGE_APP_DIR}"
)

create_hw()
