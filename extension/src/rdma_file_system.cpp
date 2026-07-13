#include "rdma_file_system.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_opener.hpp"
#include "duckdb/function/scalar/string_common.hpp"
#include "duckdb/logging/logger.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/main/config.hpp"

#include "oasis_context_cache_entry.hpp"

#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis/operator.hpp"
#include "oasis/query_splinter.hpp"
#include "oasis/scheduler.hpp"

#include <libstf/buffer.hpp>
#include <libstf/common.hpp>

#include <coyote/cThread.hpp>
#include <coyote/cDefs.hpp>

#include <algorithm>
#include <cstring>
#include <sstream>
#include <vector>

namespace duckdb {

namespace {

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
	if (!FileOpener::TryGetCurrentSetting(opener, "oasis_rdma_server", value) || value.IsNull()) {
		throw InvalidConfigurationException("rdma:// filesystem requires the RDMA server ip address to be set: "
		                                    "Run `SET oasis_rdma_server = '<ip-address>';`");
	}
	params.server = value.ToString();

	if (FileOpener::TryGetCurrentSetting(opener, "oasis_rdma_port", value) && !value.IsNull()) {
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
	auto &ctx = db->GetObjectCache().GetOrCreate<OasisContextCacheEntry>("oasis_context", *db)->ctx();
	if (!ctx.isRDMAEnabled()) {
		throw NotImplementedException("rdma:// filesystem is unavailable: This FPGA shell was "
		                              "synthesized without RDMA");
	}
	auto params = RDMAParams::ReadFrom(opener);

	ctx.initRDMA(params.server, params.port);

	LoadDirectory(opener);
	initialized = true;
}

void RDMAFileSystem::RDMAReadRange(uint64_t remote_offset, void *dst, size_t size) {
	if (size == 0) {
		return;
	}

	// EnsureInitialized has already created the OasisContext singleton.
	auto &ctx = oasis::OasisContext::ctx();

	// One raw flow on the bypass stream: an RDMA source writing directly into one sink buffer per
	// FPGA output-buffer-sized chunk. The scheduler capability-matches it onto the bypass stream.
	oasis::OperatorFlow flow;
	flow.push_back(std::make_unique<oasis::RDMASourceOperator>(remote_offset, size));
	size_t remaining = size;
	while (remaining > 0) {
		size_t chunk = std::min<size_t>(remaining, libstf::MAXIMUM_OUTPUT_WRITER_BUFFER_SIZE);
		flow.push_back(std::make_unique<oasis::LocalSinkOperator>(ctx.allocate_output_buffer(chunk)));
		remaining -= chunk;
	}
	oasis::QuerySplinter splinter;
	splinter.streams.push_back(std::move(flow));
	auto handle = ctx.scheduler().submit(std::move(splinter));

	// Drain the flow's batches. The bypass stream completes its sinks in enqueue order, so the
	// batches arrive in file order and can be copied out sequentially.
	size_t copied = 0;
	while (auto batch = handle.get_next_batch()) {
		const auto &buf = batch->buffer;
		if (copied + buf->size > size) {
			throw IOException("RDMA read overran requested size: requested %llu, already got %llu, "
			                  "next chunk %llu",
			                  (unsigned long long)size, (unsigned long long)copied, (unsigned long long)buf->size);
		}
		std::memcpy(static_cast<uint8_t *>(dst) + copied, buf->ptr, buf->size);
		copied += buf->size;
	}
	if (copied != size) {
		throw IOException("RDMA read short transfer: requested %llu bytes, got %llu", (unsigned long long)size,
		                  (unsigned long long)copied);
	}
}

void RDMAFileSystem::ReadWithStaging(RDMAFileHandle &handle, void *dst, size_t size, uint64_t location) {
	uint64_t pos = location;
	const uint64_t end = location + size;
	auto *out = static_cast<uint8_t *>(dst);

	auto range = handle.staged_ranges.begin();
	while (pos < end) {
		// Skip staged ranges that end at or before the read position (ranges are sorted by offset).
		while (range != handle.staged_ranges.end() && range->offset + range->size <= pos) {
			++range;
		}

		if (range != handle.staged_ranges.end() && range->offset <= pos) {
			// Covered: copy the overlap out of the staged buffers.
			uint64_t range_pos = pos - range->offset;
			const uint64_t n = std::min<uint64_t>(end, range->offset + range->size) - pos;
			uint64_t copied = 0;
			uint64_t buffer_begin = 0;
			for (const auto &buf : range->buffers) {
				const uint64_t buffer_end = buffer_begin + buf->size;
				if (copied < n && range_pos + copied < buffer_end) {
					const uint64_t offset_in_buffer = range_pos + copied - buffer_begin;
					const uint64_t take = std::min<uint64_t>(n - copied, buf->size - offset_in_buffer);
					std::memcpy(out + copied, static_cast<const uint8_t *>(buf->ptr) + offset_in_buffer, take);
					copied += take;
				}
				buffer_begin = buffer_end;
			}
			if (copied != n) {
				throw IOException("Staged RDMA range at offset %llu is missing bytes: wanted %llu, staged %llu",
				                  (unsigned long long)range->offset, (unsigned long long)n,
				                  (unsigned long long)copied);
			}
			pos += n;
			out += n;
			continue;
		}

		// Gap up to the next staged range (or the end of the read): fall back to an RDMA read. This
		// happens e.g. when the thrift read-ahead merged two staged column chunks across a small
		// unstaged column sitting between them.
		const uint64_t gap_end =
		    (range == handle.staged_ranges.end()) ? end : std::min<uint64_t>(end, range->offset);
		RDMAReadRange(handle.remote_offset + pos, out, gap_end - pos);
		out += gap_end - pos;
		pos = gap_end;
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
	std::sort(entries.begin(), entries.end(), [](const auto &a, const auto &b) { return a.first < b.first; });

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
	ReadWithStaging(h, buffer, static_cast<size_t>(nr_bytes), location);
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
	ReadWithStaging(h, buffer, static_cast<size_t>(to_read), h.cursor);
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

} // namespace duckdb
