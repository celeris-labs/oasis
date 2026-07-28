#include "http_file_system.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/file_opener.hpp"
#include "duckdb/main/config.hpp"
#include "duckdb/main/database.hpp"
#include "oasis_http_debug.hpp"
#include "oasis/configuration.hpp"
#include "oasis/oasis_context.hpp"
#include "oasis_context_cache_entry.hpp"

#include <libstf/buffer.hpp>
#include <libstf/output_buffer_manager.hpp>
#include <libstf/output_handle.hpp>

#include <coyote/cDefs.hpp>

#include <algorithm>
#include <arpa/inet.h>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
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

// parseIpBE: 10.253.74.74 -> 0x0AFD4A4A.
// Used as-is for openConnTcp and HTTP Host CSR (those CSRs do not byte-swap).
//
// doArpLookup goes through NET_ARP_REG which byte-reverses the written word
// (shell_slave IP set path does not). Pass bswap32(parseIpBE) so wire who-has
// matches 10.253.74.74. Earlier "backwards ARP" with bswap was from YMM multi-beat
// MMIO, not from the bswap itself (ARP is now a single dword store in libcoyote).
uint32_t ParseIpBE(const string &host) {
	unsigned b0 = 0, b1 = 0, b2 = 0, b3 = 0;
	if (std::sscanf(host.c_str(), "%u.%u.%u.%u", &b0, &b1, &b2, &b3) != 4 || b0 > 255 ||
	    b1 > 255 || b2 > 255 || b3 > 255) {
		throw IOException("Invalid http_server address '%s'", host);
	}
	return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
}

uint32_t IpForArpLookup(uint32_t ip_be) {
	return __builtin_bswap32(ip_be);
}

string NormalizeHttpPath(const string &path) {
	if (path.empty() || path[0] == '/') {
		return path;
	}
	return "/" + path;
}

// Decodes the packed HTTP/TCP FSM debug status word (HTTPReadConfig read CSR 2)
// into a human-readable one-liner. See HTTPReadConfig::debug_status() for layout.
string DecodeHttpFpgaStatus(uint32_t status) {
	static const char *top[] = {"IDLE", "TCP_SEND", "TCP_READ"};
	const auto top_state = status & 0xF;
	const char *top_name = top_state < 3 ? top[top_state] : "?";
	char buf[256];
	std::snprintf(buf, sizeof(buf),
	              "handler=%s(%u) send=%u read=%u | send_done=%u send_err=%u read_done=%u "
	              "read_err=%u busy=%u",
	              top_name, top_state, (status >> 8) & 0xF, (status >> 12) & 0xF,
	              (status >> 18) & 1, (status >> 19) & 1, (status >> 20) & 1, (status >> 21) & 1,
	              (status >> 22) & 1);
	return string(buf);
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

} // namespace

HTTPFileSystem::HTTPFileSystem(DatabaseInstance &instance) : instance(instance) {
}

HTTPFileSystem::~HTTPFileSystem() = default;

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

	server_host_ = GetStringSetting(opener, "http_server", "127.0.0.1");
	server_port_ = static_cast<uint16_t>(GetUIntSetting(opener, "http_port", coyote::DEF_PORT));
	server_ip_ = ParseIpBE(server_host_);

	(void)ctx.config<oasis::HTTPReadConfig>();

	// Optional ARP warm-up; handler opens TCP itself on START.
	if (HttpFpgaDebugEnabled()) {
		std::fprintf(stderr,
		             "[httpfpga] init http_server=%s parseIpBE=0x%08x arp=0x%08x port=%u\n",
		             server_host_.c_str(), server_ip_, IpForArpLookup(server_ip_),
		             static_cast<unsigned>(server_port_));
	}
	// Resolve the server MAC into the TOE ARP table, then let it settle. The standalone
	// bring-up tool (which works) does doArpLookup + sleep(1) before every START; here we
	// resolve once at init since the entry persists for the session. Without this the handler
	// reaches START and tries to open the connection before the server MAC is known, then
	// stalls — START fires but no SYN ever leaves the FPGA (the "fire, then hang, no TCP"
	// symptom). This call was previously commented out, which is exactly that hang.
	ctx.cthread()->doArpLookup(IpForArpLookup(server_ip_));
	sleep(1);

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
	auto resource_path = NormalizeHttpPath(path.substr(std::strlen(URL_PREFIX)));
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

