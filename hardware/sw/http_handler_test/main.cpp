// Adapted from hardware/copy_from_working/src/main.cpp for the oasis HTTP bitstream.
//
// Discovers HttpConfig by ID 0x485454. HW opens TCP itself.
// Also enqueues a MemConfig buffer on the bypass stream so OutputWriter can DMA
// the stripped HTTP body to the host, then prints it.

#include <iostream>
#include <sstream>
#include <string>
#include <stdexcept>
#include <cstdint>
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <iomanip>
#include <mutex>
#include <thread>
#include <vector>
#include <boost/program_options.hpp>
#include <unistd.h>

#include <coyote/cThread.hpp>
#include <coyote/cOps.hpp>

#define DEFAULT_VFPGA_ID 0
#define MHZ (1024ULL * 1024ULL)

constexpr uint64_t OASIS_SYSTEM_ID   = 0x0A515;
constexpr uint64_t HTTP_CONFIG_ID    = 0x0000000000485454ULL; // "HTT"
constexpr uint64_t MEM_CONFIG_ID     = 0x0ULL;
constexpr uint32_t HTTP_NUM_WRITE    = 32; // 31 params + START (4-word range)

constexpr uint32_t GLOBAL_SYSTEM_ID   = 0;
constexpr uint32_t GLOBAL_NUM_CONFIGS = 1;

// Must match libstf::common.hpp / OutputWriter interrupt encoding.
constexpr uint32_t BYTES_PER_FPGA_TRANSFER           = 65536;
constexpr uint32_t INTERRUPT_TRANSFER_SIZE_BITS      = 28;
constexpr uint32_t BUFFER_SIZE_BITS =
    INTERRUPT_TRANSFER_SIZE_BITS - 16; // floor_log2(65536) == 16
constexpr uint32_t FPGA_INTERRUPT_STREAM_ID_BITS     = 3;
constexpr uint32_t FPGA_INTERRUPT_TRANSFER_SIZE_BITS = 28;

enum class HttpLocal : uint32_t {
    SERVER_IP       = 0,
    SERVER_PORT     = 1,
    PORT_HEX        = 2,
    IP_HEX_LEN      = 3,
    IP_HEX_W0       = 4,
    IP_HEX_W1       = 5,
    IP_HEX_W2       = 6,
    IP_HEX_W3       = 7,
    FILE_LEN        = 8,
    FILE_W0         = 9,
    FILE_W1         = 10,
    FILE_W2         = 11,
    FILE_W3         = 12,
    FILE_W4         = 13,
    FILE_W5         = 14,
    FILE_W6         = 15,
    FILE_W7         = 16,
    NUM_SESSIONS    = 17,
    PKG_WORD_COUNT  = 18,
    USER_FREQUENCY  = 19,
    TIME_IN_SECONDS = 20,
    RANGE_BEGIN_LEN = 21,
    RANGE_BEGIN_W0  = 22,
    RANGE_BEGIN_W1  = 23,
    RANGE_BEGIN_W2  = 24,
    RANGE_BEGIN_W3  = 25,
    RANGE_END_LEN   = 26,
    RANGE_END_W0    = 27,
    RANGE_END_W1    = 28,
    RANGE_END_W2    = 29,
    RANGE_END_W3    = 30,
    START           = 31,
    ID              = 0,
    CLIENT_STATE    = 1,
    TOTAL_WORD      = 2,
};

struct IrqState {
    std::mutex              m;
    std::condition_variable cv;
    uint32_t                stream_id     = 0;
    uint32_t                bytes_written = 0;
    bool                    last          = false;
    bool                    got           = false;
};

static IrqState g_irq;
static std::atomic<uint32_t> g_irq_count{0};

static void on_fpga_irq(int value) {
    const uint32_t u = static_cast<uint32_t>(value);
    const uint32_t stream_id =
        u & ((1u << FPGA_INTERRUPT_STREAM_ID_BITS) - 1u);
    const uint32_t bytes_written =
        (u >> FPGA_INTERRUPT_STREAM_ID_BITS) &
        ((1u << FPGA_INTERRUPT_TRANSFER_SIZE_BITS) - 1u);
    const bool last =
        ((u >> (FPGA_INTERRUPT_STREAM_ID_BITS + FPGA_INTERRUPT_TRANSFER_SIZE_BITS)) & 1u) != 0;

    {
        std::lock_guard<std::mutex> lk(g_irq.m);
        g_irq.stream_id     = stream_id;
        g_irq.bytes_written = bytes_written;
        g_irq.last          = last;
        g_irq.got           = true;
    }
    g_irq_count.fetch_add(1);
    g_irq.cv.notify_all();

    std::cout << "[IRQ] value=0x" << std::hex << u << std::dec
              << " stream=" << stream_id
              << " bytes=" << bytes_written
              << " last=" << last << std::endl;
}

