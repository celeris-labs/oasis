// Include DuckDB headers before any Coyote header: Coyote transitively pulls
// <syslog.h>, which defines LOG_INFO / LOG_DEBUG as preprocessor macros that
// collide with duckdb::LogLevel enum values inside DuckDB's logging headers.
#include "rdma_file_system.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/main/config.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"

#include <libstf/buffer.hpp>
#include <libstf/output_buffer_manager.hpp>
#include <libstf/output_handle.hpp>

#include <coyote/cThread.hpp>
#include <coyote/cDefs.hpp>

#include <algorithm>
#include <cstring>
#include <limits>
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

string GetStringSetting(DatabaseInstance &instance, const string &key, const string &fallback) {
	Value value;
	if (instance.TryGetCurrentSetting(key, value) && !value.IsNull()) {
		return value.ToString();
	}
	return fallback;
}

uint64_t GetUIntSetting(DatabaseInstance &instance, const string &key, uint64_t fallback) {
	Value value;
	if (instance.TryGetCurrentSetting(key, value) && !value.IsNull()) {
		return value.GetValue<uint64_t>();
	}
	return fallback;
}

} // namespace

RDMAFileSystem::RDMAFileSystem(DatabaseInstance &instance) : instance(instance) {
}

RDMAFileSystem::~RDMAFileSystem() = default;

bool RDMAFileSystem::CanHandleFile(const string &fpath) {
	return fpath.rfind(URL_PREFIX, 0) == 0;
}

void RDMAFileSystem::EnsureInitialized() {
	std::lock_guard<std::mutex> lock(init_mtx);
	if (initialized) {
		return;
	}

	auto &ctx = oasis::OasisContext::ctx();
	if (!ctx.isRDMAEnabled()) {
		throw IOException("rdma:// filesystem is unavailable: this FPGA shell was synthesized "
		                  "without an RDMA bypass stream (rebuild with RDMA enabled to use "
		                  "rdma:// paths)");
	}

	auto server = GetStringSetting(instance, "rdma_server", "127.0.0.1");
	auto port = static_cast<uint16_t>(GetUIntSetting(instance, "rdma_port", coyote::DEF_PORT));

	auto coyote_thread = ctx.cthread();
	if (!coyote_thread->initRDMA(RDMA_INIT_STUB_SIZE, port, server.c_str())) {
		coyote_thread.reset(); // Destroy cThread
		throw IOException("Coyote initRDMA failed for server %s:%u", server, port);
	}

	LoadDirectory();
	initialized = true;
}

void RDMAFileSystem::RDMAReadRange(uint64_t remote_offset, void *dst, size_t size) {
	if (size == 0) {
		return;
	}
	if (size > std::numeric_limits<uint32_t>::max()) {
		throw IOException("RDMA read size %llu exceeds 32-bit limit", (unsigned long long)size);
	}

	auto &ctx = oasis::OasisContext::ctx();
	auto obm = ctx.output_buffer_manager();
	auto rdma_cfg = ctx.config<oasis::RDMAReadConfig>();
	auto bypass_stream = ctx.rdmaBypassStream();

	// Serialize buffer-enqueue + CSR fire so the buffer at the front of the
	// OBM's per-stream FIFO always matches the read just triggered. The OBM
	// is internally thread-safe and `get_next_stream_output` is sequenced
	// correctly against interrupts, so we drop the lock before blocking.
	std::shared_ptr<libstf::OutputHandle> handle;
	{
		std::lock_guard<std::mutex> lock(mtx);

        // Trigger the remote read first because it has long latency.
		rdma_cfg->read(bypass_stream, static_cast<uintptr_t>(remote_offset), size);

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

void RDMAFileSystem::LoadDirectory() {
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
}

unique_ptr<FileHandle> RDMAFileSystem::OpenFile(const string &path, FileOpenFlags flags,
                                                optional_ptr<FileOpener> opener) {
	if (flags.OpenForWriting()) {
		throw IOException("rdma:// filesystem is read-only");
	}

	EnsureInitialized();

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
	if (HasGlob(path)) {
		throw NotImplementedException("RDMAFileSystem: glob patterns are not supported");
	}
	if (FileExists(path, opener)) {
		return {OpenFileInfo(path)};
	}
	return {};
}

bool RDMAFileSystem::FileExists(const string &filename, optional_ptr<FileOpener> opener) {
	if (!CanHandleFile(filename)) {
		return false;
	}
	try {
		EnsureInitialized();
	} catch (...) {
		return false;
	}
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

} // namespace duckdb