vector<OpenFileInfo> HTTPFileSystem::Glob(const string &path, FileOpener *opener) {
	if (!HasGlob(path)) {
		if (FileExists(path, opener)) {
			return {OpenFileInfo(path)};
		}
		return {};
	}
	throw NotImplementedException("HTTPFileSystem: wildcard glob patterns are not supported");
}

void HTTPFileSystem::Seek(FileHandle &handle, idx_t location) {
	handle.Cast<HTTPFileHandle>().cursor = location;
}

idx_t HTTPFileSystem::SeekPosition(FileHandle &handle) {
	return handle.Cast<HTTPFileHandle>().cursor;
}

int64_t HTTPFileSystem::GetFileSize(FileHandle &handle) {
	auto &h = handle.Cast<HTTPFileHandle>();
	if (h.known_file_size == 0) {
		h.known_file_size = ProbeContentLength(h.path);
	}
	return static_cast<int64_t>(h.known_file_size);
}

bool HTTPFileSystem::HttpSocketRequest(const std::string &request, std::string &response) {
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

void HTTPFileSystem::HTTPReadRangeCpu(const string &path, uint64_t offset, size_t size, void *dst) {
	const auto http_path = NormalizeHttpPath(path);
	const uint64_t range_end = offset + size - 1;
	const auto request = "GET " + http_path + " HTTP/1.1\r\nHost: " + server_host_ + ":" +
	                     std::to_string(server_port_) + "\r\nRange: bytes=" + std::to_string(offset) + "-" +
	                     std::to_string(range_end) + "\r\nConnection: close\r\n\r\n";

	string response;
	if (!HttpSocketRequest(request, response)) {
		throw IOException("CPU-fallback GET failed for '%s' (socket error to %s:%u)", path, server_host_,
		                  server_port_);
	}

	const auto header_end = response.find("\r\n\r\n");
	const auto status_line_end = response.find("\r\n");
	if (header_end == string::npos || status_line_end == string::npos || response.rfind("HTTP/", 0) != 0) {
		throw IOException("CPU-fallback: invalid HTTP response for '%s'", path);
	}
	const auto status_line = response.substr(0, status_line_end);
	const bool partial = status_line.find(" 206 ") != string::npos;
	if (!partial && status_line.find(" 200 ") == string::npos) {
		throw IOException("CPU-fallback GET for '%s' failed: %s", path, status_line);
	}

	// 206 -> body is exactly the requested range. 200 -> the server ignored Range and sent the whole
	// object, so index into it at `offset`.
	const size_t body_off = header_end + 4 + (partial ? 0 : static_cast<size_t>(offset));
	if (response.size() < body_off + size) {
		throw IOException("CPU-fallback short body for '%s' range=[%llu,%llu]: have %llu, need %llu", path,
		                  (unsigned long long)offset, (unsigned long long)range_end,
		                  (unsigned long long)(response.size() - std::min(response.size(), body_off)),
		                  (unsigned long long)size);
	}
	std::memcpy(dst, response.data() + body_off, size);

	if (HttpFpgaDebugEnabled()) {
		std::fprintf(stderr, "[httpfpga] CPU-fallback read path=%s range=[%llu,%llu] size=%llu\n", path.c_str(),
		             (unsigned long long)offset, (unsigned long long)range_end, (unsigned long long)size);
	}
}

uint64_t HTTPFileSystem::ProbeContentLength(const string &resource_path) {
	if (!initialized) {
		throw IOException("httpfpga:// filesystem is not initialized");
	}

	const auto http_path = NormalizeHttpPath(resource_path);
	const auto request = "HEAD " + http_path + " HTTP/1.1\r\nHost: " + server_host_ + ":" +
	                     std::to_string(server_port_) + "\r\nConnection: close\r\n\r\n";

	string response;
	if (!HttpSocketRequest(request, response)) {
		throw IOException("Failed to probe size of '%s' (socket error to %s:%u)", resource_path,
		                  server_host_, server_port_);
	}

	const auto header_end = response.find("\r\n\r\n");
	if (header_end == string::npos) {
		throw IOException("Invalid HTTP response probing size of '%s'", resource_path);
	}

	const auto status_line_end = response.find("\r\n");
	if (status_line_end == string::npos || response.rfind("HTTP/", 0) != 0) {
		throw IOException("Invalid HTTP status line probing size of '%s'", resource_path);
	}
	const auto status_line = response.substr(0, status_line_end);
	if (status_line.find(" 200 ") == string::npos && status_line.find(" 206 ") == string::npos) {
		throw IOException("HTTP HEAD for '%s' failed: %s", resource_path, status_line);
	}

	const auto content_length = ParseContentLengthHeader(response.substr(0, header_end));
	if (content_length == 0) {
		throw IOException("HTTP server did not return Content-Length for '%s'", resource_path);
	}
	return content_length;
}

timestamp_t HTTPFileSystem::GetLastModifiedTime(FileHandle &handle) {
	// Remote HTTP objects are treated as immutable for metadata caching.
	return timestamp_t(0);
}

void HTTPFileSystem::Read(FileHandle &handle, void *buffer, int64_t nr_bytes, idx_t location) {
	auto &h = handle.Cast<HTTPFileHandle>();
	if (nr_bytes < 0) {
		throw IOException("Negative read size on %s", handle.path);
	}
	// The OBM drain blocks until exactly the requested byte count arrives, so a read
	// past EOF (which the server answers with a short body) would hang. Reject it.
	if (h.known_file_size != 0 && location + static_cast<uint64_t>(nr_bytes) > h.known_file_size) {
		throw IOException("Read past end of file %s", handle.path);
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

	// CPU fallback: bypass the FPGA and fetch over a plain socket. Reliable, but does not exercise
	// the FPGA data path — a scaffolding aid while the HW receive path is validated.
	if (HttpFpgaCpuFallbackEnabled()) {
		HTTPReadRangeCpu(path, offset, size, dst);
		return;
	}

	auto &ctx = oasis::OasisContext::ctx();
	auto http_cfg = ctx.config<oasis::HTTPReadConfig>();
	auto obm = ctx.output_buffer_manager();
	const auto bypass_stream = ctx.httpBypassStream();
	const uint64_t range_end = offset + size - 1;

	// The HTTP side is a single-session FSM: one set of parameter CSRs, one START, one client_state.
	// A second request fired while one is in flight would overwrite the CSRs and interleave bodies on
	// the shared bypass stream. So hold the lock across the whole transfer — trigger, enqueue, drain —
	// which serializes httpfpga:// reads. With the HW drain-to-close fix (tcp_read), a single request
	// returns the whole body across however many TCP segments it spans.
	std::lock_guard<std::mutex> lock(mtx);

	// Trigger the request first: the handler opens the TCP connection and issues the ranged GET.
	http_cfg->read(bypass_stream, server_ip_, server_port_, path, offset, range_end, /*session*/ 0);
	RecordHttpFpgaTrigger(bypass_stream, server_ip_, server_port_, path, offset, range_end,
	                      static_cast<uint32_t>(size));

	// The bypass stream is unmanaged on the OBM. The HW strips the HTTP header, so exactly `size`
	// body bytes land here — pass that so the OBM allocates a right-sized buffer.
	auto handle = obm->acquire_output_handle(bypass_stream, size);

	if (HttpFpgaDebugEnabled()) {
		std::fprintf(stderr, "[httpfpga] read path=%s range=[%llu,%llu] size=%llu\n", path.c_str(),
		             (unsigned long long)offset, (unsigned long long)range_end, (unsigned long long)size);
	}

	// Drain all buffers for this transfer. A body that fits one FPGA buffer is one iteration; larger
	// ranges are chunked across multiple buffers, each surfaced via its own interrupt. These calls
	// block until the FPGA writes (or discards) the allocation.
	size_t copied = 0;
	while (handle->stream_has_more_output(bypass_stream)) {
		auto buf = handle->get_next_stream_output(bypass_stream);
		if (!buf) {
			break;
		}
		if (copied + buf->size > size) {
			throw IOException("HTTP read overran requested size: requested %llu, already got %llu, "
			                  "next chunk %llu",
			                  (unsigned long long)size, (unsigned long long)copied,
			                  (unsigned long long)buf->size);
		}
		std::memcpy(static_cast<uint8_t *>(dst) + copied, buf->ptr, buf->size);
		copied += buf->size;
	}
	if (copied != size) {
		throw IOException("HTTP read short transfer for '%s' range=[%llu,%llu]: requested %llu bytes, "
		                  "got %llu (client_state=%u total_word=%u)",
		                  path, (unsigned long long)offset, (unsigned long long)range_end,
		                  (unsigned long long)size, (unsigned long long)copied,
		                  static_cast<unsigned>(http_cfg->client_state()), http_cfg->debug_status());
	}

	if (HttpFpgaDebugEnabled()) {
		std::fprintf(stderr, "[httpfpga] done path=%s copied=%llu client_state=%u\n", path.c_str(),
		             (unsigned long long)copied, static_cast<unsigned>(http_cfg->client_state()));
	}
}

} // namespace duckdb
