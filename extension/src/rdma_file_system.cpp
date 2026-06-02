// Coyote transitively pulls <syslog.h>, which defines LOG_INFO / LOG_DEBUG as
// preprocessor macros that collide with duckdb::LogLevel enum values. We include
// DuckDB headers first so the enum is declared cleanly, then #undef the syslog
// macros after the Coyote includes below so they don't corrupt LogLevel:: use
// sites in this file.
#include "rdma_file_system.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_opener.hpp"
#include "duckdb/function/scalar/string_common.hpp"
#include "duckdb/logging/logger.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/main/config.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"

#include <libstf/buffer.hpp>
#include <libstf/output_buffer_manager.hpp>
#include <libstf/output_handle.hpp>

#include <coyote/cThread.hpp>
#include <coyote/cDefs.hpp>

// <syslog.h> (pulled in by Coyote above) defines this as a numeric macros, which
// otherwise turns `LogLevel::LOG_DEBUG` into `LogLevel::7` below.
#undef LOG_INFO

#include <algorithm>
#include <cstring>
#include <limits>
#include <sstream>
#include <vector>

namespace duckdb {

namespace {

// Minimal stub region size for initRDMA — the file-system path no longer uses
// a host-side staging buffer (HW writes straight into caller buffers), but
// Coyote still requires a region to set up the QP.
constexpr uint32_t RDMA_INIT_STUB_SIZE = 4096;

template <typename T>
T ReadLE(const uint8_t *src) {
	T v;
	std::memcpy(&v, src, sizeof(T));
	return v;
}

} // namespace

RDMAParams RDMAParams::ReadFrom(optional_ptr<FileOpener> opener) {
	RDMAParams params;
	params.port = static_cast<uint16_t>(coyote::DEF_PORT);

	Value value;
	if (!FileOpener::TryGetCurrentSetting(opener, "rdma_server", value) || value.IsNull()) {
		throw InvalidConfigurationException("rdma:// filesystem requires the RDMA server ip address to be set: "
		                                    "Run `SET rdma_server = '<ip-address>';`");
	}
	params.server = value.ToString();

	if (FileOpener::TryGetCurrentSetting(opener, "rdma_port", value) && !value.IsNull()) {
		params.port = static_cast<uint16_t>(value.GetValue<uint64_t>());
	}
	return params;
}

RDMAFileSystem::RDMAFileSystem() = default;

RDMAFileSystem::~RDMAFileSystem() = default;

bool RDMAFileSystem::CanHandleFile(const string &fpath) {
	return fpath.rfind(URL_PREFIX, 0) == 0;
}

void RDMAFileSystem::EnsureInitialized(optional_ptr<FileOpener> opener) {
	std::lock_guard<std::mutex> lock(init_mtx);
	if (initialized) {
		return;
	}

	auto db = FileOpener::TryGetDatabase(opener);
	if (!db) {
		throw IOException("rdma:// filesystem requires a database context to initialize");
	}
	auto &ctx = db->GetObjectCache().GetOrCreate<OasisContextCacheEntry>("oasis_context")->ctx();
	if (!ctx.isRDMAEnabled()) {
		throw NotImplementedException("rdma:// filesystem is unavailable: This FPGA shell was "
		                              "synthesized without RDMA");
	}
    auto params = RDMAParams::ReadFrom(opener);

	auto coyote_thread = ctx.cthread();
	void *staging_buffer = nullptr;
	if (!ctx.memory_pool()->allocate(RDMA_INIT_STUB_SIZE, &staging_buffer).ok()) {
		throw IOException("Failed to allocate RDMA staging buffer of %u bytes", RDMA_INIT_STUB_SIZE);
	}
	if (!coyote_thread->initRDMA(RDMA_INIT_STUB_SIZE, params.port, params.server.c_str(), staging_buffer)) {
		throw IOException("Coyote initRDMA failed for server %s:%u", params.server, params.port);
	}

	LoadDirectory(opener);
	initialized = true;
}

void RDMAFileSystem::EnqueueRead(libstf::stream_t stream_id, uint64_t remote_offset, size_t size) {
	if (size == 0) {
		return;
	}
	if (size > std::numeric_limits<uint32_t>::max()) {
		throw IOException("RDMA read size %llu exceeds 32-bit limit", (unsigned long long)size);
	}

	auto &ctx = oasis::OasisContext::ctx();
	auto rdma_cfg = ctx.config<oasis::RDMAReadConfig>();
	rdma_cfg->read(stream_id, static_cast<uintptr_t>(remote_offset), size);
}

void RDMAFileSystem::RDMAReadRange(uint64_t remote_offset, void *dst, size_t size) {
	if (size == 0) {
		return;
	}

	// EnsureInitialized has already created the OasisContext singleton.
	auto &ctx = oasis::OasisContext::ctx();
	auto obm = ctx.output_buffer_manager();
	auto bypass_stream = ctx.rdmaBypassStream();

	// Serialize buffer-enqueue + CSR fire so the buffer at the front of the
	// OBM's per-stream FIFO always matches the read just triggered. The OBM
	// is internally thread-safe and `get_next_stream_output` is sequenced
	// correctly against interrupts, so we drop the lock before blocking.
	std::shared_ptr<libstf::OutputHandle> handle;
	{
		std::lock_guard<std::mutex> lock(mtx);

		// Trigger the remote read first because it has long latency.
		EnqueueRead(bypass_stream, remote_offset, size);

		// The bypass stream is configured as unmanaged on the OBM. Pass the exact
		// expected size so the OBM allocates a single right-sized buffer with
		// no speculative pre-allocation.
		handle = obm->acquire_output_handle(bypass_stream, size);
	}

	// Drain all buffers for this transfer. For sizes that fit in a single FPGA buffer this is
	// one iteration; for larger sizes the OBM chunks the transfer across multiple buffers, each
	// surfaced via its own interrupt.
	size_t copied = 0;
	while (handle->stream_has_more_output(bypass_stream)) {
		auto buf = handle->get_next_stream_output(bypass_stream);
		if (!buf) {
			break;
		}
		if (copied + buf->size > size) {
			throw IOException("RDMA read overran requested size: requested %llu, already got %llu, "
			                  "next chunk %llu",
			                  (unsigned long long)size, (unsigned long long)copied,
			                  (unsigned long long)buf->size);
		}
		std::memcpy(static_cast<uint8_t *>(dst) + copied, buf->ptr, buf->size);
		copied += buf->size;
	}
	if (copied != size) {
		throw IOException("RDMA read short transfer: requested %llu bytes, got %llu",
		                  (unsigned long long)size, (unsigned long long)copied);
	}
}

void RDMAFileSystem::LoadDirectory(optional_ptr<FileOpener> opener) {
	// Step 1: Fetch the directory header size.
	uint64_t dir_size = 0;
	RDMAReadRange(0, &dir_size, sizeof(dir_size));
	if (dir_size <= sizeof(uint64_t)) {
		return;
	}

	// Step 2: Read the full directory blob in a single transfer.
	std::vector<uint8_t> blob(dir_size);
	RDMAReadRange(0, blob.data(), blob.size());

	const uint8_t *p = blob.data() + sizeof(uint64_t);
	const uint8_t *end = blob.data() + blob.size();
	std::unordered_map<std::string, RDMADirEntry> parsed;
	while (p < end) {
		if (p + sizeof(uint64_t) > end) {
			throw IOException("Truncated RDMA directory entry (name_len)");
		}
		uint64_t name_len = ReadLE<uint64_t>(p);
		p += sizeof(uint64_t);
		if (p + name_len + 2 * sizeof(uint64_t) > end) {
			throw IOException("Truncated RDMA directory entry (name/offset/size)");
		}
		std::string name(reinterpret_cast<const char *>(p), name_len);
		p += name_len;
		uint64_t offset = ReadLE<uint64_t>(p);
		p += sizeof(uint64_t);
		uint64_t size = ReadLE<uint64_t>(p);
		p += sizeof(uint64_t);
		parsed.emplace(std::move(name), RDMADirEntry {offset, size});
	}
	directory = std::move(parsed);

	LogDirectory(opener, dir_size);
}

void RDMAFileSystem::LogDirectory(optional_ptr<FileOpener> opener, uint64_t dir_size) {
	if (!opener) {
		return;
	}

	// Skip building the (potentially large) listing entirely unless an INFO-level
	// log would actually be emitted.
	auto &logger = Logger::Get(*opener);
	if (!logger.ShouldLog(DefaultLogType::NAME, LogLevel::LOG_INFO)) {
		return;
	}

	std::vector<std::pair<std::string, RDMADirEntry>> entries(directory.begin(), directory.end());
	std::sort(entries.begin(), entries.end(),
	          [](const auto &a, const auto &b) { return a.first < b.first; });

	size_t max_name_len = 0;
	size_t max_offset_len = 0;
	for (const auto &entry : entries) {
		max_name_len = std::max(max_name_len, entry.first.size());
		max_offset_len = std::max(max_offset_len, std::to_string(entry.second.offset).size());
	}

	std::ostringstream out;
	out << "Loaded RDMA directory: " << entries.size() << " file(s), directory header " << dir_size << " Bytes";
	for (size_t i = 0; i < entries.size(); ++i) {
		const auto &name = entries[i].first;
		const auto &dir_entry = entries[i].second;
		std::string quoted = "\"" + name + "\"";
		out << "\n  [" << i << "] " << std::left << std::setw(static_cast<int>(max_name_len + 2)) << quoted
		    << " offset=" << std::right << std::setw(static_cast<int>(max_offset_len)) << dir_entry.offset
		    << " size=" << dir_entry.size;
	}

	logger.WriteLog(DefaultLogType::NAME, LogLevel::LOG_INFO, out.str());
}

unique_ptr<FileHandle> RDMAFileSystem::OpenFile(const string &path, FileOpenFlags flags,
                                                optional_ptr<FileOpener> opener) {
	if (flags.OpenForWriting()) {
		throw IOException("rdma:// filesystem is read-only");
	}

	EnsureInitialized(opener);

	auto name = path.substr(std::strlen(URL_PREFIX));
	auto it = directory.find(name);
	if (it == directory.end()) {
		if (flags.ReturnNullIfNotExists()) {
			return nullptr;
		}
		throw IOException("File '%s' not found in RDMA directory", path);
	}
	return make_uniq<RDMAFileHandle>(*this, path, flags, it->second.offset, it->second.size);
}

vector<OpenFileInfo> RDMAFileSystem::Glob(const string &path, FileOpener *opener) {
	if (!HasGlob(path)) {
		if (FileExists(path, opener)) {
			return {OpenFileInfo(path)};
		}
		return {};
	}

	EnsureInitialized(opener);

	// Strip the rdma:// prefix to get the filename pattern.
	auto pattern = path.substr(std::strlen(URL_PREFIX));

	vector<OpenFileInfo> result;
	for (auto &entry : directory) {
		const auto &name = entry.first;
		if (duckdb::Glob(name.c_str(), name.size(), pattern.c_str(), pattern.size())) {
			result.emplace_back(string(URL_PREFIX) + name);
		}
	}
	std::sort(result.begin(), result.end());
	return result;
}

bool RDMAFileSystem::FileExists(const string &filename, optional_ptr<FileOpener> opener) {
	if (!CanHandleFile(filename)) {
		return false;
	}

    EnsureInitialized(opener);

	auto name = filename.substr(std::strlen(URL_PREFIX));
	return directory.find(name) != directory.end();
}

void RDMAFileSystem::Read(FileHandle &handle, void *buffer, int64_t nr_bytes, idx_t location) {
	auto &h = handle.Cast<RDMAFileHandle>();
	if (nr_bytes < 0) {
		throw IOException("Negative read size on %s", handle.path);
	}
	if (location + static_cast<uint64_t>(nr_bytes) > h.size) {
		throw IOException("Read past end of file %s", handle.path);
	}
	RDMAReadRange(h.remote_offset + location, buffer, static_cast<size_t>(nr_bytes));
}

int64_t RDMAFileSystem::Read(FileHandle &handle, void *buffer, int64_t nr_bytes) {
	auto &h = handle.Cast<RDMAFileHandle>();
	if (nr_bytes < 0) {
		throw IOException("Negative read size on %s", handle.path);
	}
	if (h.cursor >= h.size) {
		return 0;
	}
	auto remaining = h.size - h.cursor;
	auto to_read = std::min<uint64_t>(static_cast<uint64_t>(nr_bytes), remaining);
	RDMAReadRange(h.remote_offset + h.cursor, buffer, static_cast<size_t>(to_read));
	h.cursor += to_read;
	return static_cast<int64_t>(to_read);
}

void RDMAFileSystem::Seek(FileHandle &handle, idx_t location) {
	auto &h = handle.Cast<RDMAFileHandle>();
	if (location > h.size) {
		throw IOException("Seek past end of file %s", handle.path);
	}
	h.cursor = location;
}

idx_t RDMAFileSystem::SeekPosition(FileHandle &handle) {
	return handle.Cast<RDMAFileHandle>().cursor;
}

int64_t RDMAFileSystem::GetFileSize(FileHandle &handle) {
	return static_cast<int64_t>(handle.Cast<RDMAFileHandle>().size);
}

timestamp_t RDMAFileSystem::GetLastModifiedTime(FileHandle &handle) {
	// The RDMA server data is immutable so just return 0.
	return timestamp_t(0);
}

void RDMAFileHandle::ReadIntoStream(libstf::stream_t stream_id, uint64_t offset, size_t size) {
	if (offset + size > this->size) {
		throw IOException("Read past end of file %s", path);
	}
	RDMAFileSystem::EnqueueRead(stream_id, remote_offset + offset, size);
}

} // namespace duckdb
