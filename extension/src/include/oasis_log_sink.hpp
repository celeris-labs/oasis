#pragma once

#include "duckdb/main/database.hpp"
#include "libstf/logging.hpp"

// Coyote's <syslog.h> (pulled in transitively via oasis_context.hpp) defines LOG_DEBUG /
// LOG_INFO / LOG_WARNING as numeric macros that collide with the duckdb::LogLevel enum
// values used in logger.hpp, turning e.g. `LogLevel::LOG_WARNING` into `LogLevel::4`.
// #undef them before including the logger so the LogLevel:: use sites below compile (see
// the matching workaround at the top of oasis_scan.cpp).
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
#include "duckdb/logging/logger.hpp"

namespace duckdb {

inline LogLevel LibstfToDuckDBLogLevel(libstf::LogLevel level) {
	switch (level) {
	case libstf::LogLevel::TRACE:
		return LogLevel::LOG_TRACE;
	case libstf::LogLevel::DEBUG:
		return LogLevel::LOG_DEBUG;
	case libstf::LogLevel::INFO:
		return LogLevel::LOG_INFO;
	case libstf::LogLevel::WARNING:
		return LogLevel::LOG_WARNING;
	case libstf::LogLevel::ERROR:
		return LogLevel::LOG_ERROR;
	case libstf::LogLevel::FATAL:
	case libstf::LogLevel::OFF:
		return LogLevel::LOG_FATAL;
	}
	return LogLevel::LOG_INFO;
}

inline libstf::LogLevel ParseLibstfLogLevel(const string &name) {
	auto upper = StringUtil::Upper(name);
	if (upper == "TRACE") {
		return libstf::LogLevel::TRACE;
	}
	if (upper == "DEBUG") {
		return libstf::LogLevel::DEBUG;
	}
	if (upper == "INFO") {
		return libstf::LogLevel::INFO;
	}
	if (upper == "WARNING") {
		return libstf::LogLevel::WARNING;
	}
	if (upper == "ERROR") {
		return libstf::LogLevel::ERROR;
	}
	if (upper == "FATAL") {
		return libstf::LogLevel::FATAL;
	}
	if (upper == "OFF") {
		return libstf::LogLevel::OFF;
	}
	throw InvalidInputException("Unknown oasis_log_level '%s'. Expected one of "
	                            "TRACE, DEBUG, INFO, WARNING, ERROR, FATAL, OFF",
	                            name);
}

class OasisLogSink : public libstf::LogSink {
public:
	explicit OasisLogSink(DatabaseInstance &db) : db(db) {
	}

	void log(libstf::LogLevel level, const std::string &message) override {
		DUCKDB_LOG_INTERNAL(db, DefaultLogType::NAME, LibstfToDuckDBLogLevel(level), message);
	}

private:
	DatabaseInstance &db;
};

} // namespace duckdb
