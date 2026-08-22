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

# Defaults to the celeris submodule. Override to build against a working clone,
# e.g. -DCELERIS_SOFTWARE_DIR=/local/home/vifranz/celeris/software -- the wire
# format lives in celeris (celeris/operators/regex/regex_stream.hpp) and has to
# match the RTL the loaded bitstream was built from.
set(CELERIS_SOFTWARE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../celeris/software"
    CACHE PATH "Path to the celeris software tree")
set(CELERIS_REGEX_DIR "${CELERIS_SOFTWARE_DIR}/celeris/operators/regex")

# re2-parser's own headers include each other as "re2/...", so its root has to be
# on the include path -- celeris a39225a's re2-parser (d7b84c3) added
# re2/re2_compat.h, which regexp.h pulls in and which resolves nowhere without
# this. Not needed before that bump, hence its absence here.
set(CELERIS_RE2_PARSER_DIR "${CELERIS_REGEX_DIR}/re2-parser")

# Fail here with the reason rather than several files deep on a missing include.
# The build goes through DuckDB's extension wrapper, so the override has to be
# threaded through EXT_FLAGS:
#   make release EXT_FLAGS="-DCELERIS_SOFTWARE_DIR=/path/to/celeris/software"
if (NOT EXISTS "${CELERIS_REGEX_DIR}/regex_stream.hpp")
    message(FATAL_ERROR
        "CELERIS_SOFTWARE_DIR=${CELERIS_SOFTWARE_DIR} has no "
        "celeris/operators/regex/regex_stream.hpp.\n"
        "The regex FPGA path needs a celeris tree carrying the streaming wire "
        "format, and it must match the RTL the loaded bitstream was built from. "
        "Point it at your working clone:\n"
        "  make release EXT_FLAGS=\"-DCELERIS_SOFTWARE_DIR=<celeris>/software\"")
endif ()

set(FREGEX_BUILD_DIR "${CMAKE_BINARY_DIR}/fregex-build")
set(FREGEX_SHARED_LIB "${FREGEX_BUILD_DIR}/libfregex.so")


set(OASIS_REGEX_MAX_TOKENS 32 CACHE STRING "Predicate slots per engine; must equal the bitstream's CHAR_COUNT")
set(OASIS_REGEX_MAX_STATES 28 CACHE STRING "NFA states per engine; must equal the bitstream's STATE_COUNT")

include(ExternalProject)
ExternalProject_Add(oasis_fregex_ext
    SOURCE_DIR ${CELERIS_REGEX_DIR}
    BINARY_DIR ${FREGEX_BUILD_DIR}
    CMAKE_ARGS
        -DCMAKE_CXX_STANDARD=20
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        # nfa.cpp lives in here and instantiates RegexConfig<TOKENS,STATES>, which *is*
        # the config blob's bit layout -- so these must equal the flashed bitstream's
        # rem_top_ff CHAR_COUNT/STATE_COUNT or the card decodes a shifted, valid-looking
        # pattern and matches nothing. Passed explicitly because ExternalProject caches
        # its own CMakeCache: editing the celeris CMakeLists alone leaves a stale value
        # pinned here, which is exactly how this drifted to 12 against a 24-state build.
        -DREGEX_MAX_TOKENS=${OASIS_REGEX_MAX_TOKENS}
        -DREGEX_MAX_STATES=${OASIS_REGEX_MAX_STATES}
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
                      src/regex.cpp src/regex_fpga_batch.cpp src/regex_table.cpp src/regex_profile.cpp ${FPGA_REGEX_SOURCES})

build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

# celeris/generated carries regex_limits.h, the source of truth for the engine's
# token/state budget. regex_table.cpp reads it rather than restating the numbers:
# the limits changed with the bitstream (12 -> 32 tokens) and a local copy here
# silently kept rejecting patterns the card could handle.
set(CELERIS_GENERATED_DIR "${CELERIS_SOFTWARE_DIR}/../generated")

# The pattern budget must match the flashed bitstream's rem_top_ff CHAR_COUNT /
# STATE_COUNT, because nfa.cpp instantiates RegexConfig<REGEX_MAX_TOKENS,
# REGEX_MAX_STATES> and that template *is* the config blob's bit layout -- a
# mismatch silently shifts every field after state_pred, so the card decodes a
# valid-looking but wrong pattern and matches nothing (or everything).
#
# celeris/generated/regex_limits.h is a stale fallback (still 12 states); the
# celeris build sets these on the command line, so this target must too or it
# quietly picks up the header instead. build_hw_24 is CHAR_COUNT=32/STATE_COUNT=24.
foreach(_t ${EXTENSION_NAME} ${LOADABLE_EXTENSION_NAME})
    target_compile_definitions(${_t} PRIVATE
        REGEX_MAX_TOKENS=${OASIS_REGEX_MAX_TOKENS}
        REGEX_MAX_STATES=${OASIS_REGEX_MAX_STATES})
endforeach()

target_include_directories(${EXTENSION_NAME} BEFORE PRIVATE ${CELERIS_SOFTWARE_DIR} ${CELERIS_REGEX_DIR} ${CELERIS_RE2_PARSER_DIR} ${CELERIS_GENERATED_DIR} )
target_include_directories(${LOADABLE_EXTENSION_NAME} BEFORE PRIVATE ${CELERIS_SOFTWARE_DIR} ${CELERIS_REGEX_DIR} ${CELERIS_RE2_PARSER_DIR} ${CELERIS_GENERATED_DIR} )

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
