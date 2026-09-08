// Standalone server that hosts a set of Parquet files in an RDMA-readable
// memory region for the Oasis extension's rdma:// filesystem.
//
// It registers one memory region for remote reads and then accepts a queue pair
// per client connection, all sharing that region. The Oasis FPGA opens one queue
// pair per read-request stream (one cThread each), so the server holds several
// concurrent QPs against the same region and serves reads on all of them.
//
// The out-of-band QP exchange is wire-compatible with Coyote's cThread::initRDMA:
// the client connects, sends its ibvQ, and then reads back ours. The ibvQ struct
// below therefore matches Coyote's coyote::ibvQ layout byte-for-byte.
//
// Layout of the region (matches RDMAFileSystem::LoadDirectory):
//   uint64 dir_size  // total bytes of the directory header (including this field)
//   repeated until dir_size bytes consumed:
//     uint64 name_len
//     char[name_len] name
//     uint64 offset    // absolute offset within the region
//     uint64 size      // bytes
//   <file payloads, packed at the recorded offsets>
//   <63 zero bytes for FPGA RDMA read-length rounding>

#include <boost/program_options.hpp>

#include <infiniband/verbs.h>

#include <algorithm>
#include <arpa/inet.h>
#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <netinet/in.h>
#include <poll.h>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <sys/time.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint16_t DEFAULT_PORT     = 18488; // matches Coyote's DEF_PORT
constexpr int      DEFAULT_IB_PORT  = 1;
constexpr int      DEFAULT_GID_IDX  = 3;     // RoCEv2 IPv4 sgid index
constexpr int      DEFAULT_DEV_IDX  = 0;

// The FPGA rounds read lengths up to 64 bytes, potentially reading past the final file.
constexpr uint64_t RDMA_READ_PADDING = 63;

// Upper bound on live client QPs. The FPGA opens one per read-request stream (a handful); this is a
// safety valve so a misbehaving/looping client cannot make the server accumulate QPs without bound.
constexpr size_t MAX_CONCURRENT_QPS = 256;

// A stalled QP exchange must not pin a worker (and thus the server's shutdown) forever, so the
// accepted socket gets this receive timeout. The client sends its ibvQ immediately after connecting,
// so a few seconds is comfortably more than a healthy exchange needs.
constexpr int EXCHANGE_TIMEOUT_SECONDS = 5;

std::atomic<bool> g_stop{false};
void              handle_signal(int) { g_stop.store(true); }

/**
 * Sets a receive timeout on a socket so blocking reads on it cannot hang indefinitely. Best-effort:
 * a failure just leaves the socket blocking, which the caller's own timeouts still bound.
 */
