# This file is included by DuckDB's build system. It specifies which extension to load

# Extension from this repo
duckdb_extension_load(oasis
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)

# Any extra extensions that should be built
# e.g.: duckdb_extension_load(json)

# The CPU baseline for scripts/tpch_demo.sh: stock DuckDB reading the same objects from the same
# object store over plain HTTP.
#
# Built here rather than installed from extensions.duckdb.org: this duckdb is one commit past v1.5.2
# (f1b9c90893, which oasis needs to yield a table function while the FPGA works) and adds fields to
# TableFunction, so no published binary matches its layout. The commit is pinned, not the
# v1.5-variegata branch, which no longer compiles against v1.5.2; it is duckdb's own CI pin
# (duckdb/.github/config/extensions/httpfs.cmake). openssl is already in vcpkg.json.
duckdb_extension_load(httpfs
    GIT_URL https://github.com/duckdb/duckdb-httpfs
    GIT_TAG 13e18b3c9f3810334f5972b76a3acc247b28e537
)