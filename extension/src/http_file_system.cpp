#include "http_file_system.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_opener.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/database.hpp"
#include "oasis_http_debug.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"

#include <coyote/cDefs.hpp>

#include <algorithm>
#include <arpa/inet.h>
#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <netdb.h>
#include <sys/socket.h>
#include <cstdlib>
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
// The HEAD probe and the CPU fallback had a copy of this each; they only differ in `what`.
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

OasisHTTPFileSystem::OasisHTTPFileSystem(DatabaseInstance &instance) : instance(instance) {
}

OasisHTTPFileSystem::~OasisHTTPFileSystem() = default;

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

	(void)ctx.config<oasis::HTTPReadConfig>();

	// No ARP warm-up: the handler opens its connection on the first START and the TOE resolves the
	// server's MAC itself then.
	if (HttpFpgaDebugEnabled()) {
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
	return make_uniq<OasisHTTPFileHandle>(*this, resource_path, flags, 0, server_ip_, server_port_);
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

// Returns the object's Content-Length, issuing at most one HEAD per path for the session.
uint64_t OasisHTTPFileSystem::CachedContentLength(const string &resource_path) {
	{
		std::lock_guard<std::mutex> lock(size_cache_mtx_);
		auto it = size_cache_.find(resource_path);
		if (it != size_cache_.end()) {
			return it->second;
		}
	}

	// Probe outside the lock: ProbeContentLength does a blocking socket round trip, and holding the
	// cache mutex across it would serialise every worker's first open. A concurrent probe of the
	// same path is harmless -- both compute the same value and the second insert is a no-op.
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

bool OasisHTTPFileSystem::HttpSocketRequest(const std::string &request, std::string &response) {
	addrinfo hints {};
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;

	addrinfo *result = nullptr;
	const auto port_str = std::to_string(server_port_);
	if (getaddrinfo(server_host_.c_str(), port_str.c_str(), &hints, &result) != 0) {
		return false;
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
		return false;
	}

	response.clear();
	response.reserve(4096);
	if (send(sock, request.data(), request.size(), 0) < 0) {
		close(sock);
		return false;
	}

	// Connection: close -> the server sends the whole response then FINs, so recv until 0.
	char buffer[4096];
	while (true) {
		const auto n = recv(sock, buffer, sizeof(buffer), 0);
		if (n <= 0) {
			break;
		}
		response.append(buffer, static_cast<size_t>(n));
	}
	close(sock);
	return true;
}

HttpReply OasisHTTPFileSystem::HttpExchange(const string &request, const char *what, const string &resource) {
	string response;
	if (!HttpSocketRequest(request, response)) {
		throw IOException("%s for '%s': socket error to %s:%u", what, resource, server_host_, server_port_);
	}
	return ParseHttpReply(std::move(response), what, resource);
}

void OasisHTTPFileSystem::HTTPReadRangeCpu(const string &path, uint64_t offset, size_t size, void *dst) {
	const uint64_t range_end = offset + size - 1;
	const auto request = "GET " + NormalizeHttpPath(path) + " HTTP/1.1\r\nHost: " + server_host_ + ":" +
	                     std::to_string(server_port_) + "\r\nRange: bytes=" + std::to_string(offset) + "-" +
	                     std::to_string(range_end) + "\r\nConnection: close\r\n\r\n";
	const auto reply = HttpExchange(request, "CPU-fallback GET", path);

	// 206 -> body is exactly the requested range. 200 -> the server ignored Range and sent the whole
	// object, so index into it at `offset`.
	const size_t body_off = reply.body_off + (reply.partial ? 0 : static_cast<size_t>(offset));
	if (reply.raw.size() < body_off + size) {
		throw IOException("CPU-fallback short body for '%s' range=[%llu,%llu]: have %llu, need %llu", path,
		                  (unsigned long long)offset, (unsigned long long)range_end,
		                  (unsigned long long)(reply.raw.size() - std::min(reply.raw.size(), body_off)),
		                  (unsigned long long)size);
	}
	std::memcpy(dst, reply.raw.data() + body_off, size);

	if (HttpFpgaDebugEnabled()) {
		std::fprintf(stderr, "[httpfpga] CPU-fallback read path=%s range=[%llu,%llu] size=%llu\n", path.c_str(),
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

// Serve a read from the handle's read-ahead cache, refilling it when the range is not resident.
//
// Without this, DuckDB's Parquet ColumnReader turned every page-header peek into a separate HTTP
// request over a separate TCP connection -- measured on the wire as a whole handshake to move 256
// bytes. Refilling 1 MiB at a time collapses thousands of those into a handful.
//
// Reads at or above the buffer size skip the cache: they are already efficient, and copying them
// through a 1 MiB window would only add a memcpy and evict useful data.
void OasisHTTPFileSystem::ReadBuffered(OasisHTTPFileHandle &h, void *dst, size_t size,
                                       uint64_t location) {
	// Diagnostic only, and off unless OASIS_READBUF_TRACE is set in the environment. Counts the
	// reads served from the resident window so a fetch line can report how many it covered.
	static std::atomic<uint64_t> trace_resident_hits {0};
	const bool trace = HttpFpgaReadTraceEnabled();

	if (size >= OasisHTTPFileHandle::READ_BUFFER_LEN) {
		if (trace) {
			std::fprintf(stderr, "[rbtrace] h=%p big loc=%llu size=%llu path=%s\n", (void *)&h,
			             (unsigned long long)location, (unsigned long long)size, h.path.c_str());
		}
		HTTPReadRange(h.path, location, size, dst);
		return;
	}
	const bool resident = h.buffer_end > h.buffer_start && location >= h.buffer_start &&
	                      location + size <= h.buffer_end;
	if (trace && resident) {
		trace_resident_hits.fetch_add(1, std::memory_order_relaxed);
	}
	if (!resident) {
		const uint64_t trace_prev_start = h.buffer_start;
		const uint64_t trace_prev_end = h.buffer_end;
		if (!h.read_buffer) {
			h.read_buffer = duckdb::unique_ptr<data_t[]>(new data_t[OasisHTTPFileHandle::READ_BUFFER_LEN]);
		}
		// READ AHEAD ONLY WHEN THE ACCESS IS ACTUALLY SEQUENTIAL.
		//
		// Reading a whole buffer for every small request is a trap, not a win. Parquet page headers
		// can sit ~1 MB apart, so a scattered 256-byte header walk would pull a fresh 1 MiB per
		// header, use 256 bytes of it and throw the rest away -- thousands of times the bytes the
		// unbuffered path moved. Sequential page walking is the case that benefits, and it is
		// recognisable: the next read starts where the last buffer ended.
		//
		// So: read ahead when this read continues the previous window, fetch exactly what was
		// asked for when it does not. A single seek costs one small request, as before; a scan
		// pays one 1 MiB fetch per MiB and gets every later header for free.
		const bool sequential = h.buffer_end > h.buffer_start && location >= h.buffer_end &&
		                        location - h.buffer_end <= OasisHTTPFileHandle::READ_BUFFER_LEN / 4;
		const bool first_touch = h.buffer_end == h.buffer_start;
		uint64_t fetch = (sequential || first_touch) ? OasisHTTPFileHandle::READ_BUFFER_LEN : size;
		// Never read past EOF: the server answers short and the drain would wait for bytes that
		// are not coming. Read() above rejects that for the caller's range; the READ-AHEAD has to
		// clamp itself.
		if (h.known_file_size != 0 && location + fetch > h.known_file_size) {
			fetch = h.known_file_size - location;
		}
		if (fetch < size) {
			fetch = size; // caller's range is authoritative and already bounds-checked
		}
		if (trace) {
			std::fprintf(stderr,
			             "[rbtrace] h=%p fetch loc=%llu size=%llu fetch=%llu seq=%d first=%d "
			             "prev=[%llu,%llu) hits=%llu path=%s\n",
			             (void *)&h, (unsigned long long)location, (unsigned long long)size,
			             (unsigned long long)fetch, sequential ? 1 : 0, first_touch ? 1 : 0,
			             (unsigned long long)trace_prev_start, (unsigned long long)trace_prev_end,
			             (unsigned long long)trace_resident_hits.exchange(0, std::memory_order_relaxed),
			             h.path.c_str());
		}
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
	// The OBM drain blocks until exactly the requested byte count arrives, so a read
	// past EOF (which the server answers with a short body) would hang. Reject it.
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

void OasisHTTPFileSystem::HTTPReadRange(const string &path, uint64_t offset, size_t size, void *dst) {
	if (size == 0) {
		return;
	}
	if (size > std::numeric_limits<uint32_t>::max()) {
		throw IOException("HTTP read size %llu exceeds 32-bit limit", (unsigned long long)size);
	}

	// Raw, undecoded bytes have no hardware return path: the HTTP body feeds the ColumnChunkDecoder
	// directly. So the two raw-byte consumers go over an ordinary host socket:
	//   - the Parquet footer/metadata read in OasisScanBind, and
	//   - the CPU/string (BYTE_ARRAY) column path in read_oasis, which reads pages via this handle.
	// Both are small and off the hot path. The FPGA data path is read_oasis's HTTPBatchSourceOperator,
	// which streams whole column chunks into the decoder.
	HTTPReadRangeCpu(path, offset, size, dst);
}

} // namespace duckdb
