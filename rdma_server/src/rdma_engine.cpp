#include "rdma_engine.hpp"

#include <arpa/inet.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <immintrin.h>
#include <mutex>
#include <sstream>
#include <stdexcept>

namespace oasis_s3 {

namespace {

// A transfer up to this size is one RDMA message. Above it the transfer is split so one large object
// cannot hold the send queue for long. The values match MinIO's MINIO_RDMA_DIRECT_MAX_SIZE default
// and its chunk size.
constexpr uint64_t DIRECT_MAX_SIZE = 64ull << 20;
constexpr uint64_t CHUNK_SIZE      = 16ull << 20;

constexpr uint32_t SEND_QUEUE_DEPTH = 256;
constexpr int      MAX_BATCH_WRS    = 32;
constexpr int      POLL_BATCH       = 32;

// The token has no field for it, so every RC connection starts at PSN 0, as hipObject does.
constexpr uint32_t INITIAL_PSN = 0;

// IBTA timeout 14 is about 67 ms per attempt.
constexpr uint8_t QP_TIMEOUT   = 14;
constexpr uint8_t QP_RETRY_CNT = 7;
constexpr uint8_t QP_RNR_RETRY = 7;
constexpr uint8_t QP_MIN_RNR   = 12;
constexpr uint8_t HOP_LIMIT    = 64;

bool is_rocev2_ipv4(ibv_context *context, const char *device, int port, int index, ibv_gid &gid) {
    if (ibv_query_gid(context, static_cast<uint8_t>(port), index, &gid) != 0) {
        return false;
    }
    static const uint8_t v4_prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
    if (std::memcmp(gid.raw, v4_prefix, sizeof(v4_prefix)) != 0) {
        return false;
    }
    std::ostringstream path;
    path << "/sys/class/infiniband/" << device << "/ports/" << port << "/gid_attrs/types/" << index;
    std::ifstream file(path.str());
    std::string   type;
    std::getline(file, type);
    return type == "RoCE v2";
}

} // namespace

struct RdmaEngine::Transfer {
    ibv_wr_opcode opcode;
    uint8_t      *local;
    uint64_t      remote_addr;
    uint32_t      rkey;
    uint64_t      size;
    uint64_t      posted = 0;

    std::mutex              mtx;
    std::condition_variable cv;
    bool                    done   = false;
    TransferStatus          status = TransferStatus::ok;

    void finish(TransferStatus result) {
        std::lock_guard<std::mutex> lock(mtx);
        status = result;
        done   = true;
        cv.notify_one();
    }

    TransferStatus wait() {
        std::unique_lock<std::mutex> lock(mtx);
        cv.wait(lock, [this] { return done; });
        return status;
    }
};

// A run of work requests of which only the last is signaled. RC completes them in order, so a
// completion retires exactly the oldest batch.
struct RdmaEngine::Batch {
    int       wrs;
    Transfer *finished; // Set if this batch holds the last bytes of the transfer.
};

struct RdmaEngine::Session {
    uint64_t    id;
    SessionKey  key;
    ibv_qp     *qp = nullptr;
    Worker     *worker = nullptr;
    uint32_t    lkey   = 0;
    std::atomic<uint64_t> last_used{0};
    std::atomic<bool>     failed{false};
    std::atomic<uint32_t> outstanding{0};

    // Only the worker thread touches these.
    std::deque<Transfer *> pending;
    std::deque<Batch>      in_flight;
    int                    send_slots = SEND_QUEUE_DEPTH;

    ~Session() {
        if (qp) {
            ibv_destroy_qp(qp);
        }
    }
};

struct RdmaEngine::Worker {
    ibv_cq     *cq = nullptr;
    std::thread thread;

    std::mutex              mtx;
    std::condition_variable cv;
    std::deque<std::pair<std::shared_ptr<Session>, Transfer *>> queue;

    // Sessions with pending or in-flight work. Only the worker thread touches this.
    std::unordered_map<uint64_t, std::shared_ptr<Session>> active;

