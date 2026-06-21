#include <algorithm>
#include <cstring>
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

constexpr const uint32_t HTTP_SERVER_IP   = 0;
constexpr const uint32_t HTTP_SERVER_PORT = 1;
constexpr const uint32_t HTTP_FILE_LEN    = 2;
constexpr const uint32_t HTTP_FILE_W0     = 3;
constexpr const uint32_t HTTP_RANGE_BEGIN = 11;
constexpr const uint32_t HTTP_RANGE_END   = 12;
constexpr const uint32_t HTTP_SIZE        = 13;
constexpr const uint32_t HTTP_START       = 14;
constexpr const uint32_t HTTP_CLIENT_STATE = 1;

void PackPathWords(const std::string &path, uint32_t &file_len, uint32_t words[8]) {
    const size_t n = std::min(path.size(), size_t {32});
    file_len = static_cast<uint32_t>(n);
    for (auto &word : words) {
        word = 0;
    }
    for (size_t i = 0; i < n; i++) {
        words[i / 4] |= static_cast<uint32_t>(static_cast<uint8_t>(path[i])) << (8 * (i % 4));
    }
}

} // namespace

HTTPReadConfig::HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                                 uint32_t num_regs)
    : Config(cthread, addr_offset, num_regs) {}

void HTTPReadConfig::read(libstf::stream_t stream, uint32_t server_ip, uint16_t server_port,
                          const std::string &path, uint64_t range_begin, uint64_t range_end) {
    uint32_t file_len = 0;
    uint32_t file_words[8] {};
    PackPathWords(path, file_len, file_words);

    const auto reg_base = stream * HTTP_READ_CONFIG_REGS;
    write_register(libstf::ConfigRegister(reg_base + HTTP_SERVER_IP, server_ip));
    write_register(libstf::ConfigRegister(reg_base + HTTP_SERVER_PORT, server_port));
    write_register(libstf::ConfigRegister(reg_base + HTTP_FILE_LEN, file_len));
    for (uint32_t i = 0; i < 8; i++) {
        write_register(libstf::ConfigRegister(reg_base + HTTP_FILE_W0 + i, file_words[i]));
    }
    write_register(libstf::ConfigRegister(reg_base + HTTP_RANGE_BEGIN, range_begin));
    write_register(libstf::ConfigRegister(reg_base + HTTP_RANGE_END, range_end));
    write_register(libstf::ConfigRegister(reg_base + HTTP_SIZE,
                                            static_cast<uint64_t>(range_end - range_begin + 1)));
    write_register(libstf::ConfigRegister(reg_base + HTTP_START, 1));
}

uint8_t HTTPReadConfig::client_state() const {
    return static_cast<uint8_t>(read_register(HTTP_CLIENT_STATE).value() & 0xF);
}

} // namespace oasis
