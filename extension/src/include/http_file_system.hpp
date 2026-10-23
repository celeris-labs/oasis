#pragma once

#include "duckdb.hpp"
#include "duckdb/common/file_system.hpp"

#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>

namespace duckdb {

class FileOpener;
class OasisHTTPFileHandle;

// The httpfpga_debug setting. Turns on the host-socket trace of this file system and liboasis's
// FPGA request trace (oasis::set_http_debug).
void SetHttpFpgaDebug(ClientContext &context, SetScope scope, Value &parameter);

// A reply read off a host socket. `raw` owns the bytes; the rest index into it.
struct HttpReply {
	string raw;
	string status_line;
	string headers;       // header block, excluding the terminating blank line
	size_t body_off = 0;  // index of the first body byte in `raw`
	bool partial = false; // 206 Partial Content rather than 200 OK
};

// httpfpga:// objects on the server named by the http_server / http_port settings. read_oasis has the
// FPGA fetch column chunks itself (HTTPBatchSourceOperator); every raw byte read through this file
// system (the Parquet footer, the CPU-decoded columns) goes over an ordinary host socket.
//
// Prefixed because DuckDB's httpfs declares HTTPFileSystem and HTTPFileHandle in the same namespace,
// and tpch_demo.sh's CPU baseline links both into one binary.
class OasisHTTPFileSystem : public FileSystem {
public:
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
	void ReadBuffered(OasisHTTPFileHandle &h, void *dst, size_t size, uint64_t location);
	// One ranged GET of the resource path `path` over a host socket into `dst`.
	void HTTPReadRange(const string &path, uint64_t offset, size_t size, void *dst);
	// The object's Content-Length, from at most one HEAD per path for the session.
	uint64_t CachedContentLength(const string &resource_path);
	// Sends `request` on a new connection and reads the reply until the server closes it. Throws on a
	// socket error, a malformed reply or a status other than 200/206; `what` names the request.
	HttpReply HttpExchange(const string &request, const char *what, const string &resource);

	std::mutex init_mtx;
	bool initialized = false;
	std::string server_host_;
	uint32_t server_ip_ = 0;
	uint16_t server_port_ = 0;

	// DuckDB opens an object several times per query (bind, glob, each worker's reader), so the size
	// is cached per path. Objects are assumed immutable for the session.
	std::mutex size_cache_mtx_;
	std::unordered_map<std::string, uint64_t> size_cache_;
};

// `path` is the resource path ("/bucket/object.parquet"), which is what a GET line takes, so read_oasis
// hands it to HTTPBatchSourceOperator unchanged. server_ip and server_port are taken at open time:
// read_oasis builds its source operators on worker threads.
class OasisHTTPFileHandle : public FileHandle {
public:
	OasisHTTPFileHandle(FileSystem &fs, string path, FileOpenFlags flags, uint32_t server_ip, uint16_t server_port)
	    : FileHandle(fs, std::move(path), flags), server_ip(server_ip), server_port(server_port) {
	}

	void Close() override {
	}

	uint64_t cursor = 0;
	uint64_t known_file_size = 0; // 0 until GetFileSize probed it
	uint32_t server_ip;
	uint16_t server_port;

	// Read-ahead buffer. DuckDB's ColumnReader walks a Parquet file in small steps (a page header is
	// about 256 bytes); without it every one of them would be its own GET and TCP connection. Reads
	// of at least the buffer size bypass it.
	static constexpr uint64_t READ_BUFFER_LEN = 1ULL << 20;
	duckdb::unique_ptr<data_t[]> read_buffer;
	uint64_t buffer_start = 0;
	uint64_t buffer_end = 0; // exclusive; equal to buffer_start when empty
};

} // namespace duckdb