    ~Worker() {
        if (cq) {
            ibv_destroy_cq(cq);
        }
    }
};

RdmaEngine::RdmaEngine(const Options &options, uint8_t *region, uint64_t region_size)
    : options_(options) {
    int          num_devices = 0;
    ibv_device **devices     = ibv_get_device_list(&num_devices);
    if (!devices || num_devices == 0) {
        throw std::runtime_error("No RDMA devices found");
    }
    if (options_.device_index >= num_devices) {
        ibv_free_device_list(devices);
        throw std::runtime_error("RDMA device index out of range");
    }
    device_name_ = ibv_get_device_name(devices[options_.device_index]);
    context_     = ibv_open_device(devices[options_.device_index]);
    ibv_free_device_list(devices);
    if (!context_) {
        throw std::runtime_error("Could not open RDMA device " + device_name_);
    }

    pd_ = ibv_alloc_pd(context_);
    if (!pd_) {
        throw std::runtime_error("Could not allocate protection domain");
    }
    if (ibv_query_device(context_, &device_attr_) != 0) {
        throw std::runtime_error("Could not query RDMA device");
    }

    ibv_port_attr port_attr = {};
    if (ibv_query_port(context_, static_cast<uint8_t>(options_.ib_port), &port_attr) != 0) {
        throw std::runtime_error("Could not query RDMA port");
    }
    // Neither side negotiates the MTU, so a client on another MTU would hang. 4096 is what Coyote
    // uses, so never exceed it even on a port that could.
    path_mtu_ = std::min(port_attr.active_mtu, IBV_MTU_4096);

    if (options_.gid_index >= 0) {
        gid_index_ = options_.gid_index;
        if (ibv_query_gid(context_, static_cast<uint8_t>(options_.ib_port), gid_index_, &gid_) != 0) {
            throw std::runtime_error("Could not query the requested GID index");
        }
    } else {
        gid_index_ = -1;
        for (int i = 0; i < port_attr.gid_tbl_len && gid_index_ < 0; ++i) {
            if (is_rocev2_ipv4(context_, device_name_.c_str(), options_.ib_port, i, gid_)) {
                gid_index_ = i;
            }
        }
        if (gid_index_ < 0) {
            throw std::runtime_error("No RoCE v2 IPv4 GID found, pass one with --gid_idx");
        }
    }

    // No remote access: the server only initiates. GETs read this memory locally for the WRITE and
    // PUTs land in it from the READ, which is why it needs local write access.
    mr_ = ibv_reg_mr(pd_, region, region_size, IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_RELAXED_ORDERING);
    if (!mr_) {
        throw std::runtime_error(std::string("Could not register the object arena: ") + strerror(errno));
    }

    const size_t worker_count = std::max<size_t>(options_.workers, 1);
    const int    cq_depth     = std::min<int>(device_attr_.max_cqe,
                                              static_cast<int>(options_.max_sessions * SEND_QUEUE_DEPTH));
    for (size_t i = 0; i < worker_count; ++i) {
        auto worker = std::make_unique<Worker>();
        worker->cq  = ibv_create_cq(context_, cq_depth, nullptr, nullptr, 0);
        if (!worker->cq) {
            throw std::runtime_error("Could not create completion queue");
        }
        workers_.push_back(std::move(worker));
    }
    for (auto &worker : workers_) {
        worker->thread = std::thread([this, raw = worker.get()] { worker_loop(*raw); });
    }
}

RdmaEngine::~RdmaEngine() {
    stop_.store(true);
    for (auto &worker : workers_) {
        {
            // Holding the lock closes the gap between a worker's predicate check and its wait.
            std::lock_guard<std::mutex> lock(worker->mtx);
        }
        worker->cv.notify_all();
        if (worker->thread.joinable()) {
            worker->thread.join();
        }
    }
    sessions_.clear(); // QPs go before their CQs.
    for (auto &worker : workers_) {
        worker->active.clear();
    }
    workers_.clear();
    if (mr_) {
        ibv_dereg_mr(mr_);
    }
    if (pd_) {
        ibv_dealloc_pd(pd_);
    }
    if (context_) {
        ibv_close_device(context_);
    }
}

std::string RdmaEngine::gid_string() const {
    char text[INET6_ADDRSTRLEN];
    inet_ntop(AF_INET6, gid_.raw, text, sizeof(text));
    return text;
}

void RdmaEngine::evict_idle_session_locked() {
    uint64_t oldest = UINT64_MAX;
    auto     victim = sessions_.end();
    for (auto it = sessions_.begin(); it != sessions_.end(); ++it) {
        const uint64_t used = it->second->last_used.load();
        if (it->second->outstanding.load() == 0 && used < oldest) {
            oldest = used;
            victim = it;
        }
    }
    if (victim != sessions_.end()) {
        sessions_.erase(victim);
    }
}

std::optional<RdmaToken> RdmaEngine::connect(const RdmaToken &client) {
    auto session    = std::make_shared<Session>();
    session->id     = next_session_id_.fetch_add(1);
    session->key    = SessionKey{client.gid, client.qpn};
    session->worker = workers_[next_worker_.fetch_add(1) % workers_.size()].get();
    session->lkey   = mr_->lkey;
    session->last_used.store(use_clock_.fetch_add(1));

    ibv_qp_init_attr init_attr = {};
    init_attr.send_cq          = session->worker->cq;
    init_attr.recv_cq          = session->worker->cq;
    init_attr.qp_type          = IBV_QPT_RC;
    init_attr.sq_sig_all       = 0;
    init_attr.cap.max_send_wr  = std::min<uint32_t>(SEND_QUEUE_DEPTH, device_attr_.max_qp_wr);
    init_attr.cap.max_recv_wr  = 1;
    init_attr.cap.max_send_sge = 1;
    init_attr.cap.max_recv_sge = 1;
    session->qp                = ibv_create_qp(pd_, &init_attr);
    if (!session->qp) {
        std::cerr << "Could not create queue pair: " << strerror(errno) << "\n";
        return std::nullopt;
    }
    session->send_slots = static_cast<int>(init_attr.cap.max_send_wr);

    ibv_qp_attr attr     = {};
    attr.qp_state        = IBV_QPS_INIT;
    attr.pkey_index      = 0;
    attr.port_num        = static_cast<uint8_t>(options_.ib_port);
    attr.qp_access_flags = 0;
    int ret = ibv_modify_qp(session->qp, &attr,
                            IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);
    if (ret) {
        std::cerr << "Could not move QP to INIT: " << strerror(ret) << "\n";
        return std::nullopt;
    }

    attr                           = {};
    attr.qp_state                  = IBV_QPS_RTR;
    attr.path_mtu                  = path_mtu_;
    attr.dest_qp_num               = client.qpn;
    attr.rq_psn                    = INITIAL_PSN;
    attr.max_dest_rd_atomic        = 1;
    attr.min_rnr_timer             = QP_MIN_RNR;
    attr.ah_attr.is_global         = 1;
    attr.ah_attr.dlid              = client.lid;
    attr.ah_attr.sl                = static_cast<uint8_t>(options_.service_level);
    attr.ah_attr.port_num          = static_cast<uint8_t>(options_.ib_port);
    attr.ah_attr.grh.hop_limit     = HOP_LIMIT;
    attr.ah_attr.grh.sgid_index    = static_cast<uint8_t>(gid_index_);
    attr.ah_attr.grh.traffic_class = static_cast<uint8_t>(options_.traffic_class);
    std::memcpy(attr.ah_attr.grh.dgid.raw, client.gid.data(), client.gid.size());
    ret = ibv_modify_qp(session->qp, &attr,
                        IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                            IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER);
    if (ret) {
        std::cerr << "Could not move QP to RTR: " << strerror(ret) << "\n";
        return std::nullopt;
    }

    attr               = {};
    attr.qp_state      = IBV_QPS_RTS;
    attr.sq_psn        = INITIAL_PSN;
    attr.timeout       = QP_TIMEOUT;
    attr.retry_cnt     = QP_RETRY_CNT;
    attr.rnr_retry     = QP_RNR_RETRY;
    attr.max_rd_atomic = static_cast<uint8_t>(std::min(16, device_attr_.max_qp_init_rd_atom));
    ret = ibv_modify_qp(session->qp, &attr,
                        IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                            IBV_QP_RNR_RETRY | IBV_QP_MAX_QP_RD_ATOMIC);
    if (ret) {
        std::cerr << "Could not move QP to RTS: " << strerror(ret) << "\n";
        return std::nullopt;
    }

    RdmaToken local;
    local.qpn         = session->qp->qp_num;
    local.gid_present = true;
    std::memcpy(local.gid.data(), gid_.raw, local.gid.size());

    {
        std::unique_lock lock(sessions_mtx_);
        sessions_.erase(session->key);
        if (sessions_.size() >= options_.max_sessions) {
            evict_idle_session_locked();
        }
        if (sessions_.size() >= options_.max_sessions) {
            std::cerr << "All " << options_.max_sessions << " RDMA sessions are busy\n";
            return std::nullopt;
        }
        sessions_[session->key] = session;
    }
    return local;
}

TransferStatus RdmaEngine::write(const RdmaToken &client, const uint8_t *local, uint64_t size) {
    return submit(client, IBV_WR_RDMA_WRITE, const_cast<uint8_t *>(local), size);
}

TransferStatus RdmaEngine::read(const RdmaToken &client, uint8_t *local, uint64_t size) {
    return submit(client, IBV_WR_RDMA_READ, local, size);
}

TransferStatus RdmaEngine::submit(const RdmaToken &client, ibv_wr_opcode opcode, uint8_t *local,
                                  uint64_t size) {
    std::shared_ptr<Session> session;
    {
        std::shared_lock lock(sessions_mtx_);
        auto             it = sessions_.find(SessionKey{client.gid, client.qpn});
        if (it == sessions_.end()) {
            return TransferStatus::no_session;
        }
        session = it->second;
    }
    session->last_used.store(use_clock_.fetch_add(1));
    if (size == 0) {
        return TransferStatus::ok;
    }

    Transfer transfer;
    transfer.opcode      = opcode;
    transfer.local       = local;
    transfer.remote_addr = client.addr;
    transfer.rkey        = client.rkey;
    transfer.size        = size;

    session->outstanding.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(session->worker->mtx);
        session->worker->queue.emplace_back(session, &transfer);
    }
    session->worker->cv.notify_one();

