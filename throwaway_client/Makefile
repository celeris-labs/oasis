PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Configuration of extension
EXT_NAME=oasis_sw
EXT_CONFIG=${PROJ_DIR}extension_config.cmake

# DuckDB and the CI tools are the extension's submodules, so both builds use the same commit.
DUCKDB_SRCDIR := ${PROJ_DIR}../extension/duckdb/

# Include the Makefile from extension-ci-tools
include ${PROJ_DIR}../extension/extension-ci-tools/makefiles/duckdb_extension.Makefile
