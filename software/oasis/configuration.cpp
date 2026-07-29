#include <algorithm>
#include <cstring>
#include <sstream>
#include <stdexcept>
#include <string>

#include <libstf/profiling.hpp>
#include <oasis/configuration.hpp>

using libstf::Profiler;

namespace oasis {

constexpr const uint32_t RDMA_READ_VADDR_ADDR = 0;
constexpr const uint32_t RDMA_READ_SIZE_ADDR  = 1;

RDMAReadConfig::RDMAReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                               uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs), num_streams_(read_register(1).value()) {}

const std::string rdma_read_prefix = "oasis::RDMAReadConfig::";

void RDMAReadConfig::enqueue_read(libstf::stream_t stream, size_t offset, size_t size) {
    Profiler::open_regions({rdma_read_prefix + "enqueue_read"});
    auto base_vaddr = reinterpret_cast<uintptr_t>(cthread->getQpair()->remote.vaddr);
    auto reg_offset = stream * RDMA_READ_CONFIG_REGS;
    write_register(libstf::ConfigRegister(reg_offset + RDMA_READ_VADDR_ADDR, base_vaddr + offset));
    write_register(libstf::ConfigRegister(reg_offset + RDMA_READ_SIZE_ADDR, size));
    Profiler::close_regions({rdma_read_prefix + "enqueue_read"});
}

const libstf::stream_t RDMAReadConfig::num_streams() const { return num_streams_; }

namespace {

// HttpConfig write map (hardware/src/hdl/http_read/http_config.sv)
constexpr const uint32_t HTTP_SERVER_IP       = 0;
constexpr const uint32_t HTTP_SERVER_PORT     = 1;
constexpr const uint32_t HTTP_PORT_HEX        = 2;
constexpr const uint32_t HTTP_IP_HEX_LEN      = 3;
constexpr const uint32_t HTTP_IP_HEX_W0       = 4;
constexpr const uint32_t HTTP_FILE_LEN        = 8;
constexpr const uint32_t HTTP_FILE_W0         = 9;
constexpr const uint32_t HTTP_NUM_SESSIONS    = 17;
constexpr const uint32_t HTTP_PKG_WORD_COUNT  = 18;
constexpr const uint32_t HTTP_USER_FREQUENCY  = 19;
constexpr const uint32_t HTTP_TIME_IN_SECONDS = 20;
constexpr const uint32_t HTTP_RANGE_BEGIN_LEN = 21;
constexpr const uint32_t HTTP_RANGE_BEGIN_W0  = 22; // 22..25
constexpr const uint32_t HTTP_RANGE_END_LEN   = 26;
constexpr const uint32_t HTTP_RANGE_END_W0    = 27; // 27..30
constexpr const uint32_t HTTP_START           = 31;

// ASCII words transferred per Range endpoint. Range values are absolute file
// offsets, so they scale with file size, not with read size: 2 words (8 digits)
// caps out at ~95 MiB, which any real Parquet file blows past immediately. 4
// words = 16 digits ~ 8.9 PiB.
constexpr const uint32_t HTTP_RANGE_WORDS = 4;
constexpr const uint32_t HTTP_RANGE_MAX_DIGITS = HTTP_RANGE_WORDS * 4;

// ASCII words transferred for the GET path (32 chars) and the Host: IP (16 chars).
constexpr const uint32_t HTTP_FILE_WORDS = 8;
constexpr const uint32_t HTTP_IP_WORDS   = 4;

// http_req_builder assembles the request into a fixed 128-byte buffer (buffer_q[127:0]) with no
// overflow detection -- writes past the end alias instead of failing. The fixed parts are
// "GET " (4) + " HTTP/1.1\r\nHost: " (17) + ":" (1) + port (4) + CRLF (2) +
// "Range: bytes=" (13) + "-" (1) + CRLF (2) + "Connection: close\r\n\r\n" (21) = 65 bytes.
constexpr const uint32_t HTTP_HEADER_BUFFER_BYTES = 128;
constexpr const uint32_t HTTP_HEADER_FIXED_BYTES  = 65;

// Read-side CSRs (see hardware/src/hdl/http_read/http_config.sv).
constexpr const uint32_t HTTP_CLIENT_STATE     = 1;
constexpr const uint32_t HTTP_TOTAL_WORD       = 2;
constexpr const uint32_t HTTP_ECHO_FILE_LEN    = 3;
constexpr const uint32_t HTTP_ECHO_FILE_W0     = 4;
constexpr const uint32_t HTTP_ECHO_FILE_W4     = 5;
constexpr const uint32_t HTTP_ECHO_RANGE_BEGIN = 6;
constexpr const uint32_t HTTP_ECHO_RANGE_END   = 7;
constexpr const uint32_t HTTP_ECHO_SERVER      = 8;

// Packs `s` little-endian into `words`. Throws rather than truncating: a silently shortened path
// makes the FPGA request a different (usually nonexistent) file, and the 404 body then flows through
// the datapath as if it were real data.
void PackAsciiWords(const std::string &s, uint32_t &len, uint32_t *words, size_t n_words,
                    const char *what) {
    if (s.size() > n_words * 4) {
        std::ostringstream msg;
        msg << "HTTP " << what << " is " << s.size() << " characters, but only " << (n_words * 4)
            << " are transferred to the FPGA: '" << s << "'";
        throw std::runtime_error(msg.str());
    }
    len = static_cast<uint32_t>(s.size());
    std::memset(words, 0, n_words * sizeof(uint32_t));
    for (size_t i = 0; i < s.size(); i++) {
        words[i / 4] |= static_cast<uint32_t>(static_cast<uint8_t>(s[i])) << (8 * (i % 4));
    }
}

std::string IpToAscii(uint32_t ip_be) {
    return std::to_string((ip_be >> 24) & 0xff) + "." + std::to_string((ip_be >> 16) & 0xff) + "." +
           std::to_string((ip_be >> 8) & 0xff) + "." + std::to_string(ip_be & 0xff);
}

uint32_t PackPortHex(uint16_t port) {
    std::ostringstream oss;
    oss.width(4);
    oss.fill('0');
    oss << port;
    const auto s = oss.str();
    uint32_t word = 0;
    for (uint32_t i = 0; i < 4; i++) {
        word |= static_cast<uint32_t>(static_cast<uint8_t>(s[i])) << (8 * i);
    }
    return word;
}

} // namespace

