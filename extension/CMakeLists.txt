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
#   * the relevant hardware build populated and xsim on PATH
#   * COYOTE_SIM_DIR=<abs path to the build_hw dir> at runtime
# The default is OFF (real FPGA). Configure with -DEN_SIMULATION=ON to run against a
# simulated bitstream. Note the two simulation targets use different sim dirs:
#   * read_oasis scan sim  -> parcore/build_hw  (Oasis ParCore bitstream)
#   * regex_fpga sim       -> celeris/hardware/build  (Celeris regex bitstream)
option(EN_SIMULATION "Link against Coyote simulation library (no FPGA required)" OFF)
if (EN_SIMULATION)
    find_package(CoyoteSimulation REQUIRED)
    add_compile_definitions(EN_SIMULATION)
else ()
    find_package(Coyote REQUIRED)
endif ()

find_package(libstf REQUIRED)

find_package(parcore REQUIRED)
find_package(oasis REQUIRED)
find_package(caliper REQUIRED)

set(CELERIS_SOFTWARE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../celeris/software")
set(CELERIS_REGEX_DIR "${CELERIS_SOFTWARE_DIR}/celeris/operators/regex")
set(FREGEX_BUILD_DIR "${CMAKE_BINARY_DIR}/fregex-build")
set(FREGEX_SHARED_LIB "${FREGEX_BUILD_DIR}/libfregex.so")


include(ExternalProject)
ExternalProject_Add(oasis_fregex_ext
    SOURCE_DIR ${CELERIS_REGEX_DIR}
    BINARY_DIR ${FREGEX_BUILD_DIR}
    CMAKE_ARGS
        -DCMAKE_CXX_STANDARD=20
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
    BUILD_COMMAND ${CMAKE_COMMAND} --build . --target fregex_shared
    INSTALL_COMMAND ""
    BUILD_BYPRODUCTS ${FREGEX_SHARED_LIB}
    USES_TERMINAL_BUILD TRUE
)

# Celeris RegexConfig CSR driver and singleton FPGA context.
set(FPGA_REGEX_SOURCES
    ${CELERIS_SOFTWARE_DIR}/celeris/configuration.cpp
    ${CELERIS_SOFTWARE_DIR}/celeris/celeris_context.cpp
    ${CELERIS_SOFTWARE_DIR}/celeris/shared_resource_lock.cpp
)

# ---------------------------------------------------------------------------
# Extension
# ---------------------------------------------------------------------------
set(EXTENSION_SOURCES src/oasis_extension.cpp src/oasis_scan.cpp src/oasis_profile.cpp
                      src/rdma_file_system.cpp src/filter_pushdown.cpp src/parcore_metadata_util.cpp
                      src/oasis_settings.cpp src/coalesced_fetcher.cpp
                      src/regex.cpp src/regex_fpga_batch.cpp src/regex_table.cpp ${FPGA_REGEX_SOURCES})

build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

target_include_directories(${EXTENSION_NAME} BEFORE PRIVATE ${CELERIS_SOFTWARE_DIR} ${CELERIS_REGEX_DIR} )
target_include_directories(${LOADABLE_EXTENSION_NAME} BEFORE PRIVATE ${CELERIS_SOFTWARE_DIR} ${CELERIS_REGEX_DIR} )

add_dependencies(${EXTENSION_NAME} oasis_fregex_ext)
add_dependencies(${LOADABLE_EXTENSION_NAME} oasis_fregex_ext)

# Caliper region profiling is not thread-safe under DuckDB's parallel pipeline; keep it off by
# default and enable it only for single-threaded profiling builds.
option(OASIS_ENABLE_PROFILING "Enable Caliper region profiling (single-threaded use only)" OFF)
if (OASIS_ENABLE_PROFILING)
    target_compile_definitions(${EXTENSION_NAME} PRIVATE OASIS_ENABLE_PROFILING)
    target_compile_definitions(${LOADABLE_EXTENSION_NAME} PRIVATE OASIS_ENABLE_PROFILING)
endif ()

set_target_properties(${EXTENSION_NAME} PROPERTIES BUILD_RPATH "${FREGEX_BUILD_DIR}")
set_target_properties(${LOADABLE_EXTENSION_NAME} PROPERTIES BUILD_RPATH "${FREGEX_BUILD_DIR}")

target_link_libraries(${EXTENSION_NAME} Coyote libstf parcore oasis caliper ${FREGEX_SHARED_LIB})
target_link_libraries(${LOADABLE_EXTENSION_NAME} Coyote libstf parcore oasis caliper ${FREGEX_SHARED_LIB})

install(
    TARGETS ${EXTENSION_NAME}
    EXPORT "${DUCKDB_EXPORT_SET}"
    LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
    ARCHIVE DESTINATION "${INSTALL_LIB_DIR}"
)