static void validate_ip_ascii(const std::string& ip_str) {
    if (ip_str.empty() || ip_str.size() > 15) {
        throw std::invalid_argument("IP ASCII length must be 1..15");
    }
    int dots = 0;
    for (char c : ip_str) {
        if (c == '.') {
            dots++;
        } else if (c < '0' || c > '9') {
            throw std::invalid_argument("IP must contain only digits and dots");
        }
    }
    if (dots != 3) {
        throw std::invalid_argument("IP must have 3 dots (A.B.C.D)");
    }
}

static void ensure_u32(const char* name, uint64_t v) {
    if (v > 0xFFFFFFFFull)
        throw std::invalid_argument(std::string("--") + name + " out of range (0..4294967295)");
}

static void pack_file_path(const std::string& file, std::array<uint32_t, 8>& words, uint32_t& len) {
    words.fill(0);
    len = static_cast<uint32_t>(std::min<size_t>(file.size(), words.size() * 4));
    for (uint32_t i = 0; i < len; ++i) {
        uint32_t w = i / 4;
        uint32_t b = i % 4;
        words[w] |= static_cast<uint32_t>(static_cast<uint8_t>(file[i])) << (8 * b);
    }
}

static void pack_ip_ascii(const std::string& ip_ascii, std::array<uint32_t, 4>& words, uint32_t& len) {
    words.fill(0);
    len = static_cast<uint32_t>(std::min<size_t>(ip_ascii.size(), words.size() * 4));
    for (uint32_t i = 0; i < len; ++i) {
        uint32_t w = i / 4;
        uint32_t b = i % 4;
        words[w] |= static_cast<uint32_t>(static_cast<uint8_t>(ip_ascii[i])) << (8 * b);
    }
}

static uint32_t parseIpBE(const std::string& ip_str) {
    std::istringstream iss(ip_str);
    std::string tok; uint32_t b[4]; int i = 0;
    while (std::getline(iss, tok, '.')) {
        if (i >= 4) throw std::invalid_argument("IP has more than 4 octets");
        tok.erase(tok.begin(), std::find_if(tok.begin(), tok.end(),
                   [](unsigned char c){ return !std::isspace(c); }));
        tok.erase(std::find_if(tok.rbegin(), tok.rend(),
                   [](unsigned char c){ return !std::isspace(c); }).base(), tok.end());
        if (tok.empty()) throw std::invalid_argument("Empty IP octet");
        char* endp = nullptr;
        long v = std::strtol(tok.c_str(), &endp, 10);
        if (*endp != '\0' || v < 0 || v > 255)
            throw std::invalid_argument(std::string("Invalid IP octet: ") + tok);
        b[i++] = static_cast<uint32_t>(v);
    }
    if (i != 4) throw std::invalid_argument("IP must have 4 octets");
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | (b[3] << 0);
}

static std::string ipToStr(uint32_t ip_be) {
    return std::to_string((ip_be>>24)&0xFF) + "." +
           std::to_string((ip_be>>16)&0xFF) + "." +
           std::to_string((ip_be>> 8)&0xFF) + "." +
           std::to_string((ip_be>> 0)&0xFF);
}

static uint32_t pack_port_hex_word(uint16_t port) {
    std::ostringstream oss;
    oss.width(4);
    oss.fill('0');
    oss << port;
    std::string port_str = oss.str();

    uint32_t word = 0;
    for (uint32_t i = 0; i < 4; ++i) {
        word |= static_cast<uint32_t>(static_cast<uint8_t>(port_str[i])) << (8 * i);
    }
    return word;
}

