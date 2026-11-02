cmake_minimum_required(VERSION 3.16)

set(TARGET_NAME oasis_sw)

set(EXTENSION_NAME ${TARGET_NAME}_extension)
set(LOADABLE_EXTENSION_NAME ${TARGET_NAME}_loadable_extension)

project(${TARGET_NAME})

# https://github.com/duckdb/duckdb/issues/22097
set(CMAKE_CXX_STANDARD 17 CACHE STRING "C++ standard to enforce" FORCE)
set(CMAKE_CXX_STANDARD_REQUIRED True)

find_library(IBVERBS_LIBRARY NAMES ibverbs REQUIRED)
find_path(IBVERBS_INCLUDE_DIR NAMES infiniband/verbs.h REQUIRED)

include_directories(src/include)
include_directories(${IBVERBS_INCLUDE_DIR})
include_directories(../rdma_server/src)

set(EXTENSION_SOURCES src/oasis_sw_extension.cpp src/s3_rdma_client.cpp)

build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

target_link_libraries(${EXTENSION_NAME} ${IBVERBS_LIBRARY})
target_link_libraries(${LOADABLE_EXTENSION_NAME} ${IBVERBS_LIBRARY})

install(
    TARGETS ${EXTENSION_NAME}
    EXPORT "${DUCKDB_EXPORT_SET}"
    LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
    ARCHIVE DESTINATION "${INSTALL_LIB_DIR}"
)