HTTPReadConfig::HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                                 uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs) {}

void HTTPReadConfig::read(libstf::stream_t /*stream*/, uint32_t server_ip, uint16_t server_port,
                          const std::string &path, uint64_t range_begin, uint64_t range_end,
                          uint16_t /*session_id*/) {
    const auto ip_ascii    = IpToAscii(server_ip);
    const auto begin_ascii = std::to_string(range_begin);
    const auto end_ascii   = std::to_string(range_end);

    // The length CSRs must never claim more characters than were transferred, or the HW walks past
    // the words it was given and builds a garbage Range: header. Check before packing so the error
    // names the offending field.
    if (begin_ascii.size() > HTTP_RANGE_MAX_DIGITS || end_ascii.size() > HTTP_RANGE_MAX_DIGITS) {
        std::ostringstream msg;
        msg << "HTTP range endpoint does not fit in " << HTTP_RANGE_MAX_DIGITS
            << " ASCII digits: begin=" << range_begin << " end=" << range_end;
        throw std::runtime_error(msg.str());
    }

    const size_t header_bytes = HTTP_HEADER_FIXED_BYTES + path.size() + ip_ascii.size() +
                                begin_ascii.size() + end_ascii.size();
    if (header_bytes > HTTP_HEADER_BUFFER_BYTES) {
        std::ostringstream msg;
        msg << "Assembled HTTP request is " << header_bytes << " bytes but the FPGA request buffer "
            << "holds only " << HTTP_HEADER_BUFFER_BYTES << " (path=" << path.size()
            << " ip=" << ip_ascii.size() << " range=" << begin_ascii.size() << "+"
            << end_ascii.size() << "): '" << path << "'";
        throw std::runtime_error(msg.str());
    }

    uint32_t file_len = 0;
    uint32_t file_words[HTTP_FILE_WORDS] {};
    PackAsciiWords(path, file_len, file_words, HTTP_FILE_WORDS, "GET path");

    uint32_t ip_len = 0;
    uint32_t ip_words[HTTP_IP_WORDS] {};
    PackAsciiWords(ip_ascii, ip_len, ip_words, HTTP_IP_WORDS, "Host: address");

    uint32_t range_begin_len = 0;
    uint32_t range_begin_words[HTTP_RANGE_WORDS] {};
    PackAsciiWords(begin_ascii, range_begin_len, range_begin_words, HTTP_RANGE_WORDS,
                   "Range begin");

    uint32_t range_end_len = 0;
    uint32_t range_end_words[HTTP_RANGE_WORDS] {};
    PackAsciiWords(end_ascii, range_end_len, range_end_words, HTTP_RANGE_WORDS, "Range end");

    write_register(libstf::ConfigRegister(HTTP_SERVER_IP, server_ip));
    write_register(libstf::ConfigRegister(HTTP_SERVER_PORT, server_port));
    write_register(libstf::ConfigRegister(HTTP_PORT_HEX, PackPortHex(server_port)));
    write_register(libstf::ConfigRegister(HTTP_IP_HEX_LEN, ip_len));
    for (uint32_t i = 0; i < HTTP_IP_WORDS; i++) {
        write_register(libstf::ConfigRegister(HTTP_IP_HEX_W0 + i, ip_words[i]));
    }
    write_register(libstf::ConfigRegister(HTTP_FILE_LEN, file_len));
    for (uint32_t i = 0; i < HTTP_FILE_WORDS; i++) {
        write_register(libstf::ConfigRegister(HTTP_FILE_W0 + i, file_words[i]));
    }
    write_register(libstf::ConfigRegister(HTTP_NUM_SESSIONS, 1));
    write_register(libstf::ConfigRegister(HTTP_PKG_WORD_COUNT, 16));
    write_register(libstf::ConfigRegister(HTTP_USER_FREQUENCY, 256ULL * 1024ULL * 1024ULL));
    write_register(libstf::ConfigRegister(HTTP_TIME_IN_SECONDS, 0));
    write_register(libstf::ConfigRegister(HTTP_RANGE_BEGIN_LEN, range_begin_len));
    for (uint32_t i = 0; i < HTTP_RANGE_WORDS; i++) {
        write_register(libstf::ConfigRegister(HTTP_RANGE_BEGIN_W0 + i, range_begin_words[i]));
    }
    write_register(libstf::ConfigRegister(HTTP_RANGE_END_LEN, range_end_len));
    for (uint32_t i = 0; i < HTTP_RANGE_WORDS; i++) {
        write_register(libstf::ConfigRegister(HTTP_RANGE_END_W0 + i, range_end_words[i]));
    }

    // Barrier before START. The parameter writes above are posted MMIO stores; the START
    // write is just another posted store, so nothing guarantees the parameter registers have
    // been latched by HttpConfig before the START beat samples the cfg snapshot. If START wins
    // the race, the handler builds its GET from a *stale* cfg — the "file path is one run behind"
    // symptom (the bring-up tool papered over this with sleep(1) before START). A CSR read is
    // non-posted and cannot be reordered ahead of the prior writes to the same AXI-Lite device,
    // so it drains them and orders START strictly after every parameter write.
    (void)read_register(HTTP_CLIENT_STATE);

    write_register(libstf::ConfigRegister(HTTP_START, 1));
}

