#pragma once

#include "libstf/common.hpp"
#include <coyote/cThread.hpp>
#include <libstf/configuration.hpp>

namespace oasis {

constexpr const uint64_t OASIS_SYSTEM_ID = 0x0A515;

constexpr const uint64_t RDMA_READ_CONFIG_REGS = 2;
constexpr const uint64_t RDMA_READ_CONFIG_ID   = 0x2f966a70f04c0e93;

constexpr const uint64_t HTTP_READ_CONFIG_REGS = 16;
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
 * Configures the hardware HTTP client (HttpConfig + handler) to issue one
 * ranged GET request. The FPGA derives Host:/Range: ASCII from the binary
 * server_ip, server_port, and range fields.
 */
class HTTPReadConfig : public libstf::Config {
  public:
    HTTPReadConfig(std::shared_ptr<coyote::cThread> cthread, uint32_t addr_offset, uint32_t num_regs);

    void read(libstf::stream_t stream, uint32_t server_ip, uint16_t server_port, const std::string &path,
              uint64_t range_begin, uint64_t range_end, uint16_t session_id);

    uint8_t client_state();

    /// Reads the packed HTTP/TCP FSM debug status (read CSR 2). Layout:
    ///   [3:0]   HTTPRead FSM   (0=IDLE,1=TCP_SEND,2=TCP_READ)
    ///   [7:4]   reserved (was tcp_init; open is SW-managed)
    ///   [11:8]  tcp_send FSM   (0=IDLE,3=BUILD,4=META,5=DATA,6=WAIT/DONE)
    ///   [15:12] tcp_read FSM   (0=IDLE,7=WAIT_NOTIFY,8=REQ_PKG,9=RECV/DONE)
    ///   [16] 0 [17] 0 [18] send_done [19] send_error
    ///   [20] read_done [21] read_error [22] handler_busy
    /// Returns 0 on bitstreams built before this CSR existed.
    uint32_t debug_status();

    /// Read back a per-stream write CSR (server_ip=0 ... size=13, session_id=14, start=15).
    uint64_t read_stream_register(libstf::stream_t stream, uint32_t reg);

    /// Reads HTTPReadConfig CSR `read_register(1)`. Today this is `num_streams`, not the TCP FSM
    /// (see `http_read.sv` — `state_debug` is not wired to CSRs yet).

    static constexpr uint64_t ID = HTTP_READ_CONFIG_ID;
};

} // namespace oasis
