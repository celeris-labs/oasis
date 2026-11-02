# This file is included by DuckDB's build system. It specifies which extension to load

duckdb_extension_load(oasis_sw
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)

# DuckDB's own Parquet reader does the decoding.
duckdb_extension_load(parquet)

# DuckDB >= 2.0 only links extensions into the shell/library when explicitly requested
if(COMMAND duckdb_extension_statically_link)
    duckdb_extension_statically_link(oasis_sw)
    duckdb_extension_statically_link(parquet)
endif()
