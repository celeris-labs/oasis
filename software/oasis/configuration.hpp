#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

namespace oasis {

constexpr const uint64_t OASIS_SYSTEM_ID = 0x0A515;

constexpr const uint64_t RDMA_READ_CONFIG_REGS = 2;
constexpr const uint64_t RDMA_READ_CONFIG_ID   = 0x2f966a70f04c0e93;

// Matches hardware HttpConfig (27 params + START). ID string "HTT".
constexpr const uint64_t HTTP_READ_CONFIG_REGS = 28;
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

    /// Read CSR 2: TOTAL_WORD on this bitstream (legacy packed FSM status on older ones).
    uint32_t debug_status();

    uint64_t read_stream_register(libstf::stream_t stream, uint32_t reg);

    static constexpr uint64_t ID = HTTP_READ_CONFIG_ID;
};

} // namespace oasis