void set_recv_timeout(int fd, int seconds) {
    struct timeval tv;
    tv.tv_sec  = seconds;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

/**
 * RDMA queue metadata exchanged out-of-band. Must match coyote::ibvQ byte-for-byte
 * so the Coyote client on the FPGA can parse it.
 */
struct ibvQ {
    uint32_t ip_addr;
    uint32_t qpn;
    uint32_t psn;
    uint32_t rkey;
    void    *vaddr;
    uint64_t size;
    char     gid[33] = {0};

    void print(const char *name) const {
        printf("%s: QPN 0x%06x, PSN 0x%06x, RKEY 0x%08x, VADDR %016lx, SIZE %016lx, IP 0x%08x\n", name, qpn, psn, rkey,
               reinterpret_cast<uint64_t>(vaddr), size, ip_addr);
    }
};

/**
 * Returns the final path component (everything after the last '/').
 */
std::string basename(const std::string &path) {
    auto slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

/**
 * Returns the byte size of the serialized directory header for the given file names.
 */
uint64_t directory_header_byte_size(const std::vector<std::string> &names) {
    uint64_t total = sizeof(uint64_t); // dir_size
    for (const auto &name : names) {
        total += sizeof(uint64_t);     // name_len
        total += name.size();          // name bytes
        total += 2 * sizeof(uint64_t); // offset + size
    }
    return total;
}

/**
 * Writes value to *ptr in little-endian byte order and advances ptr by sizeof(T).
 */
template <typename T> void write_header_value(uint8_t *&ptr, T value) {
    std::memcpy(ptr, &value, sizeof(T));
    ptr += sizeof(T);
}

/**
 * Expands a mix of .parquet files and directories into a flat, sorted list of .parquet paths.
 */
std::vector<std::string> resolve_inputs(const std::vector<std::string> &args) {
    std::vector<std::string> result;
    for (const auto &arg : args) {
        std::filesystem::path p(arg);
        if (std::filesystem::is_directory(p)) {
            std::vector<std::string> dir_files;
            for (const auto &entry : std::filesystem::directory_iterator(p)) {
                if (entry.is_regular_file() && entry.path().extension() == ".parquet")
                    dir_files.push_back(entry.path().string());
            }
            std::sort(dir_files.begin(), dir_files.end());
            result.insert(result.end(), dir_files.begin(), dir_files.end());
        } else {
            result.push_back(arg);
        }
    }
    return result;
}

/**
 * The shared RDMA endpoint: the NIC context, protection domain, completion queue, and the single
 * memory region every client queue pair reads from. Created once and shared read-only across the
 * per-connection worker threads (each worker owns its own queue pair, created by arm_qp).
 */
struct RDMAEndpoint {
    struct ibv_context     *context  = nullptr;
    struct ibv_pd          *pd       = nullptr;
    struct ibv_cq          *cq       = nullptr;
    struct ibv_mr          *mr       = nullptr;
    uint8_t                *mem      = nullptr;
    size_t                  mem_size = 0;
    struct ibv_device_attr  dev_attr = {}; // NIC limits, queried once; used to clamp QP caps.

    ~RDMAEndpoint() {
        if (cq)
            ibv_destroy_cq(cq);
        if (mr)
            ibv_dereg_mr(mr);
        if (mem)
            free(mem);
        if (pd)
            ibv_dealloc_pd(pd);
        if (context)
            ibv_close_device(context);
    }
};

/**
 * Moves the queue pair to the INIT state, ready to accept a fresh RTR/RTS transition.
 * Used both at first setup and when re-arming the QP for a reconnecting client.
 */
bool move_qp_to_init(struct ibv_qp *qp, int ib_port) {
    struct ibv_qp_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.qp_state        = IBV_QPS_INIT;
    attr.port_num        = static_cast<uint8_t>(ib_port);
    attr.pkey_index      = 0;
    attr.qp_access_flags = IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE;
    // ibv_modify_qp returns the error code directly and does not reliably set errno, so report the
    // return value -- strerror(errno) here would print a stale value from an unrelated syscall.
    int ret = ibv_modify_qp(qp, &attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);
    if (ret) {
        std::cerr << "Could not move QP to INIT: " << strerror(ret) << "\n";
        return false;
    }
    return true;
}

/**
 * Opens the NIC, caches its device limits, allocates and registers a region_size buffer for remote
 * reads, and creates the shared completion queue. Queue pairs are created per client by arm_qp();
 * the endpoint holds no QP of its own. Returns false on any failure.
 */
bool setup_endpoint(RDMAEndpoint &ep, uint64_t region_size, int dev_idx) {
    int                num_devices = 0;
    struct ibv_device **dev_list   = ibv_get_device_list(&num_devices);
    if (!dev_list || num_devices == 0) {
        std::cerr << "No RDMA devices found\n";
        return false;
    }
    if (dev_idx >= num_devices) {
        std::cerr << "Requested device index " << dev_idx << " but only " << num_devices << " device(s) present\n";
        ibv_free_device_list(dev_list);
        return false;
    }

    ep.context = ibv_open_device(dev_list[dev_idx]);
    std::cout << "Using RDMA device: " << ibv_get_device_name(dev_list[dev_idx]) << std::endl;
    ibv_free_device_list(dev_list);
    if (!ep.context) {
        std::cerr << "Could not open RDMA device\n";
        return false;
    }

    ep.pd = ibv_alloc_pd(ep.context);
    if (!ep.pd) {
        std::cerr << "Could not allocate protection domain\n";
        return false;
    }

    // Page-align the region so the NIC and the huge-page-friendly allocator are happy.
    ep.mem_size    = region_size;
    void *raw      = nullptr;
    size_t page_sz = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    if (posix_memalign(&raw, page_sz, region_size) != 0 || !raw) {
        std::cerr << "Could not allocate " << region_size << " Byte region\n";
        return false;
    }
    ep.mem = static_cast<uint8_t *>(raw);

    ep.mr = ibv_reg_mr(ep.pd, ep.mem, region_size,
                       IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ | IBV_ACCESS_RELAXED_ORDERING);
    if (!ep.mr) {
        std::cerr << "Could not register memory region\n";
        return false;
    }

    ep.cq = ibv_create_cq(ep.context, 16, nullptr, nullptr, 0);
    if (!ep.cq) {
        std::cerr << "Could not create completion queue\n";
        return false;
    }

    // Cache the NIC's limits so arm_qp() can clamp QP capabilities to what the device supports.
    if (ibv_query_device(ep.context, &ep.dev_attr) != 0) {
        std::cerr << "Could not query device attributes: " << strerror(errno) << "\n";
        return false;
    }

    return true;
}

/**
 * Creates a fresh RC queue pair on the shared endpoint and leaves it in the INIT state, ready for an
 * RTR/RTS transition. Called once per client connection so each stream gets its own QP; a QP is
 * never reset and reused, which behaves inconsistently across mlx5 and bnxt_re. Returns the new QP,
 * or nullptr on failure. Caps are clamped to the cached device limits.
 *
 * This QP is a passive RDMA-read responder -- the FPGA is the requester and we never post send/recv
 * work requests -- so it needs only token WQE depth. Broadcom (bnxt_re) has a tighter per-QP WQE
 * budget than Mellanox (mlx5): the 2048/16 caps that worked on mlx5 fail here (EINVAL on
 * max_sge > 13, then ENOSPC as WR x SGE overruns the budget).
 */
struct ibv_qp *arm_qp(RDMAEndpoint &ep, int ib_port) {
    struct ibv_qp_init_attr qp_init_attr;
    memset(&qp_init_attr, 0, sizeof(qp_init_attr));
    qp_init_attr.send_cq          = ep.cq;
    qp_init_attr.recv_cq          = ep.cq;
    qp_init_attr.qp_type          = IBV_QPT_RC;
    qp_init_attr.cap.max_send_wr  = std::min(16, ep.dev_attr.max_qp_wr);
    qp_init_attr.cap.max_recv_wr  = std::min(16, ep.dev_attr.max_qp_wr);
    qp_init_attr.cap.max_send_sge = std::min(1, ep.dev_attr.max_sge);
    qp_init_attr.cap.max_recv_sge = std::min(1, ep.dev_attr.max_sge);

    struct ibv_qp *qp = ibv_create_qp(ep.pd, &qp_init_attr);
    if (!qp) {
        std::cerr << "Could not create queue pair: " << strerror(errno) << "\n";
        return nullptr;
    }

    if (!move_qp_to_init(qp, ib_port)) {
        ibv_destroy_qp(qp);
        return nullptr;
    }
    return qp;
}

/**
 * Extracts the IPv4 address the NIC uses from the RoCEv2 GID at (ib_port, gid_idx).
 *
 * A RoCEv2 IPv4 GID is the IPv4-mapped IPv6 form ::ffff:a.b.c.d, so the address lives
 * in the last four GID bytes (network order). Returns it as a host-order uint32 (first
 * octet in the most significant byte). Fails if the index does not hold an IPv4 GID.
 */
bool query_local_ipv4(struct ibv_context *context, int ib_port, int gid_idx, uint32_t &ip_out) {
    union ibv_gid gid;
    if (ibv_query_gid(context, static_cast<uint8_t>(ib_port), gid_idx, &gid)) {
        std::cerr << "Could not query GID at port " << ib_port << " index " << gid_idx << ": " << strerror(errno)
                  << "\n";
        return false;
    }
    // Confirm the ::ffff: prefix that marks an IPv4-mapped GID.
    static const uint8_t v4_prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
    if (std::memcmp(gid.raw, v4_prefix, sizeof(v4_prefix)) != 0) {
        std::cerr << "GID at index " << gid_idx << " is not a RoCEv2 IPv4 GID; try a different --gid_idx\n";
        return false;
    }
    ip_out = (static_cast<uint32_t>(gid.raw[12]) << 24) | (static_cast<uint32_t>(gid.raw[13]) << 16) |
             (static_cast<uint32_t>(gid.raw[14]) << 8) | static_cast<uint32_t>(gid.raw[15]);
    return true;
}

/**
 * Transitions the queue pair to RTR then RTS, connecting it to the remote (FPGA) QP.
 *
 * The GID is built RoCEv2-IPv4-style from the remote IP : the
 * Coyote FPGA advertises its RoCE IP rather than a real GID. The shared PSN convention
 * (both sides use the client's PSN) also follows the reference.
 */
bool connect_qp(struct ibv_qp *qp, const ibvQ &remote, uint32_t psn, int ib_port, int gid_idx) {
    // Build the remote GID as ::ffff:<ip> in network byte order.
    uint64_t remote_gid = 0x0000FFFF00000000ULL | static_cast<uint64_t>(remote.ip_addr);
    uint32_t high_part  = htonl(static_cast<uint32_t>(remote_gid >> 32));
    uint32_t low_part   = htonl(static_cast<uint32_t>(remote_gid & 0xFFFFFFFF));
    remote_gid          = (static_cast<uint64_t>(low_part) << 32) | high_part;

    union ibv_gid dgid;
    memset(&dgid, 0, sizeof(dgid));
    dgid.global.subnet_prefix = 0;
    dgid.global.interface_id  = static_cast<uint64_t>(remote_gid);

    struct ibv_qp_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.qp_state              = IBV_QPS_RTR;
    attr.path_mtu              = IBV_MTU_4096;
    attr.dest_qp_num           = remote.qpn;
    attr.rq_psn                = psn;
    attr.max_dest_rd_atomic    = 16;
    attr.min_rnr_timer         = 0;
    attr.ah_attr.dlid          = 0;
    attr.ah_attr.sl            = 1;
    attr.ah_attr.static_rate   = IBV_RATE_100_GBPS;
    attr.ah_attr.is_global     = 1;
    attr.ah_attr.src_path_bits = 0;
    attr.ah_attr.port_num      = static_cast<uint8_t>(ib_port);
    attr.ah_attr.grh.dgid          = dgid;
    attr.ah_attr.grh.flow_label    = 0;
    attr.ah_attr.grh.sgid_index    = static_cast<uint8_t>(gid_idx);
    attr.ah_attr.grh.hop_limit     = 4;
    attr.ah_attr.grh.traffic_class = 0;

    int ret = ibv_modify_qp(qp, &attr,
                            IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                                IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER);
    if (ret) {
        std::cerr << "Could not move QP to RTR: " << strerror(ret) << "\n";
        return false;
    }

    memset(&attr, 0, sizeof(attr));
    attr.qp_state      = IBV_QPS_RTS;
    attr.sq_psn        = psn;
    attr.timeout       = 20;
    attr.retry_cnt     = 12;
    attr.rnr_retry     = 1;
    attr.max_rd_atomic = 16;
    attr.path_mig_state = IBV_MIG_REARM;
    ret = ibv_modify_qp(qp, &attr,
                        IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY |
                            IBV_QP_MAX_QP_RD_ATOMIC | IBV_QP_PATH_MIG_STATE);
    if (ret) {
        std::cerr << "Could not move QP to RTS: " << strerror(ret) << "\n";
        return false;
    }
    return true;
}

/**
 * Creates, binds, and listens on a TCP socket for QP-exchange connections. Kept open for
 * the server's lifetime so successive clients can reconnect. Returns the listening socket
 * fd or -1 on failure.
 */
int create_listen_socket(uint16_t port) {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        std::cerr << "Could not create socket\n";
        return -1;
    }
    int optval = 1;
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    struct sockaddr_in server;
    memset(&server, 0, sizeof(server));
    server.sin_family      = AF_INET;
    server.sin_addr.s_addr = INADDR_ANY;
    server.sin_port        = htons(port);
    if (bind(sockfd, reinterpret_cast<struct sockaddr *>(&server), sizeof(server)) < 0) {
        std::cerr << "Could not bind port " << port << ": " << strerror(errno) << "\n";
        close(sockfd);
        return -1;
    }
    if (listen(sockfd, SOMAXCONN) < 0) {
        std::cerr << "Could not listen on port " << port << "\n";
        close(sockfd);
        return -1;
    }
    return sockfd;
}

/**
 * Performs the Coyote-compatible QP exchange on an already-accepted connection: read the client's
 * ibvQ, then send ours. Returns true on success with remote_out holding the client's queue metadata.
 *
 * The client's PSN is adopted as the shared PSN, so local.psn is filled from the client's QP after
 * the read and before the reply is sent.
 */
bool exchange_qp(int connfd, ibvQ &local, ibvQ &remote_out) {
    // Read the client's QP first, then reply with ours (Coyote's exchange order). A short read here
    // is usually the receive timeout firing on a client that connected but never sent its ibvQ.
    if (read(connfd, &remote_out, sizeof(ibvQ)) != static_cast<ssize_t>(sizeof(ibvQ))) {
        std::cerr << "Failed to read client QP: " << strerror(errno) << "\n";
        return false;
    }
    local.psn = remote_out.psn; // both sides share the client's PSN
    if (write(connfd, &local, sizeof(ibvQ)) != static_cast<ssize_t>(sizeof(ibvQ))) {
        std::cerr << "Failed to send server QP\n";
        return false;
    }
    return true;
}

/**
 * Blocks until the client tears down the TCP connection (read returns 0) or the server is asked to
 * stop. RDMA reads are served by the NIC with no CPU involvement, so the socket carries no
 * post-exchange traffic; any bytes that do arrive are ignored. Runs on a worker thread, where the
 * shutdown signal is delivered to the main thread rather than here -- so instead of relying on
 * EINTR we poll with a timeout and re-check g_stop between waits.
 */
void wait_for_disconnect(int connfd) {
    struct pollfd pfd;
    pfd.fd     = connfd;
    pfd.events = POLLIN;
    char buf[64];
    while (!g_stop.load()) {
        int r = poll(&pfd, 1, 200 /* ms */);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return; // real poll error
        }
        if (r == 0)
            continue; // timeout -- re-check g_stop
        ssize_t n = read(connfd, buf, sizeof(buf));
        if (n == 0)                  // client closed the connection
            return;
        if (n < 0 && errno != EINTR) // real error (EINTR just means a signal woke us)
            return;
    }
}

