cmake_minimum_required(VERSION 3.16)

set(TARGET_NAME oasis)

set(EXTENSION_NAME ${TARGET_NAME}_extension)
set(LOADABLE_EXTENSION_NAME ${TARGET_NAME}_loadable_extension)

project(${TARGET_NAME})

# https://github.com/duckdb/duckdb/issues/22097
set(CMAKE_CXX_STANDARD 17 CACHE STRING "C++ standard to enforce" FORCE)
set(CMAKE_CXX_STANDARD_REQUIRED True)

include_directories(src/include)
include_directories(duckdb/extension/parquet/include)
include_directories(duckdb/third_party/parquet)
include_directories(duckdb/third_party/thrift)

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

# Both parcore/coyote/sw and parcore/coyote/sim/sw declare a target named
# "Coyote" — the former opens a real FPGA char device, the latter spawns
# Vivado xsim in the background and pipes to it. Swap the subdirectory to
# switch between real hardware and simulation; everything downstream
# (libstf, ParCore) links to "Coyote" without caring which one it got.
#
# For simulation you also need:
#   * parcore/build_hw/sim/ populated (run parcore/sim_setup.sh once)
#   * xsim on PATH
#   * COYOTE_SIM_DIR=<abs path to parcore/build_hw> at runtime
option(EN_SIMULATION "Link against Coyote simulation library (no FPGA required)" ON)
if (EN_SIMULATION)
    find_package(CoyoteSimulation REQUIRED)
    add_compile_definitions(EN_SIMULATION)
else ()
    find_package(Coyote REQUIRED)
endif ()

find_package(libstf REQUIRED)

find_package(Arrow REQUIRED)
find_package(parcore REQUIRED)
find_package(oasis REQUIRED)

# ---------------------------------------------------------------------------
# Extension
# ---------------------------------------------------------------------------
set(EXTENSION_SOURCES src/oasis_extension.cpp src/oasis_filter.cpp src/oasis_scan.cpp)

build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

target_link_libraries(${EXTENSION_NAME} Coyote libstf parcore oasis)
target_link_libraries(${LOADABLE_EXTENSION_NAME} Coyote libstf parcore oasis)

install(
    TARGETS ${EXTENSION_NAME}
    EXPORT "${DUCKDB_EXPORT_SET}"
    LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
    ARCHIVE DESTINATION "${INSTALL_LIB_DIR}"
)
