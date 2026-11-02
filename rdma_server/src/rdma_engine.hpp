#pragma once

#include "rdma_token.hpp"

#include <infiniband/verbs.h>

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <shared_mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace oasis_s3 {

enum class TransferStatus {
    ok,
    no_session, // The token names a QP this server never connected to, so nothing was sent.
    failed      // The transfer started and failed. Its QP is gone and the client must reconnect.
};

/**
 * Moves object bytes with server-initiated RDMA: WRITE for GET, READ for PUT. The client's token
 * names a QP it connected through connect(), and that QP stays up across transfers.
 *
 * Transfers on one QP are posted strictly in submission order and never interleaved. Writes within
 * a transfer are in ascending address order.
 */
class RdmaEngine {
  public:
    struct Options {
        int    device_index = 0;
        int    ib_port      = 1;
        int    gid_index    = -1; // -1 picks the first RoCE v2 IPv4 GID
        int    traffic_class = 0;
        int    service_level = 0;
        size_t workers      = 2;
        size_t max_sessions = 256;
    };

    RdmaEngine(const Options &options, uint8_t *region, uint64_t region_size);
    ~RdmaEngine();

    RdmaEngine(const RdmaEngine &)            = delete;
    RdmaEngine &operator=(const RdmaEngine &) = delete;

    // The RC handshake: creates a QP towards the client's and returns the token describing it. The
    // client's QP only has to be connected before the first GET or PUT. Reconnecting the same
    // client QP replaces the old session.
    std::optional<RdmaToken> connect(const RdmaToken &client);

    // Both block until the transfer finished. `local` must lie inside the registered region.
    TransferStatus write(const RdmaToken &client, const uint8_t *local, uint64_t size);
    TransferStatus read(const RdmaToken &client, uint8_t *local, uint64_t size);

    [[nodiscard]] std::string device_name() const { return device_name_; }
    [[nodiscard]] std::string gid_string() const;
    [[nodiscard]] int         gid_index() const { return gid_index_; }

  private:
    struct Transfer;
    struct Batch;
    struct Session;
    struct Worker;
    using SessionKey = std::pair<std::array<uint8_t, 16>, uint32_t>;

    TransferStatus submit(const RdmaToken &client, ibv_wr_opcode opcode, uint8_t *local, uint64_t size);
    void           worker_loop(Worker &worker);
    void           pump(Session &session);
    void           fail_session(Worker &worker, const std::shared_ptr<Session> &session);
    void           erase_session(const SessionKey &key, uint64_t id);
    void           evict_idle_session_locked();

    Options     options_;
    std::string device_name_;
    int         gid_index_ = 0;
    ibv_gid     gid_       = {};
    ibv_mtu     path_mtu_  = IBV_MTU_4096;
    ibv_device_attr device_attr_ = {};

    ibv_context *context_ = nullptr;
    ibv_pd      *pd_      = nullptr;
    ibv_mr      *mr_      = nullptr;

    std::vector<std::unique_ptr<Worker>> workers_;
    std::atomic<size_t>                  next_worker_{0};
    std::atomic<bool>                    stop_{false};

    std::shared_mutex                      sessions_mtx_;
    std::map<SessionKey, std::shared_ptr<Session>> sessions_;
    std::atomic<uint64_t>                  next_session_id_{1};
    std::atomic<uint64_t>                  use_clock_{0};
};

} // namespace oasis_s3