/**
 * Services one client connection end-to-end on its own thread: creates a fresh QP on the shared
 * endpoint, exchanges queue metadata, connects the QP to the client's, then holds it in RTS
 * serving RDMA reads until the client disconnects (or the server stops). Tears the QP and socket
 * down on the way out. `local` is a per-connection copy of the advertised metadata; only its qpn
 * (from the new QP) and psn (from the exchange) are filled here.
 *
 * `done` is set to true just before the thread returns, on every exit path, so the main loop can
 * reap the finished thread (and free its QP resources) without blocking.
 */
void handle_client(int connfd, RDMAEndpoint &ep, ibvQ local, int ib_port, int gid_idx,
                   std::shared_ptr<std::atomic<bool>> done) {
    // Signal completion on any return path so the main loop reaps this worker promptly.
    struct DoneGuard {
        std::shared_ptr<std::atomic<bool>> flag;
        ~DoneGuard() { flag->store(true); }
    } done_guard{done};

    // Bound the QP exchange so a client that connects but never completes it cannot pin this thread
    // (and thus block the server's shutdown join) forever.
    set_recv_timeout(connfd, EXCHANGE_TIMEOUT_SECONDS);

    struct ibv_qp *qp = arm_qp(ep, ib_port);
    if (!qp) {
        close(connfd);
        return;
    }
    local.qpn = qp->qp_num;

    ibvQ remote;
    memset(&remote, 0, sizeof(remote));
    if (exchange_qp(connfd, local, remote) && connect_qp(qp, remote, local.psn, ib_port, gid_idx)) {
        remote.print("Remote");
        local.print("Local");
        std::cout << "Now serving a stream (QPN 0x" << std::hex << qp->qp_num << std::dec
                  << ")..." << std::endl;
        wait_for_disconnect(connfd);
        std::cout << "Stream QPN 0x" << std::hex << qp->qp_num << std::dec << " disconnected."
                  << std::endl;
    }

    close(connfd);
    ibv_destroy_qp(qp);
}

