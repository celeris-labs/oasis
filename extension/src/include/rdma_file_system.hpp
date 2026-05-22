#pragma once

#include "duckdb/common/file_system.hpp"

#include <libstf/common.hpp>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace coyote {
class cThread;
} // namespace coyote

namespace duckdb {

class DatabaseInstance;

struct RDMADirEntry {
	uint64_t offset;
	uint64_t size;
};

class RDMAFileSystem : public FileSystem {
public:
	explicit RDMAFileSystem(DatabaseInstance &db);
	~RDMAFileSystem() override;

	static constexpr const char *URL_PREFIX = "rdma://";

	std::string GetName() const override {
		return "RDMAFileSystem";
	}

	bool CanHandleFile(const string &fpath) override;
	unique_ptr<FileHandle> OpenFile(const string &path, FileOpenFlags flags,
	                                optional_ptr<FileOpener> opener = nullptr) override;
	bool FileExists(const string &filename, optional_ptr<FileOpener> opener = nullptr) override;

	void Read(FileHandle &handle, void *buffer, int64_t nr_bytes, idx_t location) override;
	int64_t Read(FileHandle &handle, void *buffer, int64_t nr_bytes) override;
	void Seek(FileHandle &handle, idx_t location) override;
	idx_t SeekPosition(FileHandle &handle) override;
	int64_t GetFileSize(FileHandle &handle) override;

	bool CanSeek() override {
		return true;
	}
	bool OnDiskFile(FileHandle &handle) override {
		return false;
	}

private:
	void RDMAReadRange(uint64_t remote_offset, void *dst, size_t size);
	void EnsureInitialized();
	void LoadDirectory();

	DatabaseInstance &instance;

	// Guards first-time initialization and the `directory` map.
	std::mutex init_mtx;
	// Serializes the (enqueue buffer, fire CSR) pair inside RDMAReadRange so
	// the OBM's per-stream FIFO stays aligned with the order of HW reads.
	std::mutex mtx;
	bool initialized = false;

	std::unordered_map<std::string, RDMADirEntry> directory;
};

class RDMAFileHandle : public FileHandle {
public:
	RDMAFileHandle(FileSystem &fs, string path, FileOpenFlags flags, uint64_t remote_offset, uint64_t size)
	    : FileHandle(fs, std::move(path), flags), remote_offset(remote_offset), size(size), cursor(0) {
	}

	void Close() override {
	}

	uint64_t remote_offset;
	uint64_t size;
	uint64_t cursor;
};

} // namespace duckdb
