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
#   * celeris hardware build populated (see celeris/hardware)
#   * xsim on PATH
#   * COYOTE_SIM_DIR=<abs path to parcore/build_hw> at runtime
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

set(CELERIS_SOFTWARE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../celeris/software")
set(CELERIS_REGEX_DIR "${CELERIS_SOFTWARE_DIR}/celeris/operators/regex")
set(FREGEX_BUILD_DIR "${CMAKE_BINARY_DIR}/fregex-build")
set(FREGEX_SHARED_LIB "${FREGEX_BUILD_DIR}/libfregex.so")

# ---------------------------------------------------------------------------
# Abseil headers — needed to compile regex.cpp, which includes nfa.hpp which
# transitively pulls in re2/regexp.h → absl/log/absl_check.h.
# We only need the source tree (headers); linking is via libfregex.so which
# already has abseil compiled in.
# ---------------------------------------------------------------------------
include(FetchContent)
FetchContent_Declare(
    abseil
    GIT_REPOSITORY https://github.com/abseil/abseil-cpp.git
    GIT_TAG        20240722.0
)
FetchContent_GetProperties(abseil)
if(NOT abseil_POPULATED)
    FetchContent_Populate(abseil)
endif()

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

set(FPGA_REGEX_SOURCES ${CELERIS_SOFTWARE_DIR}/celeris/configuration.cpp)

# ---------------------------------------------------------------------------
# Extension
# ---------------------------------------------------------------------------
set(EXTENSION_SOURCES src/oasis_extension.cpp src/oasis_scan.cpp src/oasis_profile.cpp
                      src/rdma_file_system.cpp src/filter_pushdown.cpp src/parcore_metadata_util.cpp
                      src/oasis_settings.cpp src/coalesced_fetcher.cpp)

build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

target_include_directories(${EXTENSION_NAME} BEFORE PRIVATE ${CELERIS_SOFTWARE_DIR} ${CELERIS_REGEX_DIR} ${abseil_SOURCE_DIR})
target_include_directories(${LOADABLE_EXTENSION_NAME} BEFORE PRIVATE ${CELERIS_SOFTWARE_DIR} ${CELERIS_REGEX_DIR} ${abseil_SOURCE_DIR})

add_dependencies(${EXTENSION_NAME} oasis_fregex_ext)
add_dependencies(${LOADABLE_EXTENSION_NAME} oasis_fregex_ext)

set_target_properties(${EXTENSION_NAME} PROPERTIES BUILD_RPATH "${FREGEX_BUILD_DIR}")
set_target_properties(${LOADABLE_EXTENSION_NAME} PROPERTIES BUILD_RPATH "${FREGEX_BUILD_DIR}")

target_link_libraries(${EXTENSION_NAME} Coyote libstf parcore oasis ${FREGEX_SHARED_LIB})
target_link_libraries(${LOADABLE_EXTENSION_NAME} Coyote libstf parcore oasis ${FREGEX_SHARED_LIB})

install(
    TARGETS ${EXTENSION_NAME}
    EXPORT "${DUCKDB_EXPORT_SET}"
    LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
    ARCHIVE DESTINATION "${INSTALL_LIB_DIR}"
)