static uint32_t find_config_base(coyote::cThread& t, uint64_t want_id, const char* name,
                                 uint32_t min_write_regs = 0) {
    const uint64_t system_id = t.getCSR(GLOBAL_SYSTEM_ID);
    const uint64_t num_configs = t.getCSR(GLOBAL_NUM_CONFIGS);

    std::cout << "reg0 (system_id)   = 0x" << std::hex << system_id << std::dec << std::endl;
    std::cout << "reg1 (num_configs) = " << num_configs << std::endl;

    if (system_id != OASIS_SYSTEM_ID) {
        std::cerr << "WARNING: expected oasis SYSTEM_ID 0x" << std::hex << OASIS_SYSTEM_ID
                  << std::dec << std::endl;
    }
    if (num_configs == 0 || num_configs > 16) {
        throw std::runtime_error("num_configs looks invalid");
    }

    uint32_t start = static_cast<uint32_t>(2 + num_configs);
    for (uint64_t i = 0; i < num_configs; ++i) {
        const uint32_t end = static_cast<uint32_t>(t.getCSR(static_cast<uint32_t>(2 + i)));
        const uint64_t id = t.getCSR(start);
        std::cout << "config[" << i << "] [" << start << "," << end
                  << ") id=0x" << std::hex << id << std::dec << std::endl;
        if (id == want_id) {
            if (min_write_regs && end < start + min_write_regs) {
                throw std::runtime_error(std::string(name) + " address space too small");
            }
            return start;
        }
        start = end;
    }
    throw std::runtime_error(std::string(name) + " not found — wrong bitstream?");
}

static size_t round_up_transfer(size_t n) {
    if (n == 0) n = 1;
    return ((n + BYTES_PER_FPGA_TRANSFER - 1) / BYTES_PER_FPGA_TRANSFER) * BYTES_PER_FPGA_TRANSFER;
}

static void enqueue_mem_buffer(coyote::cThread& t, uint32_t mem_base, uint32_t stream,
                               void* ptr, size_t capacity) {
    if (capacity == 0 || (capacity % BYTES_PER_FPGA_TRANSFER) != 0) {
        throw std::runtime_error("buffer capacity must be a multiple of 65536");
    }
    const uint64_t vaddr = reinterpret_cast<uint64_t>(ptr);
    const uint64_t n_xfer = capacity / BYTES_PER_FPGA_TRANSFER;
    const uint64_t word = (vaddr << BUFFER_SIZE_BITS) | n_xfer;
    t.setCSR(word, mem_base + stream);
    std::cout << "[MEM] enqueue stream=" << stream
              << " vaddr=0x" << std::hex << vaddr << std::dec
              << " capacity=" << capacity
              << " n_xfer=" << n_xfer << std::endl;
}

static void print_body(const uint8_t* data, size_t nbytes, size_t print_max) {
    const size_t n = std::min(nbytes, print_max);
    std::cout << "\n======== vFPGA bypass body (" << nbytes << " bytes"
              << (nbytes > print_max ? ", showing first " + std::to_string(print_max) : "")
              << ") ========\n";

    // Hex + ASCII rows of 16
    for (size_t off = 0; off < n; off += 16) {
        std::cout << std::hex << std::setw(8) << std::setfill('0') << off << "  ";
        for (size_t i = 0; i < 16; ++i) {
            if (off + i < n) {
                std::cout << std::hex << std::setw(2) << std::setfill('0')
                          << static_cast<unsigned>(data[off + i]) << ' ';
            } else {
                std::cout << "   ";
            }
            if (i == 7) std::cout << ' ';
        }
        std::cout << " |";
        for (size_t i = 0; i < 16 && off + i < n; ++i) {
            const unsigned char c = data[off + i];
            std::cout << (std::isprint(c) ? static_cast<char>(c) : '.');
        }
        std::cout << "|\n";
    }
    std::cout << std::dec << std::setfill(' ');

    // Best-effort text view
    std::cout << "-------- as text (printable / '.') --------\n";
    for (size_t i = 0; i < n; ++i) {
        const unsigned char c = data[i];
        if (c == '\n' || c == '\r' || c == '\t' || std::isprint(c))
            std::cout << static_cast<char>(c);
        else
            std::cout << '.';
    }
    std::cout << "\n==========================================\n";
}

