#include "http_file_system.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_opener.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/database.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"

#include <libstf/buffer.hpp>
#include <libstf/output_buffer_manager.hpp>
#include <libstf/output_handle.hpp>

#include <coyote/cDefs.hpp>

#include <algorithm>
#include <arpa/inet.h>
#include <cstring>
#include <limits>

namespace duckdb {

namespace {

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

uint32_t ParseIPv4(const string &host) {
	struct in_addr addr {};
	if (inet_pton(AF_INET, host.c_str(), &addr) != 1) {
		throw IOException("Invalid http_server address '%s'", host);
	}
	return ntohl(addr.s_addr);
}

} // namespace

HTTPFileSystem::HTTPFileSystem(DatabaseInstance &instance) : instance(instance) {
}

void HTTPFileSystem::EnsureInitialized(optional_ptr<FileOpener> opener) {
	std::lock_guard<std::mutex> lock(init_mtx);
	if (initialized) {
		return;
	}

	auto db = FileOpener::TryGetDatabase(opener);
	if (!db) {
		throw IOException("httpfpga:// filesystem requires a database context to initialize");
	}
	auto &ctx = db->GetObjectCache().GetOrCreate<OasisContextCacheEntry>("oasis_context", *db)->ctx();
	if (!ctx.isHTTPEnabled()) {
		throw IOException("httpfpga:// filesystem is unavailable: this FPGA shell was synthesized "
		                  "without HTTPReadConfig (rebuild with -DENABLE_HTTP=ON)");
	}

	server_host_ = GetStringSetting(instance, "http_server", "127.0.0.1");
	server_port_ = static_cast<uint16_t>(GetUIntSetting(instance, "http_port", coyote::DEF_PORT));
	server_ip_ = ParseIPv4(server_host_);

	(void)ctx.config<oasis::HTTPReadConfig>();
	initialized = true;
}

bool HTTPFileSystem::CanHandleFile(const string &fpath) {
	return fpath.rfind(URL_PREFIX, 0) == 0;
}

unique_ptr<FileHandle> HTTPFileSystem::OpenFile(const string &path, FileOpenFlags flags,
                                                optional_ptr<FileOpener> opener) {
	if (flags.OpenForWriting()) {
		throw IOException("httpfpga:// filesystem is read-only");
	}

	EnsureInitialized(opener);
	auto resource_path = path.substr(std::strlen(URL_PREFIX));
	return make_uniq<HTTPFileHandle>(*this, resource_path, flags, 0);
}

bool HTTPFileSystem::FileExists(const string &filename, optional_ptr<FileOpener> opener) {
	if (!CanHandleFile(filename)) {
		return false;
	}
	try {
		EnsureInitialized(opener);
	} catch (...) {
		return false;
	}
	return true;
}

void HTTPFileSystem::Seek(FileHandle &handle, idx_t location) {
	handle.Cast<HTTPFileHandle>().cursor = location;
}

idx_t HTTPFileSystem::SeekPosition(FileHandle &handle) {
	return handle.Cast<HTTPFileHandle>().cursor;
}

int64_t HTTPFileSystem::GetFileSize(FileHandle &handle) {
	return static_cast<int64_t>(handle.Cast<HTTPFileHandle>().known_file_size);
}

void HTTPFileSystem::Read(FileHandle &handle, void *buffer, int64_t nr_bytes, idx_t location) {
	auto &h = handle.Cast<HTTPFileHandle>();
	if (nr_bytes < 0) {
		throw IOException("Negative read size on %s", handle.path);
	}
	HTTPReadRange(h.path, location, static_cast<size_t>(nr_bytes), buffer);
}

int64_t HTTPFileSystem::Read(FileHandle &handle, void *buffer, int64_t nr_bytes) {
	auto &h = handle.Cast<HTTPFileHandle>();
	if (nr_bytes < 0) {
		throw IOException("Negative read size on %s", handle.path);
	}
	if (h.known_file_size != 0 && h.cursor >= h.known_file_size) {
		return 0;
	}
	auto to_read = static_cast<size_t>(nr_bytes);
	if (h.known_file_size != 0) {
		to_read = std::min(to_read, static_cast<size_t>(h.known_file_size - h.cursor));
	}
	HTTPReadRange(h.path, h.cursor, to_read, buffer);
	h.cursor += to_read;
	return static_cast<int64_t>(to_read);
}

void HTTPFileSystem::HTTPReadRange(const string &path, uint64_t offset, size_t size, void *dst) {
	if (size == 0) {
		return;
	}
	if (size > std::numeric_limits<uint32_t>::max()) {
		throw IOException("HTTP read size %llu exceeds 32-bit limit", (unsigned long long)size);
	}

	auto &ctx = oasis::OasisContext::ctx();
	auto obm = ctx.output_buffer_manager();
	auto http_cfg = ctx.config<oasis::HTTPReadConfig>();
	const auto bypass_stream = ctx.httpBypassStream();
	const uint64_t range_end = offset + size - 1;

	std::shared_ptr<libstf::OutputHandle> handle;
	{
		std::lock_guard<std::mutex> lock(mtx);

		http_cfg->read(bypass_stream, server_ip_, server_port_, path, offset, range_end);
		handle = obm->acquire_output_handle(bypass_stream, size);
	}

	size_t copied = 0;
	while (handle->stream_has_more_output(bypass_stream)) {
		auto buf = handle->get_next_stream_output(bypass_stream);
		if (!buf) {
			break;
		}
		if (copied + buf->size > size) {
			throw IOException("HTTP read overran requested size: requested %llu, already got %llu, next chunk %llu",
			                  (unsigned long long)size, (unsigned long long)copied, (unsigned long long)buf->size);
		}
		std::memcpy(static_cast<uint8_t *>(dst) + copied, buf->ptr, buf->size);
		copied += buf->size;
	}
	if (copied != size) {
		throw IOException("HTTP read short transfer: requested %llu bytes, got %llu", (unsigned long long)size,
		                  (unsigned long long)copied);
	}
}

} // namespace duckdb
