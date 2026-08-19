#pragma once

#include "duckdb/common/file_system.hpp"

#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>

namespace duckdb {

class DatabaseInstance;
class OasisHTTPFileHandle; // defined below; ReadBuffered takes it by reference
class FileOpener;

// A reply read off a host socket. `raw` owns the bytes; the rest index into it.
struct HttpReply {
	string raw;
	string status_line;
	string headers;       // header block, excluding the terminating blank line
	size_t body_off = 0;  // index of the first body byte in `raw`
	bool partial = false; // 206 Partial Content rather than 200 OK
};

// NAMED WITH THE PREFIX ON PURPOSE. DuckDB's own httpfs extension declares duckdb::HTTPFileSystem
// and duckdb::HTTPFileHandle, and scripts/tpch_demo.sh now links httpfs into the same binary to use
// it as the CPU baseline. Sharing the unqualified names produced a wall of "multiple definition of
// duckdb::HTTPFileSystem::Read" at link time. Anything added here that mirrors a stock httpfs type
// needs the prefix too.
class OasisHTTPFileSystem : public FileSystem {
public:
	explicit OasisHTTPFileSystem(DatabaseInstance &db);
	~OasisHTTPFileSystem() override;

	static constexpr const char *URL_PREFIX = "httpfpga://";

	std::string GetName() const override {
		return "OasisHTTPFileSystem";
	}

	bool CanHandleFile(const string &fpath) override;
	unique_ptr<FileHandle> OpenFile(const string &path, FileOpenFlags flags,
	                                optional_ptr<FileOpener> opener = nullptr) override;
	bool FileExists(const string &filename, optional_ptr<FileOpener> opener = nullptr) override;
	vector<OpenFileInfo> Glob(const string &path, FileOpener *opener = nullptr) override;

	void Read(FileHandle &handle, void *buffer, int64_t nr_bytes, idx_t location) override;
	int64_t Read(FileHandle &handle, void *buffer, int64_t nr_bytes) override;
	void Seek(FileHandle &handle, idx_t location) override;
	idx_t SeekPosition(FileHandle &handle) override;
	int64_t GetFileSize(FileHandle &handle) override;
	timestamp_t GetLastModifiedTime(FileHandle &handle) override;
	bool CanSeek() override {
		return true;
	}
	bool OnDiskFile(FileHandle &handle) override {
		return false;
	}

private:
	void EnsureInitialized(optional_ptr<FileOpener> opener);
	void HTTPReadRange(const string &path, uint64_t offset, size_t size, void *dst);
	void ReadBuffered(OasisHTTPFileHandle &h, void *dst, size_t size, uint64_t location);
	// CPU fallback: fetch the range over an ordinary host socket, bypassing the FPGA entirely.
	// Enabled with `SET httpfpga_cpu_fallback = true;`. Reliable but does not exercise the FPGA
	// data path — a scaffolding aid while the HW receive path is validated.
	void HTTPReadRangeCpu(const string &path, uint64_t offset, size_t size, void *dst);
	uint64_t ProbeContentLength(const string &resource_path);
	// Connect to the configured server, send `request`, read the full response until the peer
	// closes. Returns false on any socket error.
	bool HttpSocketRequest(const std::string &request, std::string &response);
	// HttpSocketRequest plus response parsing. Throws on a transport error, a malformed reply, or a
	// status other than 200/206; `what` names the operation in those messages.
	HttpReply HttpExchange(const string &request, const char *what, const string &resource);

	DatabaseInstance &instance;
	std::mutex init_mtx;
	std::mutex mtx;
	bool initialized = false;

	std::string server_host_;
	uint32_t server_ip_ = 0;
	uint16_t server_port_ = 0;

	// Content-Length cache, keyed by resource path. DuckDB opens the same object several times per
	// query (bind, glob, per-worker reader init), and GetFileSize probes with a HEAD whenever the
	// handle reports 0. Caching on the handle meant every reopen paid another round trip -- about
	// six HEADs for one scan. Keyed on the path here instead, so it is one per object per session.
	// Objects are assumed immutable for the session's lifetime, which is already assumed elsewhere:
	// the Parquet footer is read once at bind and reused for every row group.
	std::mutex size_cache_mtx_;
	std::unordered_map<std::string, uint64_t> size_cache_;

	uint64_t CachedContentLength(const string &resource_path);
};

// `path` is the resource path only ("/bucket/object.parquet"), already normalized — that is exactly
// what the GET line needs, so read_oasis can hand it to HTTPSourceOperator unchanged.
//
// server_ip / server_port are snapshotted at open time rather than read from the filesystem on
// demand: read_oasis builds its source operators on DuckDB worker threads, and the settings behind
// those fields are only resolved under the filesystem's init lock.
class OasisHTTPFileHandle : public FileHandle {
public:
	OasisHTTPFileHandle(FileSystem &fs, string path, FileOpenFlags flags, uint64_t file_size, uint32_t server_ip,
	               uint16_t server_port)
	    : FileHandle(fs, std::move(path), flags), cursor(0), known_file_size(file_size), server_ip(server_ip),
	      server_port(server_port) {
	}

	void Close() override {
	}

	uint64_t cursor;
	uint64_t known_file_size;
	uint32_t server_ip;
	uint16_t server_port;

	// Read-ahead cache. DuckDB's ColumnReader walks a Parquet file in very small steps -- a page
	// header is ~256 bytes -- and without a buffer every one of those became its own HTTP request
	// AND its own TCP connection (HTTPReadRangeCpu sends Connection: close). Observed on the wire:
	// a full SYN / SYN-ACK / GET / 206 / FIN / FIN-ACK exchange to move 256 bytes, repeated for
	// every page of every BYTE_ARRAY column. DuckDB's own HTTPFileHandle buffers for this reason.
	//
	// Reads larger than the buffer bypass it entirely and stream straight into the caller.
	static constexpr uint64_t READ_BUFFER_LEN = 1ULL << 20; // 1 MiB
	duckdb::unique_ptr<data_t[]> read_buffer;
	uint64_t buffer_start = 0;
	uint64_t buffer_end = 0; // exclusive; buffer_end == buffer_start means empty
};

} // namespace duckdb
