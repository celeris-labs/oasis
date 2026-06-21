cmake_minimum_required(VERSION 3.14)
project(oasis_rdma_server VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Boost REQUIRED COMPONENTS program_options)
find_package(Coyote REQUIRED)

add_executable(oasis_rdma_server src/main.cpp)

target_link_libraries(oasis_rdma_server PUBLIC Coyote Boost::program_options)