/**
 * A worker thread plus the flag it raises when it finishes. Kept together so the main loop can join
 * and drop finished workers (freeing their QPs) without blocking on ones still serving a client.
 */
struct Worker {
    std::thread                        thread;
    std::shared_ptr<std::atomic<bool>> done;
};

/**
 * Joins and removes every worker that has finished, leaving the still-serving ones in place. Called
 * from the accept loop so completed QPs are reclaimed continuously rather than only at shutdown.
 */
void reap_finished_workers(std::vector<Worker> &workers) {
    for (auto it = workers.begin(); it != workers.end();) {
        if (it->done->load()) {
            if (it->thread.joinable())
                it->thread.join();
            it = workers.erase(it);
        } else {
            ++it;
        }
    }
}

} // namespace

int main(int argc, char *argv[]) {
    uint16_t                 port;
    int                      dev_idx;
    int                      ib_port;
    int                      gid_idx;
    std::vector<std::string> files;

    boost::program_options::options_description options("Oasis RDMA server (Mellanox) options");
    options.add_options()("help,h", "Show help")(
        "port,p", boost::program_options::value<uint16_t>(&port)->default_value(DEFAULT_PORT),
        "TCP port for QP exchange")(
        "device,d", boost::program_options::value<int>(&dev_idx)->default_value(DEFAULT_DEV_IDX),
        "RDMA device index")(
        "ib_port,b", boost::program_options::value<int>(&ib_port)->default_value(DEFAULT_IB_PORT),
        "HCA physical port number")(
        "gid_idx,g", boost::program_options::value<int>(&gid_idx)->default_value(DEFAULT_GID_IDX),
        "Local GID index (RoCEv2 IPv4)")(
        "files", boost::program_options::value<std::vector<std::string>>(&files)->multitoken(),
        "Parquet files to host (positional)");
    boost::program_options::positional_options_description positional;
    positional.add("files", -1);
    boost::program_options::variables_map vm;
    boost::program_options::store(boost::program_options::command_line_parser(argc, argv)
                                      .options(options)
                                      .positional(positional)
                                      .run(),
                                  vm);
    boost::program_options::notify(vm);

    if (vm.count("help") || files.empty()) {
        std::cout << options << std::endl;
        return files.empty() ? EXIT_FAILURE : EXIT_SUCCESS;
    }

    files = resolve_inputs(files);
    if (files.empty()) {
        std::cerr << "No .parquet files found in the given paths\n";
        return EXIT_FAILURE;
    }

    {
        std::vector<std::string> sorted_names;
        sorted_names.reserve(files.size());
        for (const auto &f : files)
            sorted_names.push_back(basename(f));
        std::sort(sorted_names.begin(), sorted_names.end());
        auto dup = std::adjacent_find(sorted_names.begin(), sorted_names.end());
        if (dup != sorted_names.end()) {
            std::cerr << "Duplicate file name: " << *dup << "\n";
            return EXIT_FAILURE;
        }
    }

    // Compute name list and the directory's serialized size.
    std::vector<std::string> names;
    names.reserve(files.size());
    for (const auto &f : files) {
        names.push_back(basename(f));
    }
    uint64_t dir_header_size = directory_header_byte_size(names);

    // Open inputs and gather sizes / total payload.
    std::vector<uint64_t> sizes(files.size());
    uint64_t              payload_total = 0;
    for (size_t i = 0; i < files.size(); ++i) {
        std::ifstream f(files[i], std::ios::binary | std::ios::ate);
        if (!f) {
            std::cerr << "Cannot open " << files[i] << std::endl;
            return EXIT_FAILURE;
        }
        auto file_size = static_cast<uint64_t>(f.tellg());
        sizes[i]       = file_size;
        payload_total += file_size;
    }

    uint64_t data_size = dir_header_size + payload_total;
    uint64_t region_size = data_size + RDMA_READ_PADDING;

    // Compute file offsets within the region.
    std::vector<uint64_t> offsets(files.size());
    {
        uint64_t cursor = dir_header_size;
        for (size_t i = 0; i < files.size(); ++i) {
            offsets[i] = cursor;
            cursor += sizes[i];
        }
    }

    // Print the directory of hosted files before bringing up the connection.
    std::cout << "Oasis RDMA Server: " << files.size() << " file(s), directory header " << dir_header_size
              << " Bytes + payload " << payload_total << " Bytes + padding " << RDMA_READ_PADDING
              << " Bytes = region " << region_size << " Bytes, on port "
              << port << std::endl;
    size_t max_name_len   = 0;
    size_t max_offset_len = 0;
    for (const auto &name : names) max_name_len = std::max(max_name_len, name.size());
    for (const auto &off : offsets)
        max_offset_len = std::max(max_offset_len, std::to_string(off).size());
    for (size_t i = 0; i < files.size(); ++i) {
        std::string quoted = "\"" + names[i] + "\"";
        std::cout << "  [" << i << "] " << std::left << std::setw(max_name_len + 2) << quoted << " offset=" << std::right
                  << std::setw(max_offset_len) << offsets[i] << " size=" << sizes[i] << std::endl;
    }

    // Bring up the Mellanox NIC and register the region for remote reads.
    RDMAEndpoint ep;
    if (!setup_endpoint(ep, region_size, dev_idx)) {
        return EXIT_FAILURE;
    }
    std::memset(ep.mem + data_size, 0, RDMA_READ_PADDING);

    // Discover the RoCE IPv4 we advertise from the GID at the index we connect with.
    uint32_t local_ip = 0;
    if (!query_local_ipv4(ep.context, ib_port, gid_idx, local_ip)) {
        return EXIT_FAILURE;
    }
    {
        char ip_str[INET_ADDRSTRLEN];
        uint32_t net_ip = htonl(local_ip);
        inet_ntop(AF_INET, &net_ip, ip_str, sizeof(ip_str));
        std::cout << "Advertising RoCE IPv4: " << ip_str << std::endl;
    }

    // Lay out the directory.
    std::memset(ep.mem, 0, dir_header_size);
    uint8_t *p = ep.mem;
    write_header_value<uint64_t>(p, dir_header_size);
    for (size_t i = 0; i < files.size(); ++i) {
        write_header_value<uint64_t>(p, static_cast<uint64_t>(names[i].size()));
        std::memcpy(p, names[i].data(), names[i].size());
        p += names[i].size();
        write_header_value<uint64_t>(p, offsets[i]);
        write_header_value<uint64_t>(p, sizes[i]);
    }

    // Copy file Bytes into the region at their assigned offsets.
    for (size_t i = 0; i < files.size(); ++i) {
        std::ifstream f(files[i], std::ios::binary);
        if (!f) {
            std::cerr << "Cannot reopen " << files[i] << std::endl;
            return EXIT_FAILURE;
        }
        f.read(reinterpret_cast<char *>(ep.mem + offsets[i]), static_cast<std::streamsize>(sizes[i]));
        if (static_cast<uint64_t>(f.gcount()) != sizes[i]) {
            std::cerr << "Short read on " << files[i] << std::endl;
            return EXIT_FAILURE;
        }
    }

    // The QP metadata we advertise. rkey, vaddr and size are stable across every connection (all QPs
    // read the same region); qpn is filled per connection from its fresh QP and psn is adopted from
    // the client during the exchange. Each worker takes a copy and fills those two fields in.
    ibvQ local_template;
    local_template.ip_addr = local_ip;
    local_template.rkey    = ep.mr->rkey;
    local_template.vaddr   = ep.mem;
    local_template.size    = region_size;
    // Coyote encodes the GID as the RoCE IP repeated four times (see ibvQ::gidToUint).
    snprintf(local_template.gid, sizeof(local_template.gid), "%08x%08x%08x%08x", local_ip, local_ip, local_ip,
             local_ip);

    int listenfd = create_listen_socket(port);
    if (listenfd < 0) {
        return EXIT_FAILURE;
    }

    // Install the handlers via sigaction without SA_RESTART so that a signal interrupts a
    // blocking accept() with EINTR instead of silently restarting it; that lets the loop below
    // observe g_stop and shut down. std::signal would set SA_RESTART on Linux.
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);

    // Accept connections and hand each off to a worker thread that owns its own QP. The Oasis FPGA
    // opens one connection per read-request stream, so several QPs are served concurrently against
    // the shared region. Each worker creates a fresh QP (destroyed when its client disconnects) --
    // more portable than resetting and reusing one QP, which behaves inconsistently across mlx5 and
    // bnxt_re.
    std::cout << "Waiting for connections from client on port " << port << "... Press Ctrl+C to exit." << std::endl;
    std::vector<Worker> workers;
    while (!g_stop.load()) {
        // Reclaim any workers whose clients have disconnected before taking on more.
        reap_finished_workers(workers);

        // Wait for a connection with a timeout instead of blocking in accept(), so the loop keeps
        // reaping finished workers and re-checks g_stop even while idle.
        struct pollfd pfd;
        pfd.fd     = listenfd;
        pfd.events = POLLIN;
        int r      = poll(&pfd, 1, 500 /* ms */);
        if (r <= 0) {
            if (r < 0 && errno != EINTR)
                std::cerr << "poll on listen socket failed: " << strerror(errno) << "\n";
            continue; // timeout, EINTR (shutdown signal), or error -- loop re-checks g_stop
        }

        int connfd = accept(listenfd, nullptr, nullptr);
        if (connfd < 0) {
            if (errno == EINTR) // shutdown signal interrupted accept()
                break;
            std::cerr << "Failed to accept connection\n";
            continue;
        }

        // Safety valve: never let live QPs grow without bound. Reap once more in case a worker just
        // finished, and if we are still at the cap reject this connection rather than pile on.
        if (workers.size() >= MAX_CONCURRENT_QPS) {
            reap_finished_workers(workers);
            if (workers.size() >= MAX_CONCURRENT_QPS) {
                std::cerr << "At QP capacity (" << MAX_CONCURRENT_QPS << "); rejecting connection\n";
                close(connfd);
                continue;
            }
        }

        auto done = std::make_shared<std::atomic<bool>>(false);
        workers.push_back({std::thread(handle_client, connfd, std::ref(ep), local_template, ib_port,
                                       gid_idx, done),
                           done});
    }

    std::cout << "Shutting down!" << std::endl;
    close(listenfd);
    // Join every worker before ep is destroyed -- the workers use its pd/cq/mr. g_stop makes the
    // serving workers fall out of wait_for_disconnect within its poll interval, and the exchange
    // receive timeout bounds any worker still mid-handshake, so none of these joins can hang.
    for (auto &worker : workers) {
        if (worker.thread.joinable())
            worker.thread.join();
    }
    return EXIT_SUCCESS;
}