uint8_t HTTPReadConfig::client_state() {
    return static_cast<uint8_t>(read_register(HTTP_CLIENT_STATE).value() & 0xF);
}

uint32_t HTTPReadConfig::debug_status() {
    return static_cast<uint32_t>(read_register(HTTP_TOTAL_WORD).value());
}

HTTPRequestEcho HTTPReadConfig::request_echo() {
    const auto range_begin = read_register(HTTP_ECHO_RANGE_BEGIN).value();
    const auto range_end   = read_register(HTTP_ECHO_RANGE_END).value();
    const auto server      = read_register(HTTP_ECHO_SERVER).value();

    HTTPRequestEcho echo {};
    echo.file_len        = static_cast<uint32_t>(read_register(HTTP_ECHO_FILE_LEN).value());
    echo.file_w0         = static_cast<uint32_t>(read_register(HTTP_ECHO_FILE_W0).value());
    echo.file_w4         = static_cast<uint32_t>(read_register(HTTP_ECHO_FILE_W4).value());
    echo.range_begin_w0  = static_cast<uint32_t>(range_begin & 0xFFFFFFFFULL);
    echo.range_begin_len = static_cast<uint8_t>((range_begin >> 32) & 0xFF);
    echo.range_end_w0    = static_cast<uint32_t>(range_end & 0xFFFFFFFFULL);
    echo.range_end_len   = static_cast<uint8_t>((range_end >> 32) & 0xFF);
    echo.server_ip       = static_cast<uint32_t>(server & 0xFFFFFFFFULL);
    echo.server_port     = static_cast<uint16_t>((server >> 32) & 0xFFFF);
    return echo;
}

// Renders the little-endian ASCII word pair the hardware latched, so a mismatch is readable
// ("h-10" vs "h-1/") instead of two hex blobs.
std::string HTTPRequestEcho::describe() const {
    auto word_to_ascii = [](uint32_t w) {
        std::string s;
        for (int i = 0; i < 4; i++) {
            const auto c = static_cast<char>((w >> (8 * i)) & 0xFF);
            s += (c >= 0x20 && c < 0x7F) ? c : '.';
        }
        return s;
    };

    std::ostringstream oss;
    oss << "path_len=" << file_len << " path[0:4]='" << word_to_ascii(file_w0) << "'"
        << " path[16:20]='" << word_to_ascii(file_w4) << "'"
        << " range=" << static_cast<unsigned>(range_begin_len) << ":'"
        << word_to_ascii(range_begin_w0) << "'-" << static_cast<unsigned>(range_end_len) << ":'"
        << word_to_ascii(range_end_w0) << "'"
        << " ip=0x" << std::hex << server_ip << std::dec << " port=" << server_port;
    return oss.str();
}

uint64_t HTTPReadConfig::read_stream_register(libstf::stream_t /*stream*/, uint32_t reg) {
    assert(reg < HTTP_READ_CONFIG_REGS);
    return cthread->getCSR(addr_offset + reg);
}

} // namespace oasis
