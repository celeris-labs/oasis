# This file is included by DuckDB's build system. It specifies which extension to load

# Extension from this repo
duckdb_extension_load(oasis
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)

# Any extra extensions that should be built
# e.g.: duckdb_extension_load(json)

# The CPU baseline for scripts/tpch_demo.sh: stock DuckDB reading the same objects from the same
# object store over plain HTTP, so that nothing we wrote sits inside the number we compare against.
#
# It has to be built HERE rather than installed from extensions.duckdb.org. This duckdb is one commit
# past the v1.5.2 tag (f1b9c90893, "Pass interrupt state to table function and add blocked field"),
# which oasis needs in order to yield a table function while the FPGA works. DuckDB therefore
# namespaces extensions by commit hash and looks for .duckdb/extensions/f1b9c90893/..., for which the
# repository has no build -- and the official v1.5.2 binary is not a safe substitute, because that
# commit ADDS FIELDS TO TableFunction. Loading a binary compiled against the old layout is a struct
# size mismatch, which corrupts memory rather than failing cleanly.
#
# v1.5-variegata is the branch tracking DuckDB 1.5.x. openssl, its one real dependency, is already in
# vcpkg.json.
duckdb_extension_load(httpfs
    GIT_URL https://github.com/duckdb/duckdb-httpfs
    GIT_TAG v1.5-variegata
)