#pragma once

#include "duckdb/common/file_system.hpp"

#include <cstdint>
#include <mutex>
#include <string>

namespace duckdb {

class DatabaseInstance;
class FileOpener;

class HTTPFileSystem : public FileSystem {
public:
	explicit HTTPFileSystem(DatabaseInstance &db);
	~HTTPFileSystem() override;

	static constexpr const char *URL_PREFIX = "httpfpga://";

	std::string GetName() const override {
		return "HTTPFileSystem";
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
	// CPU fallback: fetch the range over an ordinary host socket, bypassing the FPGA entirely.
	// Enabled with `SET httpfpga_cpu_fallback = true;`. Reliable but does not exercise the FPGA
	// data path — a scaffolding aid while the HW receive path is validated.
	void HTTPReadRangeCpu(const string &path, uint64_t offset, size_t size, void *dst);
	uint64_t ProbeContentLength(const string &resource_path);
	// Connect to the configured server, send `request`, read the full response until the peer
	// closes. Returns false on any socket error.
	bool HttpSocketRequest(const std::string &request, std::string &response);

	DatabaseInstance &instance;
	std::mutex init_mtx;
	std::mutex mtx;
	bool initialized = false;

	std::string server_host_;
	uint32_t server_ip_ = 0;
	uint16_t server_port_ = 0;
};

// `path` is the resource path only ("/bucket/object.parquet"), already normalized — that is exactly
// what the GET line needs, so read_oasis can hand it to HTTPSourceOperator unchanged.
//
// server_ip / server_port are snapshotted at open time rather than read from the filesystem on
// demand: read_oasis builds its source operators on DuckDB worker threads, and the settings behind
// those fields are only resolved under the filesystem's init lock.
class HTTPFileHandle : public FileHandle {
public:
	HTTPFileHandle(FileSystem &fs, string path, FileOpenFlags flags, uint64_t file_size, uint32_t server_ip,
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
};

} // namespace duckdb
