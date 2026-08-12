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
# PIN THE COMMIT, NOT THE BRANCH. v1.5-variegata tracks the 1.5 line but keeps moving, and it has
# already moved past this duckdb: it failed to compile with
#     HTTPFSUtil::ShouldRetry(const BaseRequest&, const HTTPResponse&) marked 'override',
#     but does not override
# because the base class it derives from changed shape after v1.5.2 was cut.
#
# The commit below is what duckdb itself builds httpfs against for this version, copied verbatim from
# the submodule's own CI pin at duckdb/.github/config/extensions/httpfs.cmake. When the duckdb
# submodule moves, re-read that file rather than guessing a branch. openssl, httpfs's one real
# dependency, is already in vcpkg.json.
duckdb_extension_load(httpfs
    GIT_URL https://github.com/duckdb/duckdb-httpfs
    GIT_TAG 13e18b3c9f3810334f5972b76a3acc247b28e537
)