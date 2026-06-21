# Extension updating 
When cloning this template, the target version of DuckDB should be the latest stable release of DuckDB. However, there 
will inevitably come a time when a new DuckDB is released and the extension repository needs updating. This process goes
as follows:

- Bump submodules
  - `./duckdb` should be set to latest tagged release
  - `./extension-ci-tools` should be set to updated branch corresponding to latest DuckDB release. So if you're building for DuckDB `v1.1.0` there will be a branch in `extension-ci-tools` named `v1.1.0` to which you should check out. 
- Bump versions in `./github/workflows`
  - `duckdb_version` input in `duckdb-stable-build` job in `MainDistributionPipeline.yml` should be set to latest tagged release
  - `duckdb_version` input in `duckdb-stable-deploy` job in `MainDistributionPipeline.yml` should be set to latest tagged release
  - the reusable workflow `duckdb/extension-ci-tools/.github/workflows/_extension_distribution.yml` for the `duckdb-stable-build` job should be set to latest tagged release

# Local DuckDB patches (re-apply on every submodule bump)

The oasis extension carries a small local patch to the pinned `./duckdb` submodule. Bumping the
submodule **resets the working tree to upstream and drops this patch** — you must re-apply it (or
rebase it onto the new tag) after every bump, or `read_oasis` will hang on its first BLOCKED return.

### Patch: let a plain table function block on async I/O

**Why:** `read_oasis` is an async source that must yield its DuckDB worker thread while the FPGA
decodes, then be rescheduled by an FPGA-completion thread calling `InterruptState::Callback()`.
Upstream DuckDB only lets the *in-out* function path return `BLOCKED`, and even there does not expose
the `InterruptState` (acknowledged limitation: duckdb/duckdb#18856). The in-out path is also
unusable for us because it bypasses projection/filter pushdown (the binder force-adds all columns).
So we keep `read_oasis` a **plain** table function and patch the plain path to support blocking.

**Files / changes** (search for the marker `OASIS PATCH`):
- `src/include/duckdb/function/table_function.hpp` — add two fields to `struct TableFunctionInput`:
  `optional_ptr<InterruptState> interrupt_state;` and `bool blocked = false;`.
- `src/execution/operator/scan/physical_table_scan.cpp` — in `GetDataInternal`, in the
  `if (function.function)` (plain) branch: set `data.interrupt_state = &input.interrupt_state;` before
  calling the function, and immediately after the call, `if (data.blocked) { auto guard =
  g_state.Lock(); return g_state.BlockSource(guard, input.interrupt_state); }`.

How our extension uses it: the scan arms a readiness callback on the FPGA result channels that calls
`InterruptState::Callback()`, sets `data.blocked = true`, and returns an empty chunk. The patched scan
registers the task as blocked instead of treating the empty chunk as EOF.

When upstream adds an equivalent mechanism, drop this patch and update `extension/src/oasis_scan.cpp`
to use the official fields.

# API changes
DuckDB extensions built with this extension template are built against the internal C++ API of DuckDB. This API is not guaranteed to be stable.
What this means for extension development is that when updating your extensions DuckDB target version using the above steps, you may run into the fact that your extension no longer builds properly.

Currently, DuckDB does not (yet) provide a specific change log for these API changes, but it is generally not too hard to figure out what has changed.

For figuring out how and why the C++ API changed, we recommend using the following resources:
- DuckDB's [Release Notes](https://github.com/duckdb/duckdb/releases)
- DuckDB's history of [Core extension patches](https://github.com/duckdb/duckdb/commits/main/.github/patches/extensions)
- The git history of the relevant C++ Header file of the API that has changed