    const TransferStatus status = transfer.wait();
    session->outstanding.fetch_sub(1);
    return status;
}

// Posts as much of the session's pending work as its send queue has room for.
void RdmaEngine::pump(Session &session) {
    ibv_send_wr wrs[MAX_BATCH_WRS];
    ibv_sge     sges[MAX_BATCH_WRS];

    while (!session.pending.empty() && session.send_slots > 0) {
        Transfer      *transfer = session.pending.front();
        const uint64_t chunk    = transfer->size <= DIRECT_MAX_SIZE ? transfer->size : CHUNK_SIZE;

        int count = 0;
        while (count < std::min(MAX_BATCH_WRS, session.send_slots) && transfer->posted < transfer->size) {
            const uint64_t length = std::min(chunk, transfer->size - transfer->posted);

            sges[count]        = {};
            sges[count].addr   = reinterpret_cast<uint64_t>(transfer->local + transfer->posted);
            sges[count].length = static_cast<uint32_t>(length);
            sges[count].lkey   = session.lkey;

            wrs[count]                     = {};
            wrs[count].wr_id               = session.id;
            wrs[count].sg_list             = &sges[count];
            wrs[count].num_sge             = 1;
            wrs[count].opcode              = transfer->opcode;
            wrs[count].wr.rdma.remote_addr = transfer->remote_addr + transfer->posted;
            wrs[count].wr.rdma.rkey        = transfer->rkey;
            wrs[count].next                = nullptr;
            if (count > 0) {
                wrs[count - 1].next = &wrs[count];
            }

            transfer->posted += length;
            ++count;
        }
        wrs[count - 1].send_flags = IBV_SEND_SIGNALED;

        ibv_send_wr *bad = nullptr;
        const int    ret = ibv_post_send(session.qp, wrs, &bad);
        if (ret) {
            std::cerr << "ibv_post_send failed: " << strerror(ret) << "\n";
            session.failed.store(true);
            return;
        }

        session.send_slots -= count;
        const bool finished = transfer->posted == transfer->size;
        session.in_flight.push_back(Batch{count, finished ? transfer : nullptr});
        if (finished) {
            session.pending.pop_front();
        }
    }
}

