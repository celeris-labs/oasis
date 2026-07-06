#pragma once

// Caliper region instrumentation is dev-only profiling. Caliper maintains a per-thread region
// blackboard that is not safe under DuckDB's multi-threaded pipeline execution: once more than a
// couple of worker threads run an instrumented table function concurrently, cali_end_region()
// segfaults regardless of CALI_CONFIG. Compile the markers out by default so parallel scans are
// safe, and enable real Caliper only for (single-threaded) profiling builds via
// -DOASIS_ENABLE_PROFILING.
#ifdef OASIS_ENABLE_PROFILING

#include <caliper/cali.h>
#include <caliper/cali_macros.h>

#else

#define CALI_CXX_MARK_FUNCTION ((void)0)
#define CALI_MARK_BEGIN(name) ((void)0)
#define CALI_MARK_END(name) ((void)0)

#endif
