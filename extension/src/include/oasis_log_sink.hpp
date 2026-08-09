#pragma once

#include "duckdb/main/database.hpp"
#include "libstf/logging.hpp"

// Drops the <syslog.h> LOG_* macros that would otherwise mangle the LogLevel:: use sites below
// (and in TUs that include this header, e.g. oasis_scan.cpp). See syslog_undef.hpp for details.
#include "syslog_undef.hpp"

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
