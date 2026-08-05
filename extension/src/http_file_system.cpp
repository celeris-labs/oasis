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
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <netdb.h>
#include <sys/socket.h>
#include <thread>
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

// Decodes the packed FSM status word (HttpConfig read CSR 2). Layout is defined by `totalWord` in
// hardware/src/hdl/http_read/handler.sv. Every sub-FSM gets its own field here, which the 4-bit
// client_state cannot give you: state_debug multiplexes one value, so 2, 6, 9 and 10 each alias two
// different states.
string DecodeHttpFpgaStatus(uint32_t status) {
	// Mirrors `coarse_state` in hardware/src/hdl/http_read/handler.sv. RECONNECT replaced CLOSE
	// when the client stopped tearing the connection down after every response.
	static const char *handler_states[] = {"IDLE", "CONNECT", "SEND", "READ", "RECONNECT"};
	const auto top = status & 0xF;
	char buf[256];
	std::snprintf(buf, sizeof(buf),
	              "handler=%s(%u) init=%u send=%u read=%u | done i/s/r=%u/%u/%u "
	              "err i/s/r=%u/%u/%u busy=%u sid=%u",
	              top < 5 ? handler_states[top] : "?", top, (status >> 4) & 0xF,
	              (status >> 8) & 0xF, (status >> 12) & 0xF, (status >> 16) & 1,
	              (status >> 18) & 1, (status >> 20) & 1, (status >> 17) & 1, (status >> 19) & 1,
	              (status >> 21) & 1, (status >> 22) & 1, (status >> 24) & 0xFF);
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

// The handler is busy (totalWord bit 22 = state != ST_IDLE).
bool HandlerBusy(uint32_t status) {
	return (status & (1u << 22)) != 0;
}

// Polls the handler status for as long as it is alive and prints a summary every three seconds.
// get_next_stream_output blocks with NO timeout, so without this a stalled FPGA is a silent hang
// with nothing on stderr at all.
//
// Tracks the PEAK handler state and whether it was ever busy across the whole read, which separates
// "START never fired" (peak stays 0 => a control/trigger bug, no GET on the wire) from "the handler
// ran but the body was dropped after receive" (peak reaches 1..4 => datapath/DMA bug).
class HandlerWatchdog {
public:
	HandlerWatchdog(oasis::HTTPReadConfig &cfg, size_t expected) : cfg_(cfg), expected_(expected) {
		thread_ = std::thread([this] { Run(); });
	}
	~HandlerWatchdog() {
		done_.store(true, std::memory_order_relaxed);
		if (thread_.joinable()) {
			thread_.join();
		}
	}
	HandlerWatchdog(const HandlerWatchdog &) = delete;
	HandlerWatchdog &operator=(const HandlerWatchdog &) = delete;

	void Progress(size_t copied) {
		copied_.store(copied, std::memory_order_relaxed);
	}

private:
	void Run() {
		uint32_t peak_state = 0;
		bool ever_busy = false;
		int ms = 0;
		int next_bark_ms = 3000;
		// Poll fast so we catch the handler in flight even if it runs and returns to IDLE in well
		// under a second.
		while (!done_.load(std::memory_order_relaxed)) {
			std::this_thread::sleep_for(std::chrono::milliseconds(1));
			ms++;
			uint32_t status = 0;
			try {
				status = cfg_.debug_status();
			} catch (...) {
				continue;
			}
			peak_state = std::max(peak_state, status & 0xFu);
			ever_busy = ever_busy || HandlerBusy(status);
			if (ms >= next_bark_ms) {
				next_bark_ms += 3000;
				std::fprintf(stderr,
				             "[httpfpga] WATCHDOG %ds: waiting, copied=%llu/%llu | THIS READ peak: "
				             "handler_max=%u ever_busy=%d | now=[%s]\n",
				             ms / 1000, (unsigned long long)copied_.load(),
				             (unsigned long long)expected_, peak_state, ever_busy ? 1 : 0,
				             DecodeHttpFpgaStatus(status).c_str());
			}
		}
	}

	oasis::HTTPReadConfig &cfg_;
	size_t expected_;
	std::atomic<bool> done_ {false};
	std::atomic<size_t> copied_ {0};
	std::thread thread_;
};

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
	return make_uniq<HTTPFileHandle>(*this, resource_path, flags, 0, server_ip_, server_port_);
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

// Returns the object's Content-Length, issuing at most one HEAD per path for the session.
uint64_t HTTPFileSystem::CachedContentLength(const string &resource_path) {
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

int64_t HTTPFileSystem::GetFileSize(FileHandle &handle) {
	auto &h = handle.Cast<HTTPFileHandle>();
	if (h.known_file_size == 0) {
		h.known_file_size = CachedContentLength(h.path);
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

HttpReply HTTPFileSystem::HttpExchange(const string &request, const char *what, const string &resource) {
	string response;
	if (!HttpSocketRequest(request, response)) {
		throw IOException("%s for '%s': socket error to %s:%u", what, resource, server_host_, server_port_);
	}
	return ParseHttpReply(std::move(response), what, resource);
}

void HTTPFileSystem::HTTPReadRangeCpu(const string &path, uint64_t offset, size_t size, void *dst) {
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

uint64_t HTTPFileSystem::ProbeContentLength(const string &resource_path) {
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

	// Raw, undecoded bytes have NO hardware return path on an ENABLE_HTTP bitstream. The HTTP body
	// now feeds the ColumnChunkDecoder directly and axi_out[BYPASS_ID] is tied off
	// (hardware/src/vfpga_top.svh) — enqueuing on the old bypass stream just blocks forever on an
	// interrupt that can never fire.
	//
	// So the two remaining raw-byte consumers go over an ordinary host socket:
	//   - the Parquet footer/metadata read in OasisScanBind, and
	//   - the CPU/string (BYTE_ARRAY) column path in read_oasis, which reads pages via this handle.
	// Both are small and off the hot path. The FPGA data path is exercised by read_oasis's
	// HTTPSourceOperator, which streams whole column chunks into the decoder.
	//
	// The legacy raw-bypass path below is kept for bringing up a pre-decoder bitstream and is
	// reachable only via `SET httpfpga_raw_bypass = true`.
	if (!HttpFpgaRawBypassEnabled() || HttpFpgaCpuFallbackEnabled()) {
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

	// The handler samples runTx only in ST_IDLE (hardware/src/hdl/http_read/handler.sv). runTx is a
	// one-cycle pulse, so a START written while the handler is mid-transfer is dropped on the floor
	// and never retried -- the read below would then block forever on a buffer nothing will ever
	// fill. A previous request that stalled (or a query cancelled with Ctrl-C between trigger and
	// drain) leaves it exactly there, and there is no reset CSR: nothing short of reprogramming the
	// bitstream returns it to IDLE. Detect it here instead of hanging, since the wedge outlives the
	// process and every later run inherits it -- the tell is an unchanged sid across runs, because
	// session_id_q only moves when a fresh tcp_init completes.
	const auto pre_status = http_cfg->debug_status();
	if (HandlerBusy(pre_status)) {
		throw IOException("httpfpga: the FPGA HTTP handler is still busy from an earlier request "
		                  "[%s], and it only accepts a new request from its IDLE state -- this read "
		                  "would be silently dropped and then hang. There is no reset register; "
		                  "reprogram the bitstream to clear it.",
		                  DecodeHttpFpgaStatus(pre_status));
	}

	// Enqueue the destination buffer BEFORE triggering the request. The trigger is a posted CSR
	// write, so the FPGA can start writing body bytes as soon as the response arrives; if no buffer
	// has been enqueued for the bypass stream at that point, the StreamWriter targets whatever
	// allocation the hardware still holds from an earlier read. Acquire-then-trigger closes that
	// window at the cost of nothing but a few microseconds of connection-setup overlap.
	//
	// The bypass stream is unmanaged on the OBM. The HW strips the HTTP header, so exactly `size`
	// body bytes land here — pass that so the OBM allocates a right-sized buffer. Note the OBM
	// rounds capacity up to BYTES_PER_FPGA_TRANSFER (64 KiB), so the hardware is always permitted
	// to write up to 64 KiB regardless of `size`; the drain loop below is the only thing that
	// detects over-delivery.
	auto handle = obm->acquire_output_handle(bypass_stream, size);

	// Now trigger: the handler opens the TCP connection and issues the ranged GET.
	http_cfg->read(bypass_stream, server_ip_, server_port_, path, offset, range_end, /*session*/ 0);

	if (HttpFpgaDebugEnabled()) {
		std::fprintf(stderr, "[httpfpga] read path=%s range=[%llu,%llu] size=%llu\n", path.c_str(),
		             (unsigned long long)offset, (unsigned long long)range_end, (unsigned long long)size);
		// Read the parameters back out of the hardware. The write CSRs are write-only, so this echo
		// is the only confirmation that the values reached the FPGA and were not, say, still in
		// flight when START sampled them.
		std::fprintf(stderr, "[httpfpga]   latched: %s\n",
		             http_cfg->request_echo().describe().c_str());
	}

	// Reports which state a stall is parked in (the `read` nibble: 7=WAIT_NOTIFY, 9=RECV_DATA,
	// 10=FINISH) and how many body bytes have landed. Stops and joins on every exit path.
	unique_ptr<HandlerWatchdog> watchdog;
	if (HttpFpgaDebugEnabled()) {
		watchdog = make_uniq<HandlerWatchdog>(*http_cfg, size);
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
			                  "next chunk %llu [%s]",
			                  (unsigned long long)size, (unsigned long long)copied,
			                  (unsigned long long)buf->size,
			                  DecodeHttpFpgaStatus(http_cfg->debug_status()));
		}
		std::memcpy(static_cast<uint8_t *>(dst) + copied, buf->ptr, buf->size);
		copied += buf->size;
		if (watchdog) {
			watchdog->Progress(copied);
		}
	}
	if (copied != size) {
		// Debug triage: dump the bytes the FPGA actually delivered so they can be diffed against the
		// server's ground truth for this exact range. `cmp` on the two files localizes the loss:
		//   - identical up to `copied`, true file longer  -> bytes lost at the BACK (close/last-beat)
		//   - first difference at offset 0                 -> bytes lost/shifted at the FRONT (header strip)
		//   - first difference somewhere in the middle     -> a seam/framing drop (TOE/normalizer)
		char dump_path[512];
		std::snprintf(dump_path, sizeof(dump_path), "/tmp/httpfpga_short_%llu_%llu.bin",
		              (unsigned long long)offset, (unsigned long long)range_end);
		if (FILE *df = std::fopen(dump_path, "wb")) {
			if (copied > 0) {
				std::fwrite(dst, 1, copied, df);
			}
			std::fclose(df);
			std::fprintf(stderr,
			             "[httpfpga] SHORT: wrote %llu received bytes to %s\n"
			             "[httpfpga] triage: curl -s -r %llu-%llu 'http://%s:%u%s' -o /tmp/httpfpga_true.bin "
			             "&& cmp %s /tmp/httpfpga_true.bin\n",
			             (unsigned long long)copied, dump_path, (unsigned long long)offset,
			             (unsigned long long)range_end, server_host_.c_str(),
			             static_cast<unsigned>(server_port_), path.c_str(), dump_path);
		} else {
			std::fprintf(stderr, "[httpfpga] SHORT: could not open %s for dump\n", dump_path);
		}
		throw IOException("HTTP read short transfer for '%s' range=[%llu,%llu]: requested %llu bytes, "
		                  "got %llu [%s] [latched: %s]",
		                  path, (unsigned long long)offset, (unsigned long long)range_end,
		                  (unsigned long long)size, (unsigned long long)copied,
		                  DecodeHttpFpgaStatus(http_cfg->debug_status()),
		                  http_cfg->request_echo().describe());
	}

	if (HttpFpgaDebugEnabled()) {
		std::fprintf(stderr, "[httpfpga] done path=%s copied=%llu client_state=%u\n", path.c_str(),
		             (unsigned long long)copied, static_cast<unsigned>(http_cfg->client_state()));
	}
}

} // namespace duckdb
