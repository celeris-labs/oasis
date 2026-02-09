cmake_minimum_required(VERSION 3.16)
project(Oasis
  DESCRIPTION "Datalake-on-FPGA"
  VERSION 0.1.0
  LANGUAGES CXX
)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR) 
    add_subdirectory(../coyote/sw coyote)
else()
    if(NOT TARGET Coyote)
        message(FATAL_ERROR "When Oasis is a subproject, parent must provide Coyote")
    endif()
endif()
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR) 
    add_subdirectory(../libstf/software libstf)
else()
    if(NOT TARGET libstf)
        message(FATAL_ERROR "When Oasis is a subproject, parent must provide libstf")
    endif()
endif()
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR) 
    add_subdirectory(../parcore/software parcore)
else()
    if(NOT TARGET Parcore)
        message(FATAL_ERROR "When Oasis is a subproject, parent must provide Parcore")
    endif()
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(Oasis)
set_target_properties(Oasis PROPERTIES OUTPUT_NAME "oasis")

target_sources(Oasis PRIVATE
    oasis/configuration.cpp
    oasis/parcore/rdma_reader.cpp
)
target_include_directories(Oasis
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/oasis>
)


target_link_libraries(Oasis PRIVATE Coyote)
target_include_directories(Oasis PRIVATE ${COYOTE_INCLUDE_DIRS})
target_link_libraries(Oasis PRIVATE libstf)
target_include_directories(Oasis PRIVATE ${LIBSTF_INCLUDE_DIRS})
target_link_libraries(Oasis PUBLIC Parcore)
target_include_directories(Oasis PUBLIC ${PARCORE_INCLUDE_DIRS})

include(GNUInstallDirs)

# Install the library
install(TARGETS Oasis
    EXPORT OasisTargets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

# Install headers
install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/oasis
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/oasis
    FILES_MATCHING PATTERN "*.hpp"
)

# Export package configuration
install(EXPORT OasisTargets
    FILE OasisTargets.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/oasis
)

# Generate CMake package configuration files
include(CMakePackageConfigHelpers)
write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/OasisConfigVersion.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY AnyNewerVersion
)