int main(int argc, char* argv[]) {
    namespace po = boost::program_options;

    std::string ip_str;
    std::string server_ip_str;
    unsigned int sessions = 1;
    uint64_t words = 16;
    uint64_t timeS = 0;
    uint16_t port = 9000;
    std::string file = "/testbench/test.csv";
    uint64_t range_begin = 0;
    uint64_t range_end   = 50000;
    bool skip_arp = false;
    bool no_prime = false;
    uint64_t out_bytes = 0;   // 0 => derive from range
    uint64_t print_max = 4096;
    uint64_t irq_timeout_s = 30;

    po::options_description desc("oasis http_handler_test (body → host via bypass/OutputWriter)");
    desc.add_options()
        ("help,h", "Show help")
        ("ip,i",       po::value<std::string>(&ip_str)->required(),                     "HTTP Host IP A.B.C.D (required)")
        ("server-ip",  po::value<std::string>(&server_ip_str),                           "TCP connect IP A.B.C.D (defaults to --ip)")
        ("sessions,s", po::value<unsigned int>(&sessions)->default_value(1),            "numSessions (0..65535)")
        ("words,w",    po::value<uint64_t>(&words)->default_value(16),                  "PKG_WORD_COUNT (0..4294967295)")
        ("time,t",     po::value<uint64_t>(&timeS)->default_value(0),                   "timeInSeconds (0..4294967295)")
        ("port,p",     po::value<uint16_t>(&port)->default_value(9000),                 "Port number (default 9000)")
        ("file,f",     po::value<std::string>(&file)->default_value("/testbench/test.csv"),
                        "File path for GET (default /testbench/test.csv)")
        ("begin,b",    po::value<uint64_t>(&range_begin)->default_value(0),
                        "Range header start byte (default 0)")
        ("end,e",      po::value<uint64_t>(&range_end)->default_value(50000),
                        "Range header end byte (default 50000)")
        ("out-bytes",  po::value<uint64_t>(&out_bytes)->default_value(0),
                        "Expected body bytes to DMA (0 = end-begin+1)")
        ("print-max",  po::value<uint64_t>(&print_max)->default_value(4096),
                        "Max bytes to print from body")
        ("irq-timeout", po::value<uint64_t>(&irq_timeout_s)->default_value(30),
                        "Seconds to wait for OutputWriter IRQ after START")
        ("skip-arp",   po::bool_switch(&skip_arp),
                        "Do not call doArpLookup before START (TOE can ARP on SYN)")
        ("no-prime",   po::bool_switch(&no_prime),
                        "Skip the throwaway priming request. Only correct once the HW "
                        "tcp_read session filter lands; by default we prime once to flush "
                        "the stale one-run-behind notification.");
    po::variables_map vm;
    try {
        po::store(po::parse_command_line(argc, argv, desc), vm);
        if (vm.count("help")) { std::cout << desc << "\n"; return EXIT_SUCCESS; }
        po::notify(vm);
    } catch (const po::error& e) {
        std::cerr << "Argument error: " << e.what() << "\n\n" << desc << std::endl;
        return EXIT_FAILURE;
    }

    ensure_u32("words", words);
    ensure_u32("time",  timeS);
    ensure_u32("begin", range_begin);
    ensure_u32("end",   range_end);
    if (range_end < range_begin)
        throw std::invalid_argument("--end must be >= --begin");

    validate_ip_ascii(ip_str);
    uint32_t server_ip_be = parseIpBE(server_ip_str.empty() ? ip_str : server_ip_str);
    std::array<uint32_t, 4> ip_ascii_words;
    uint32_t ip_ascii_len = 0;
    pack_ip_ascii(ip_str, ip_ascii_words, ip_ascii_len);
    uint32_t port_hex_word0 = pack_port_hex_word(port);

    std::array<uint32_t, 8> file_words;
    uint32_t file_len = 0;
    pack_file_path(file, file_words, file_len);

    std::array<uint32_t, 8> range_begin_words;
    std::array<uint32_t, 8> range_end_words;
    uint32_t range_begin_len = 0;
    uint32_t range_end_len = 0;
    pack_file_path(std::to_string(range_begin), range_begin_words, range_begin_len);
    pack_file_path(std::to_string(range_end),   range_end_words,   range_end_len);
    if (range_begin_len == 0 || range_begin_len > 16)
        throw std::invalid_argument("--begin must produce 1..16 ASCII digits");
    if (range_end_len == 0 || range_end_len > 16)
        throw std::invalid_argument("--end must produce 1..16 ASCII digits");

    // ISR must be registered at construction.
    coyote::cThread coyote_thread(DEFAULT_VFPGA_ID, getpid(), /*device*/ 0, on_fpga_irq);

    std::cout << "[CFG] sessions=" << sessions
              << " words=" << words
              << " time="  << timeS
              << " http_ip=" << ip_str
              << " server_ip=" << ipToStr(server_ip_be)
              << " (ascii_len=" << ip_ascii_len << ")"
              << " port=" << port
              << " file=\"" << file << "\""
              << " range=" << range_begin << "-" << range_end
              << std::endl;

    const uint32_t mem_base = find_config_base(coyote_thread, MEM_CONFIG_ID, "MemConfig");
    const uint32_t http_base = find_config_base(coyote_thread, HTTP_CONFIG_ID, "HttpConfig",
                                               HTTP_NUM_WRITE);
    std::cout << "MemConfig  base CSR = " << mem_base << std::endl;
    std::cout << "HttpConfig base CSR = " << http_base << std::endl;

    const uint64_t num_streams = coyote_thread.getCSR(mem_base + 1);
    if (num_streams == 0 || num_streams > 16) {
        throw std::runtime_error("MemConfig num_streams looks invalid");
    }
    const uint32_t bypass_stream = static_cast<uint32_t>(num_streams - 1);
    std::cout << "num_streams=" << num_streams
              << " bypass_stream=" << bypass_stream << std::endl;

    const size_t expected_body =
        out_bytes != 0 ? static_cast<size_t>(out_bytes)
                       : static_cast<size_t>(range_end - range_begin + 1);
    const size_t out_cap = round_up_transfer(expected_body);
    uint8_t* out_buf = static_cast<uint8_t*>(
        coyote_thread.getMem({coyote::CoyoteAllocType::HPF, out_cap}));
    if (!out_buf) {
        throw std::runtime_error("getMem failed for output buffer");
    }
    // The OW buffer is (re-)armed inside fire_and_wait immediately before each START.

    auto wr = [&](HttpLocal reg, uint64_t val) {
        coyote_thread.setCSR(val, http_base + static_cast<uint32_t>(reg));
    };
    auto rd = [&](HttpLocal reg) -> uint64_t {
        return coyote_thread.getCSR(http_base + static_cast<uint32_t>(reg));
    };

    if (!skip_arp) {
        const uint32_t arp_ip = __builtin_bswap32(server_ip_be);
        std::cout << "doArpLookup(0x" << std::hex << arp_ip << std::dec << ") ..." << std::endl;
        coyote_thread.doArpLookup(arp_ip);
        sleep(1);
    }

    wr(HttpLocal::SERVER_IP,       server_ip_be);
    wr(HttpLocal::SERVER_PORT,     port);
    wr(HttpLocal::PORT_HEX,        port_hex_word0);
    wr(HttpLocal::IP_HEX_LEN,      ip_ascii_len);
    wr(HttpLocal::IP_HEX_W0,       ip_ascii_words[0]);
    wr(HttpLocal::IP_HEX_W1,       ip_ascii_words[1]);
    wr(HttpLocal::IP_HEX_W2,       ip_ascii_words[2]);
    wr(HttpLocal::IP_HEX_W3,       ip_ascii_words[3]);
    wr(HttpLocal::FILE_LEN,        file_len);
    wr(HttpLocal::FILE_W0,         file_words[0]);
    wr(HttpLocal::FILE_W1,         file_words[1]);
    wr(HttpLocal::FILE_W2,         file_words[2]);
    wr(HttpLocal::FILE_W3,         file_words[3]);
    wr(HttpLocal::FILE_W4,         file_words[4]);
    wr(HttpLocal::FILE_W5,         file_words[5]);
    wr(HttpLocal::FILE_W6,         file_words[6]);
    wr(HttpLocal::FILE_W7,         file_words[7]);
    wr(HttpLocal::NUM_SESSIONS,    sessions);
    wr(HttpLocal::PKG_WORD_COUNT,  words);
    wr(HttpLocal::USER_FREQUENCY,  256ULL * MHZ);
    wr(HttpLocal::TIME_IN_SECONDS, timeS);
    wr(HttpLocal::RANGE_BEGIN_LEN, range_begin_len);
    wr(HttpLocal::RANGE_BEGIN_W0,  range_begin_words[0]);
    wr(HttpLocal::RANGE_BEGIN_W1,  range_begin_words[1]);
    wr(HttpLocal::RANGE_BEGIN_W2,  range_begin_words[2]);
    wr(HttpLocal::RANGE_BEGIN_W3,  range_begin_words[3]);
    wr(HttpLocal::RANGE_END_LEN,   range_end_len);
    wr(HttpLocal::RANGE_END_W0,    range_end_words[0]);
    wr(HttpLocal::RANGE_END_W1,    range_end_words[1]);
    wr(HttpLocal::RANGE_END_W2,    range_end_words[2]);
    wr(HttpLocal::RANGE_END_W3,    range_end_words[3]);
    std::cout << "file=" << file << " range=" << range_begin << "-" << range_end << std::endl;
    // One request cycle: (re-)arm the OW buffer, pulse START, wait for the body DMA.
    // The config registers written above are left untouched between fires, so every
    // call issues the SAME GET — which is what makes the priming scheme below work.
    // Returns the body bytes DMA'd for this fire.
    auto fire_and_wait = [&](const char* label) -> uint32_t {
        // Re-arm the OutputWriter: flush any stale enqueue, clear + enqueue our buffer.
        coyote_thread.setCSR(1, mem_base + static_cast<uint32_t>(num_streams));
        std::memset(out_buf, 0, out_cap);
        enqueue_mem_buffer(coyote_thread, mem_base, bypass_stream, out_buf, out_cap);

        // Reset the IRQ capture so we only observe THIS fire's completion.
        {
            std::lock_guard<std::mutex> lk(g_irq.m);
            g_irq.got  = false;
            g_irq.last = false;
        }

        // Barrier before START: a CSR read is non-posted and cannot be reordered ahead of
        // the prior parameter writes, so it drains the posted MMIO store buffer and orders
        // START strictly after every config write (a plain sleep would not drain it).
        (void)rd(HttpLocal::CLIENT_STATE);
        wr(HttpLocal::START, 1);
        std::cout << "[" << label << "] client_state after START = "
                  << rd(HttpLocal::CLIENT_STATE) << std::endl;

        while (rd(HttpLocal::CLIENT_STATE) == 0) {
            sleep(1);
            std::cout << "waiting leave IDLE, state=" << rd(HttpLocal::CLIENT_STATE) << std::endl;
        }

        if (timeS > 0) {
            sleep(static_cast<unsigned int>(timeS));
        }

        // Wait for OutputWriter IRQ (body DMA) and/or HTTP FSM back to IDLE.
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::seconds(irq_timeout_s);
        uint32_t body_bytes = 0;
        bool got_irq = false;

        while (std::chrono::steady_clock::now() < deadline) {
            {
                std::unique_lock<std::mutex> lk(g_irq.m);
                if (g_irq.got) {
                    got_irq = true;
                    body_bytes = g_irq.bytes_written;
                    if (g_irq.stream_id != bypass_stream) {
                        std::cerr << "WARNING: IRQ stream " << g_irq.stream_id
                                  << " != bypass " << bypass_stream << std::endl;
                    }
                    g_irq.got = false;
                    if (g_irq.last) break;
                }
            }

            const uint64_t st = rd(HttpLocal::CLIENT_STATE);
            std::cout << "running, state=" << st
                      << " total_word=" << rd(HttpLocal::TOTAL_WORD)
                      << " irq_count=" << g_irq_count.load() << std::endl;
            if (st == 0 && got_irq) break;
            if (st == 0 && !got_irq) {
                // FSM done but no body IRQ yet — keep waiting a bit for late DMA.
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                continue;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }

        std::cout << "[DONE " << label << "] total_word=" << rd(HttpLocal::TOTAL_WORD)
                  << " client_state=" << rd(HttpLocal::CLIENT_STATE)
                  << " irq_count=" << g_irq_count.load()
                  << " body_bytes=" << body_bytes << std::endl;

        if (!got_irq) {
            std::cerr << "WARNING: no OutputWriter IRQ for " << label
                      << " — is body wired and bitstream rebuilt?\n";
            body_bytes = static_cast<uint32_t>(std::min(expected_body, out_cap));
        }
        return body_bytes;
    };

    // The FPGA hands back a body one run behind: the shared TOE notification FIFO still
    // holds the previous connection's notification, so run N's tcp_read pops THAT and DMAs
    // run (N-1)'s body, while run N's own body waits in the FIFO for the next run. That is
    // why a single request always returns the previous path's data and you had to run the
    // program twice by hand. We reproduce that second run in-process: fire one throwaway
    // "prime" request (its stale body is discarded), then read the real body on the second
    // fire. Because the config registers are identical across both fires, the second fire
    // pops exactly the notification the first fire's request generated -> current data.
    // The proper fix is the tcp_read session filter in hardware; this is the SW workaround.
    if (!no_prime) {
        std::cout << "==> priming request (result discarded to flush the stale notification)"
                  << std::endl;
        (void)fire_and_wait("prime");
    }
    const uint32_t body_bytes = fire_and_wait("read");

    print_body(out_buf, body_bytes, static_cast<size_t>(print_max));
    return EXIT_SUCCESS;
}
