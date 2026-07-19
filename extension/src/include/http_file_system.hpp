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
	uint64_t ProbeContentLength(const string &resource_path);

	DatabaseInstance &instance;
	std::mutex init_mtx;
	std::mutex mtx;
	bool initialized = false;

	std::string server_host_;
	uint32_t server_ip_ = 0;
	uint16_t server_port_ = 0;
};

class HTTPFileHandle : public FileHandle {
public:
	HTTPFileHandle(FileSystem &fs, string path, FileOpenFlags flags, uint64_t file_size)
	    : FileHandle(fs, std::move(path), flags), cursor(0), known_file_size(file_size) {
	}

	void Close() override {
	}

	uint64_t cursor;
	uint64_t known_file_size;
};

} // namespace duckdb
