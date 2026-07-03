cmake_minimum_required(VERSION 3.14)
project(oasis_rdma_server VERSION 0.1.0 LANGUAGES CXX)

# Default to a Release build (optimized) unless the user specifies otherwise.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Choose the type of build." FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
        "Debug" "Release" "MinSizeRel" "RelWithDebInfo")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Boost REQUIRED COMPONENTS program_options)

find_library(IBVERBS_LIBRARY NAMES ibverbs REQUIRED)
find_path(IBVERBS_INCLUDE_DIR NAMES infiniband/verbs.h REQUIRED)

add_executable(oasis_rdma_server src/main.cpp)

target_include_directories(oasis_rdma_server PRIVATE ${IBVERBS_INCLUDE_DIR})
target_link_libraries(oasis_rdma_server PUBLIC ${IBVERBS_LIBRARY} Boost::program_options)
