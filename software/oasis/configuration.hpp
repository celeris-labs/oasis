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

// Matches hardware HttpConfig (39 params [0..38] + START at 39). ID string "HTT".
// Kept in sync with hardware/src/hdl/http_read/http_config.sv (NUM_PARAM_REGS=39, START_ADDR=39).
// Must match HTTP_CONFIG_ADDR_SPACE in hardware/src/vfpga_top.svh. Went 32 -> 64 when the GET path
// grew from 8 to 16 CSR words (32 -> 64 characters), which pushed START from 31 to 39.
constexpr const uint64_t HTTP_READ_CONFIG_REGS = 64;
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
    uint32_t file_w8         = 0; // GET path characters 32..35
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

    /**
     * Read CSR 10: the request-ring occupancy (`inflightWord` in handler.sv).
     *
     * The handler pipelines several ranged GETs over concurrent TCP sessions, so "busy" is the
     * normal state during a scan and says nothing about whether another request can be accepted.
     * This does: the ring holds `slots` descriptors and `occupied` of them are in use.
     *
     * Bitstreams older than the pipelined handler have no such register and read back zero, which
     * is reported as slots == 0. Callers must treat that as "legacy, one request at a time".
     */
    struct HTTPInflight {
        uint8_t occupied      = 0;
        uint8_t slots         = 0; // 0 => pre-pipelining bitstream
        uint8_t pending_mask  = 0; // per-slot: bytes announced but not yet read
        uint8_t closed_mask   = 0; // per-slot: peer has FINed

        bool legacy() const { return slots == 0; }
        uint8_t free_slots() const { return slots > occupied ? uint8_t(slots - occupied) : uint8_t(0); }
        std::string describe() const;
    };
    HTTPInflight inflight();

    /// Requests the hardware can hold at once (0 on a pre-pipelining bitstream). Cached after the
    /// first read; the value is fixed by the bitstream.
    uint8_t num_slots();

    /// Read CSRs 3..8: the request parameters currently latched in hardware.
    HTTPRequestEcho request_echo();

    /// Renders a packed status word from debug_status() into per-sub-FSM fields.
    static std::string describe_status(uint32_t status);

    uint64_t read_stream_register(libstf::stream_t stream, uint32_t reg);

    static constexpr uint64_t ID = HTTP_READ_CONFIG_ID;

  private:
    /// -1 until the first inflight() read; then the bitstream's slot count.
    int num_slots_ = -1;
};

} // namespace oasis
