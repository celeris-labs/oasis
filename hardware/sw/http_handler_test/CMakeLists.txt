cmake_minimum_required(VERSION 3.16)
project(http_handler_test)

find_package(Coyote REQUIRED)
find_package(Boost REQUIRED COMPONENTS program_options)

add_executable(http_handler_test main.cpp)
target_link_libraries(http_handler_test PUBLIC Coyote Boost::program_options)

# Prefer oasis .local over a stale $HOME/opt via LD_LIBRARY_PATH.
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,--disable-new-dtags")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,--disable-new-dtags")
set_target_properties(http_handler_test PROPERTIES
  BUILD_RPATH "/scratch/jkreissl/oasis/.local/lib;$ENV{HOME}/opt/lib"
  INSTALL_RPATH "/scratch/jkreissl/oasis/.local/lib;$ENV{HOME}/opt/lib"
  LINK_FLAGS "-Wl,--disable-new-dtags"
)
