cmake_minimum_required(VERSION 3.16)
project(oasis
  DESCRIPTION "Library for data processing SmartNIC"
  VERSION 0.1.0
  LANGUAGES CXX
)

# Default to a Release build (optimized) unless the user specifies otherwise.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Choose the type of build." FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
        "Debug" "Release" "MinSizeRel" "RelWithDebInfo")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT TARGET Coyote)
    find_package(Coyote QUIET)
    if(NOT Coyote_FOUND)
        add_subdirectory(../parcore/libstf/coyote/sw coyote)
    endif()
endif()

if(NOT TARGET libstf)
    find_package(libstf QUIET)
    if(NOT libstf_FOUND)
        add_subdirectory(../parcore/libstf/software libstf)
    endif()
endif()

if(NOT TARGET parcore)
    find_package(parcore QUIET)
    if(NOT parcore_FOUND)
        add_subdirectory(../parcore/software parcore)
    endif()
endif()

add_library(oasis SHARED)

target_sources(oasis PRIVATE
    oasis/bypass_receiver.cpp
    oasis/configuration.cpp
    oasis/oasis_context.cpp
    oasis/operator.cpp
    oasis/scheduler.cpp
)
target_include_directories(oasis
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)

find_package(Threads REQUIRED)
target_link_libraries(oasis PRIVATE Coyote libstf parcore Threads::Threads)
target_include_directories(oasis PRIVATE ${COYOTE_INCLUDE_DIRS} ${LIBSTF_INCLUDE_DIRS} ${PARCORE_INCLUDE_DIRS})

include(GNUInstallDirs)

# Install the library
install(TARGETS oasis
    EXPORT oasisTargets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

# Install headers
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/oasis/"
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/oasis
    FILES_MATCHING PATTERN "*.hpp"
)

# Export package configuration
install(EXPORT oasisTargets
    FILE oasisTargets.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/oasis
)

# Generate CMake package configuration files
include(CMakePackageConfigHelpers)
configure_package_config_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/oasisConfig.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/oasisConfig.cmake
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/oasis
)
write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/oasisConfigVersion.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY AnyNewerVersion
)

install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/oasisConfig.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/oasisConfigVersion.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/oasis
)
