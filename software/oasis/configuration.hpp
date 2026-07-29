#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <cstdint>
#include <libstf/configuration.hpp>
#include <string>

namespace oasis {

constexpr const uint64_t OASIS_SYSTEM_ID = 0x0A515;

constexpr const uint64_t RDMA_READ_CONFIG_REGS = 2;
constexpr const uint64_t RDMA_READ_CONFIG_ID   = 0x2f966a70f04c0e93;

// Matches hardware HttpConfig (31 params [0..30] + START at 31 = 32 regs). ID string "HTT".
// Kept in sync with hardware/src/hdl/http_read/http_config.sv (NUM_PARAM_REGS=31, START_ADDR=31).
constexpr const uint64_t HTTP_READ_CONFIG_REGS = 32;
constexpr const uint64_t HTTP_READ_CONFIG_ID   = 0x0000000000485454;

/**
 * Configues a hardware RDMARead module to properly process the next page
 */
class RDMAReadConfig : public libstf::Config {
  public:
    RDMAReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset,
                   uint32_t num_regs);

    /**
     * Triggers a remote read using the RDMARead module.
     *
     * Offsets are relative to the base virtual address of the remote RDMA region. initRDMA must 
     * have exchanged queue pairs before the first enqueue_read().
     *
     * @param stream The Coyote stream on which to perform the read.
     * @param offset The offset, relative to the remote region's base vaddr, to read from.
     * @param size   The number of bytes to read.
     */
    void enqueue_read(libstf::stream_t stream, size_t offset, size_t size);

    const libstf::stream_t num_streams() const;

    static constexpr uint64_t ID = RDMA_READ_CONFIG_ID;

  private:
    libstf::stream_t num_streams_;
};

/**
 * Snapshot of the request parameters the hardware actually latched, read back from HttpConfig read
 * CSRs 3..8. The parameter write registers are write-only, so this is the only way to confirm that
 * the CSR writes landed before START sampled them.
 */
struct HTTPRequestEcho {
    uint32_t file_len        = 0;
    uint32_t file_w0         = 0; // GET path characters 0..3
    uint32_t file_w4         = 0; // GET path characters 16..19
    uint32_t range_begin_w0  = 0; // first four ASCII digits of the range start
    uint8_t  range_begin_len = 0;
    uint32_t range_end_w0    = 0;
    uint8_t  range_end_len   = 0;
    uint32_t server_ip       = 0;
    uint16_t server_port     = 0;

    /// One-line human-readable rendering, with the ASCII words decoded.
    std::string describe() const;
};

/**
 * Dirty bring-up of hardware HttpConfig + handler (HW TCP open).
 * Writes the full CSR map and pulses START. No body return path yet.
 */
class HTTPReadConfig : public libstf::Config {
  public:
    HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs);

    /// Fire one ranged GET. `stream` / `session_id` ignored (single HttpConfig; HW opens).
    void read(libstf::stream_t stream, uint32_t server_ip, uint16_t server_port, const std::string &path,
              uint64_t range_begin, uint64_t range_end, uint16_t session_id);

    uint8_t client_state();

    /// Read CSR 2: packed FSM status word (layout defined by `totalWord` in handler.sv).
    uint32_t debug_status();

    /// Read CSRs 3..8: the request parameters currently latched in hardware.
    HTTPRequestEcho request_echo();

    uint64_t read_stream_register(libstf::stream_t stream, uint32_t reg);

    static constexpr uint64_t ID = HTTP_READ_CONFIG_ID;
};

} // namespace oasis
