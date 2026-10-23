#include "http_file_system.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_opener.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/database.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"

#include <coyote/cDefs.hpp>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <limits>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

namespace duckdb {

namespace {

string GetStringSetting(optional_ptr<FileOpener> opener, const string &key, const string &fallback) {
	Value value;
	if (FileOpener::TryGetCurrentSetting(opener, key, value) && !value.IsNull()) {
		return value.ToString();
	}
	return fallback;
}

uint64_t GetUIntSetting(optional_ptr<FileOpener> opener, const string &key, uint64_t fallback) {
	Value value;
	if (FileOpener::TryGetCurrentSetting(opener, key, value) && !value.IsNull()) {
		return value.GetValue<uint64_t>();
	}
	return fallback;
}

// 10.253.74.74 -> 0x0AFD4A4A: the order the SERVER_IP CSR takes (it does not byte-swap).
uint32_t ParseIpBE(const string &host) {
	unsigned b0 = 0, b1 = 0, b2 = 0, b3 = 0;
	if (std::sscanf(host.c_str(), "%u.%u.%u.%u", &b0, &b1, &b2, &b3) != 4 || b0 > 255 ||
	    b1 > 255 || b2 > 255 || b3 > 255) {
		throw IOException("Invalid http_server address '%s'", host);
	}
	return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
}

string NormalizeHttpPath(const string &path) {
	if (path.empty() || path[0] == '/') {
		return path;
	}
	return "/" + path;
}

// Case-insensitive prefix check for HTTP header lines.
bool StartsWithIgnoreCase(const string &line, const char *prefix) {
	const auto prefix_len = std::strlen(prefix);
	if (line.size() < prefix_len) {
		return false;
	}
	for (size_t i = 0; i < prefix_len; i++) {
		if (std::tolower(static_cast<unsigned char>(line[i])) !=
		    std::tolower(static_cast<unsigned char>(prefix[i]))) {
			return false;
		}
	}
	return true;
}

uint64_t ParseContentLengthHeader(const string &headers) {
	size_t pos = 0;
	while (pos < headers.size()) {
		auto line_end = headers.find("\r\n", pos);
		if (line_end == string::npos) {
			break;
		}
		auto line = headers.substr(pos, line_end - pos);
		pos = line_end + 2;

		if (StartsWithIgnoreCase(line, "content-length:")) {
			auto value = line.substr(std::strlen("content-length:"));
			value.erase(0, value.find_first_not_of(" \t"));
			return std::stoull(value);
		}
		if (StartsWithIgnoreCase(line, "content-range:")) {
			// bytes START-END/TOTAL or bytes */TOTAL
			auto slash = line.rfind('/');
			if (slash != string::npos && slash + 1 < line.size()) {
				auto total = line.substr(slash + 1);
				total.erase(0, total.find_first_not_of(" \t"));
				if (total != "*") {
					return std::stoull(total);
				}
			}
		}
	}
	return 0;
}

// Splits a raw reply into status line / headers / body and rejects anything that is not 200 or 206.
HttpReply ParseHttpReply(string raw, const char *what, const string &resource) {
	HttpReply reply;
	reply.raw = std::move(raw);

	const auto header_end = reply.raw.find("\r\n\r\n");
	const auto status_end = reply.raw.find("\r\n");
	if (header_end == string::npos || status_end == string::npos || reply.raw.rfind("HTTP/", 0) != 0) {
		throw IOException("%s for '%s': malformed HTTP response", what, resource);
	}

	reply.status_line = reply.raw.substr(0, status_end);
	reply.headers = reply.raw.substr(0, header_end);
	reply.body_off = header_end + 4;
	reply.partial = reply.status_line.find(" 206 ") != string::npos;
	if (!reply.partial && reply.status_line.find(" 200 ") == string::npos) {
		throw IOException("%s for '%s' failed: %s", what, resource, reply.status_line);
	}
	return reply;
}

} // namespace

void SetHttpFpgaDebug(ClientContext &, SetScope, Value &parameter) {
	oasis::set_http_debug(!parameter.IsNull() && parameter.GetValue<bool>());
}

void OasisHTTPFileSystem::EnsureInitialized(optional_ptr<FileOpener> opener) {
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

	server_host_ = GetStringSetting(opener, "http_server", "127.0.0.1");
	server_port_ = static_cast<uint16_t>(GetUIntSetting(opener, "http_port", coyote::DEF_PORT));
	server_ip_ = ParseIpBE(server_host_);
	if (oasis::http_debug_enabled()) {
		std::fprintf(stderr, "[httpfpga] init http_server=%s ip=0x%08x port=%u\n", server_host_.c_str(),
		             server_ip_, static_cast<unsigned>(server_port_));
	}
	initialized = true;
}

bool OasisHTTPFileSystem::CanHandleFile(const string &fpath) {
	return fpath.rfind(URL_PREFIX, 0) == 0;
}

unique_ptr<FileHandle> OasisHTTPFileSystem::OpenFile(const string &path, FileOpenFlags flags,
                                                     optional_ptr<FileOpener> opener) {
	if (flags.OpenForWriting()) {
		throw IOException("httpfpga:// filesystem is read-only");
	}

	EnsureInitialized(opener);
	auto resource_path = NormalizeHttpPath(path.substr(std::strlen(URL_PREFIX)));
	return make_uniq<OasisHTTPFileHandle>(*this, resource_path, flags, server_ip_, server_port_);
}

bool OasisHTTPFileSystem::FileExists(const string &filename, optional_ptr<FileOpener> opener) {
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

vector<OpenFileInfo> OasisHTTPFileSystem::Glob(const string &path, FileOpener *opener) {
	if (!HasGlob(path)) {
		if (FileExists(path, opener)) {
			return {OpenFileInfo(path)};
		}
		return {};
	}
	throw NotImplementedException("OasisHTTPFileSystem: wildcard glob patterns are not supported");
}

void OasisHTTPFileSystem::Seek(FileHandle &handle, idx_t location) {
	handle.Cast<OasisHTTPFileHandle>().cursor = location;
}

idx_t OasisHTTPFileSystem::SeekPosition(FileHandle &handle) {
	return handle.Cast<OasisHTTPFileHandle>().cursor;
}

uint64_t OasisHTTPFileSystem::CachedContentLength(const string &resource_path) {
	{
		std::lock_guard<std::mutex> lock(size_cache_mtx_);
		auto it = size_cache_.find(resource_path);
		if (it != size_cache_.end()) {
			return it->second;
		}
	}

	// Probe outside the lock, so the workers' first opens do not serialise on one round trip. A
	// concurrent probe of the same path computes the same value; the second insert is a no-op.
	const auto size = ProbeContentLength(resource_path);

	std::lock_guard<std::mutex> lock(size_cache_mtx_);
	size_cache_.emplace(resource_path, size);
	return size;
}

int64_t OasisHTTPFileSystem::GetFileSize(FileHandle &handle) {
	auto &h = handle.Cast<OasisHTTPFileHandle>();
	if (h.known_file_size == 0) {
		h.known_file_size = CachedContentLength(h.path);
	}
	return static_cast<int64_t>(h.known_file_size);
}

HttpReply OasisHTTPFileSystem::HttpExchange(const string &request, const char *what, const string &resource) {
	const auto socket_error = [&]() {
		return IOException("%s for '%s': socket error to %s:%u", what, resource, server_host_, server_port_);
	};

	addrinfo hints {};
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	addrinfo *result = nullptr;
	if (getaddrinfo(server_host_.c_str(), std::to_string(server_port_).c_str(), &hints, &result) != 0) {
		throw socket_error();
	}
	int sock = -1;
	for (auto *rp = result; rp != nullptr; rp = rp->ai_next) {
		sock = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
		if (sock < 0) {
			continue;
		}
		if (connect(sock, rp->ai_addr, rp->ai_addrlen) == 0) {
			break;
		}
		close(sock);
		sock = -1;
	}
	freeaddrinfo(result);
	if (sock < 0) {
		throw socket_error();
	}

	if (send(sock, request.data(), request.size(), 0) < 0) {
		close(sock);
		throw socket_error();
	}
	// Every request says Connection: close, so the server sends the whole reply and then FINs.
	string response;
	response.reserve(4096);
	char buffer[4096];
	while (true) {
		const auto n = recv(sock, buffer, sizeof(buffer), 0);
		if (n <= 0) {
			break;
		}
		response.append(buffer, static_cast<size_t>(n));
	}
	close(sock);
	return ParseHttpReply(std::move(response), what, resource);
}

void OasisHTTPFileSystem::HTTPReadRange(const string &path, uint64_t offset, size_t size, void *dst) {
	if (size == 0) {
		return;
	}
	if (size > std::numeric_limits<uint32_t>::max()) {
		throw IOException("HTTP read size %llu exceeds 32-bit limit", (unsigned long long)size);
	}
	const uint64_t range_end = offset + size - 1;
	const auto request = "GET " + NormalizeHttpPath(path) + " HTTP/1.1\r\nHost: " + server_host_ + ":" +
	                     std::to_string(server_port_) + "\r\nRange: bytes=" + std::to_string(offset) + "-" +
	                     std::to_string(range_end) + "\r\nConnection: close\r\n\r\n";
	const auto reply = HttpExchange(request, "host GET", path);

	// 206 -> body is exactly the requested range. 200 -> the server ignored Range and sent the whole
	// object, so index into it at `offset`.
	const size_t body_off = reply.body_off + (reply.partial ? 0 : static_cast<size_t>(offset));
	if (reply.raw.size() < body_off + size) {
		throw IOException("host GET short body for '%s' range=[%llu,%llu]: have %llu, need %llu", path,
		                  (unsigned long long)offset, (unsigned long long)range_end,
		                  (unsigned long long)(reply.raw.size() - std::min(reply.raw.size(), body_off)),
		                  (unsigned long long)size);
	}
	std::memcpy(dst, reply.raw.data() + body_off, size);

	if (oasis::http_debug_enabled()) {
		std::fprintf(stderr, "[httpfpga] host read path=%s range=[%llu,%llu] size=%llu\n", path.c_str(),
		             (unsigned long long)offset, (unsigned long long)range_end, (unsigned long long)size);
	}
}

uint64_t OasisHTTPFileSystem::ProbeContentLength(const string &resource_path) {
	if (!initialized) {
		throw IOException("httpfpga:// filesystem is not initialized");
	}

	const auto request = "HEAD " + NormalizeHttpPath(resource_path) + " HTTP/1.1\r\nHost: " + server_host_ +
	                     ":" + std::to_string(server_port_) + "\r\nConnection: close\r\n\r\n";
	const auto reply = HttpExchange(request, "HTTP HEAD", resource_path);

	const auto content_length = ParseContentLengthHeader(reply.headers);
	if (content_length == 0) {
		throw IOException("HTTP server did not return Content-Length for '%s'", resource_path);
	}
	return content_length;
}

timestamp_t OasisHTTPFileSystem::GetLastModifiedTime(FileHandle &handle) {
	// Remote HTTP objects are treated as immutable for metadata caching.
	return timestamp_t(0);
}

// Serves a read from the handle's read-ahead buffer, refilling it when the range is not resident.
// Reads of at least the buffer size skip it: they are already efficient.
void OasisHTTPFileSystem::ReadBuffered(OasisHTTPFileHandle &h, void *dst, size_t size, uint64_t location) {
	if (size >= OasisHTTPFileHandle::READ_BUFFER_LEN) {
		HTTPReadRange(h.path, location, size, dst);
		return;
	}
	const bool resident =
	    h.buffer_end > h.buffer_start && location >= h.buffer_start && location + size <= h.buffer_end;
	if (!resident) {
		if (!h.read_buffer) {
			h.read_buffer = duckdb::unique_ptr<data_t[]>(new data_t[OasisHTTPFileHandle::READ_BUFFER_LEN]);
		}
		// Read ahead only when the access is sequential, i.e. continues the previous window. Parquet
		// page headers can sit about 1 MB apart, and a full buffer per scattered header would fetch
		// thousands of times the bytes used. A seek costs one small request instead.
		const bool sequential = h.buffer_end > h.buffer_start && location >= h.buffer_end &&
		                        location - h.buffer_end <= OasisHTTPFileHandle::READ_BUFFER_LEN / 4;
		const bool first_touch = h.buffer_end == h.buffer_start;
		uint64_t fetch = (sequential || first_touch) ? OasisHTTPFileHandle::READ_BUFFER_LEN : size;
		// The read-ahead must not pass EOF: the server would answer short and HTTPReadRange rejects a
		// short body. Read() already bounds the caller's own range.
		if (h.known_file_size != 0 && location + fetch > h.known_file_size) {
			fetch = h.known_file_size - location;
		}
		fetch = std::max<uint64_t>(fetch, size);
		HTTPReadRange(h.path, location, static_cast<size_t>(fetch), h.read_buffer.get());
		h.buffer_start = location;
		h.buffer_end = location + fetch;
	}
	std::memcpy(dst, h.read_buffer.get() + (location - h.buffer_start), size);
}

void OasisHTTPFileSystem::Read(FileHandle &handle, void *buffer, int64_t nr_bytes, idx_t location) {
	auto &h = handle.Cast<OasisHTTPFileHandle>();
	if (nr_bytes < 0) {
		throw IOException("Negative read size on %s", handle.path);
	}
	// A range past EOF comes back short, which is an error; reject it before asking.
	if (h.known_file_size != 0 && location + static_cast<uint64_t>(nr_bytes) > h.known_file_size) {
		throw IOException("Read past end of file %s", handle.path);
	}
	ReadBuffered(h, buffer, static_cast<size_t>(nr_bytes), location);
}

int64_t OasisHTTPFileSystem::Read(FileHandle &handle, void *buffer, int64_t nr_bytes) {
	auto &h = handle.Cast<OasisHTTPFileHandle>();
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
	ReadBuffered(h, buffer, to_read, h.cursor);
	h.cursor += to_read;
	return static_cast<int64_t>(to_read);
}

} // namespace duckdb
