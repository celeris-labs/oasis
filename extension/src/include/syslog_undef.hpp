#pragma once

// Coyote's cThread.hpp pulls in <syslog.h> (only in EN_SIMULATION builds, where the simulation
// cThread.hpp includes it), which defines LOG_DEBUG / LOG_INFO / LOG_WARNING as numeric macros.
// Those collide with the duckdb::LogLevel enumerators, turning e.g. `LogLevel::LOG_WARNING` into
// `LogLevel::4` in any DuckDB header parsed afterwards. Include this immediately after any celeris
// or coyote header and before the DuckDB headers of the same TU.
// The #ifdef guards make this a no-op for real-FPGA builds where syslog.h is never pulled in.
#ifdef LOG_TRACE
#undef LOG_TRACE
#endif
#ifdef LOG_DEBUG
#undef LOG_DEBUG
#endif
#ifdef LOG_INFO
#undef LOG_INFO
#endif
#ifdef LOG_WARNING
#undef LOG_WARNING
#endif
#ifdef LOG_ERROR
#undef LOG_ERROR
#endif
#ifdef LOG_FATAL
#undef LOG_FATAL
#endif