void RdmaEngine::fail_session(Worker &worker, const std::shared_ptr<Session> &session) {
    for (const auto &batch : session->in_flight) {
        if (batch.finished) {
            batch.finished->finish(TransferStatus::failed);
        }
    }
    for (Transfer *transfer : session->pending) {
        transfer->finish(TransferStatus::failed);
    }
    session->in_flight.clear();
    session->pending.clear();
    session->failed.store(true);
    erase_session(session->key, session->id);
    worker.active.erase(session->id);
}

void RdmaEngine::erase_session(const SessionKey &key, uint64_t id) {
    std::unique_lock lock(sessions_mtx_);
    auto             it = sessions_.find(key);
    // A client may already have reconnected this QP, and that newer session must stay.
    if (it != sessions_.end() && it->second->id == id) {
        sessions_.erase(it);
    }
}

void RdmaEngine::worker_loop(Worker &worker) {
    ibv_wc completions[POLL_BATCH];

    while (!stop_.load(std::memory_order_relaxed)) {
        std::deque<std::pair<std::shared_ptr<Session>, Transfer *>> incoming;
        {
            std::unique_lock<std::mutex> lock(worker.mtx);
            // Spin only while work is on the wire: an idle server must not burn a core per worker.
            if (worker.active.empty() && worker.queue.empty()) {
                worker.cv.wait(lock, [&] { return stop_.load() || !worker.queue.empty(); });
            }
            incoming.swap(worker.queue);
        }

        for (auto &item : incoming) {
            if (item.first->failed.load()) {
                item.second->finish(TransferStatus::failed);
                continue;
            }
            item.first->pending.push_back(item.second);
            worker.active.emplace(item.first->id, item.first);
        }

        std::vector<std::shared_ptr<Session>> to_fail;
        for (auto &entry : worker.active) {
            pump(*entry.second);
            if (entry.second->failed.load()) {
                to_fail.push_back(entry.second);
            }
        }

        const int polled = ibv_poll_cq(worker.cq, POLL_BATCH, completions);
        for (int i = 0; i < polled; ++i) {
            const ibv_wc &wc = completions[i];
            auto          it = worker.active.find(wc.wr_id);
            if (it == worker.active.end()) {
                continue; // A flushed completion of a session that already failed.
            }
            Session &session = *it->second;
            if (wc.status != IBV_WC_SUCCESS) {
                std::cerr << "RDMA transfer failed on QPN 0x" << std::hex << session.qp->qp_num << std::dec
                          << ": " << ibv_wc_status_str(wc.status) << " (vendor error " << wc.vendor_err
                          << ")\n";
                to_fail.push_back(it->second);
                continue;
            }
            const Batch batch = session.in_flight.front();
            session.in_flight.pop_front();
            session.send_slots += batch.wrs;
            if (batch.finished) {
                batch.finished->finish(TransferStatus::ok);
            }
        }

        for (const auto &session : to_fail) {
            if (worker.active.count(session->id) != 0) {
                fail_session(worker, session);
            }
        }

        for (auto it = worker.active.begin(); it != worker.active.end();) {
            if (it->second->pending.empty() && it->second->in_flight.empty()) {
                it = worker.active.erase(it);
            } else {
                ++it;
            }
        }

        if (polled == 0) {
            _mm_pause();
        }
    }

    // Shutdown: nobody may stay blocked on a transfer that will never complete.
    std::lock_guard<std::mutex> lock(worker.mtx);
    for (auto &item : worker.queue) {
        item.second->finish(TransferStatus::failed);
    }
    worker.queue.clear();
    for (auto &entry : worker.active) {
        for (const auto &batch : entry.second->in_flight) {
            if (batch.finished) {
                batch.finished->finish(TransferStatus::failed);
            }
        }
        for (Transfer *transfer : entry.second->pending) {
            transfer->finish(TransferStatus::failed);
        }
    }
    worker.active.clear();
}

} // namespace oasis_s3
