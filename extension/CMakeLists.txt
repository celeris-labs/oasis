cmake_minimum_required(VERSION 3.16)

set(TARGET_NAME maximus)

# DuckDB's extension distribution supports vcpkg. Dependencies are specified in ./vcpkg.json.
find_package(OpenSSL REQUIRED)

set(EXTENSION_NAME ${TARGET_NAME}_extension)
set(LOADABLE_EXTENSION_NAME ${TARGET_NAME}_loadable_extension)

project(${TARGET_NAME})
include_directories(src/include)

# ---------------------------------------------------------------------------
# Parcore dependency stack
# ---------------------------------------------------------------------------
# jemalloc is expected at ~/opt (installed via parcore/libstf/scripts/install_jemalloc.sh).
# libstf's FindJemalloc.cmake needs it on CMAKE_PREFIX_PATH.
list(APPEND CMAKE_PREFIX_PATH "$ENV{HOME}/opt")
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/libstf/software/cmake")

# Block install(EXPORT ...) commands from parcore subdirectories so the targets
# can be added to DuckDB's single export set without conflicts.
set(_PARCORE_BLOCKED_EXPORTS "CoyoteTargets;libstfTargets;ParcoreTargets")
macro(install)
    set(_parcore_skip FALSE)
    foreach(_arg ${ARGN})
        if("${_arg}" IN_LIST _PARCORE_BLOCKED_EXPORTS)
            set(_parcore_skip TRUE)
            break()
        endif()
    endforeach()
    if(NOT _parcore_skip)
        _install(${ARGN})
    endif()
endmacro()

# 1. Coyote  (needs Boost, Threads)
# Both parcore/coyote/sw and parcore/coyote/sim/sw declare a target named
# "Coyote" — the former opens a real FPGA char device, the latter spawns
# Vivado xsim in the background and pipes to it. Swap the subdirectory to
# switch between real hardware and simulation; everything downstream
# (libstf, Parcore) links to "Coyote" without caring which one it got.
#
# For simulation you also need:
#   * parcore/build_hw/sim/ populated (run parcore/sim_setup.sh once)
#   * xsim on PATH
#   * COYOTE_SIM_DIR=<abs path to parcore/build_hw> at runtime
option(MAXIMUS_SIM "Link against Coyote simulation library (no FPGA required)" OFF)
if(MAXIMUS_SIM)
    add_subdirectory(parcore/coyote/sim/sw coyote_build EXCLUDE_FROM_ALL)
else()
    add_subdirectory(parcore/coyote/sw coyote_build EXCLUDE_FROM_ALL)
endif()

# 2. libstf  (needs Coyote + jemalloc) — hoisted to top-level submodule so we
# can pin a newer version than parcore's pinned commit.
add_subdirectory(libstf/software libstf_build EXCLUDE_FROM_ALL)

# 3. Arrow (from vcpkg — installed as static, but parcore expects Arrow::arrow_shared)
find_package(Arrow CONFIG REQUIRED)
if(NOT TARGET Arrow::arrow_shared AND TARGET Arrow::arrow_static)
    add_library(Arrow::arrow_shared INTERFACE IMPORTED)
    target_link_libraries(Arrow::arrow_shared INTERFACE Arrow::arrow_static)
endif()

# 4. Parcore (needs Coyote + libstf + Arrow)
set(PARCORE_INCLUDE_CPU OFF CACHE BOOL "Disable CPU-side Parquet reader in parcore" FORCE)
add_subdirectory(parcore/software parcore_build EXCLUDE_FROM_ALL)

# ---------------------------------------------------------------------------
# Extension
# ---------------------------------------------------------------------------
set(EXTENSION_SOURCES src/maximus_extension.cpp)

build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

# Parcore and its dependencies (Arrow, libstf) require C++17.
set_target_properties(${EXTENSION_NAME} PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
set_target_properties(${LOADABLE_EXTENSION_NAME} PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)

# Parcore links libstf/Coyote as PRIVATE, so their PUBLIC include dirs don't
# propagate through Parcore alone. Link libstf and Coyote directly here so
# the extension picks up their PUBLIC include dirs — libstf's PUBLIC include
# dirs notably carry the jemalloc path, which libstf's memory_pool.hpp needs.
target_link_libraries(${EXTENSION_NAME} OpenSSL::SSL OpenSSL::Crypto Parcore libstf Coyote)
target_link_libraries(${LOADABLE_EXTENSION_NAME} OpenSSL::SSL OpenSSL::Crypto Parcore libstf Coyote)

install(
  TARGETS ${EXTENSION_NAME} Parcore Coyote libstf
  EXPORT "${DUCKDB_EXPORT_SET}"
  LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
  ARCHIVE DESTINATION "${INSTALL_LIB_DIR}")
