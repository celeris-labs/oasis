// Standalone server that hosts a set of Parquet files in an RDMA-readable
// memory region for the Oasis extension's rdma:// filesystem.
//
// It brings up a single RC queue pair, registers the region for remote reads,
// and then sits idle and waits for requests.
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
#include <ifaddrs.h>
#include <iomanip>
#include <iostream>
#include <netinet/in.h>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr uint16_t DEFAULT_PORT     = 18488; // matches Coyote's DEF_PORT
constexpr int      DEFAULT_IB_PORT  = 1;
constexpr int      DEFAULT_GID_IDX  = 3;     // RoCEv2 IPv4 sgid index
constexpr int      DEFAULT_DEV_IDX  = 0;

std::atomic<bool> g_stop{false};
void              handle_signal(int) { g_stop.store(true); }

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
 * Returns a newline-separated list of non-loopback IPv4 addresses with their interface names.
 */
std::string local_ipv4_addresses() {
    std::string     result;
    struct ifaddrs *ifa_list;
    if (getifaddrs(&ifa_list) != 0)
        return result;
    for (auto *ifa = ifa_list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        auto *sin = reinterpret_cast<struct sockaddr_in *>(ifa->ifa_addr);
        if (sin->sin_addr.s_addr == htonl(INADDR_LOOPBACK))
            continue;
        char buf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
        result += "\n  ";
        result += ifa->ifa_name;
        result += ": ";
        result += buf;
    }
    freeifaddrs(ifa_list);
    return result;
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
 * Holds every libibverbs object that makes up the server's RDMA endpoint.
 */
struct RDMAEndpoint {
    struct ibv_context *context    = nullptr;
    struct ibv_pd      *pd         = nullptr;
    struct ibv_cq      *cq         = nullptr;
    struct ibv_qp      *qp         = nullptr;
    struct ibv_mr      *mr         = nullptr;
    uint8_t            *mem        = nullptr;
    size_t              mem_size   = 0;

    ~RDMAEndpoint() {
        if (qp)
            ibv_destroy_qp(qp);
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
 * Opens the NIC, allocates and registers a region_size buffer for remote reads, and
 * creates an RC queue pair left in the INIT state. Returns false on any failure.
 */
bool setup_endpoint(RDMAEndpoint &ep, uint64_t region_size, int dev_idx, int ib_port) {
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

    struct ibv_qp_init_attr qp_init_attr;
    memset(&qp_init_attr, 0, sizeof(qp_init_attr));
    qp_init_attr.send_cq          = ep.cq;
    qp_init_attr.recv_cq          = ep.cq;
    qp_init_attr.qp_type          = IBV_QPT_RC;
    qp_init_attr.cap.max_send_wr  = 2048;
    qp_init_attr.cap.max_recv_wr  = 2048;
    qp_init_attr.cap.max_send_sge = 16;
    qp_init_attr.cap.max_recv_sge = 16;

    ep.qp = ibv_create_qp(ep.pd, &qp_init_attr);
    if (!ep.qp) {
        std::cerr << "Could not create queue pair\n";
        return false;
    }

    struct ibv_qp_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.qp_state        = IBV_QPS_INIT;
    attr.port_num        = static_cast<uint8_t>(ib_port);
    attr.pkey_index      = 0;
    attr.qp_access_flags = IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE;
    if (ibv_modify_qp(ep.qp, &attr,
                      IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS)) {
        std::cerr << "Could not move QP to INIT: " << strerror(errno) << "\n";
        return false;
    }
    return true;
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
bool connect_qp(RDMAEndpoint &ep, const ibvQ &remote, uint32_t psn, int ib_port, int gid_idx) {
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

    if (ibv_modify_qp(ep.qp, &attr,
                      IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                          IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER)) {
        std::cerr << "Could not move QP to RTR: " << strerror(errno) << "\n";
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
    if (ibv_modify_qp(ep.qp, &attr,
                      IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY |
                          IBV_QP_MAX_QP_RD_ATOMIC | IBV_QP_PATH_MIG_STATE)) {
        std::cerr << "Could not move QP to RTS: " << strerror(errno) << "\n";
        return false;
    }
    return true;
}

/**
 * Accepts a single TCP connection on port and performs the Coyote-compatible QP
 * exchange: read the client's ibvQ, then send ours. Returns the accepted socket fd
 * (kept open for the lifetime of the server) or -1 on failure.
 *
 * The client's PSN is adopted as the shared PSN, so local.psn
 * is filled from the client's QP after the read and before the reply is sent. On
 * success remote_out holds the client's queue metadata.
 */
int exchange_qp(uint16_t port, ibvQ &local, ibvQ &remote_out) {
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
    if (listen(sockfd, 1) < 0) {
        std::cerr << "Could not listen on port " << port << "\n";
        close(sockfd);
        return -1;
    }

    int connfd = accept(sockfd, nullptr, nullptr);
    close(sockfd); // one client only; done listening
    if (connfd < 0) {
        std::cerr << "Failed to accept connection\n";
        return -1;
    }

    // Read the client's QP first, then reply with ours (Coyote's exchange order).
    if (read(connfd, &remote_out, sizeof(ibvQ)) != static_cast<ssize_t>(sizeof(ibvQ))) {
        std::cerr << "Failed to read client QP\n";
        close(connfd);
        return -1;
    }
    local.psn = remote_out.psn; // both sides share the client's PSN
    if (write(connfd, &local, sizeof(ibvQ)) != static_cast<ssize_t>(sizeof(ibvQ))) {
        std::cerr << "Failed to send server QP\n";
        close(connfd);
        return -1;
    }
    return connfd;
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

    uint64_t region_size = dir_header_size + payload_total;

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
              << " Bytes + payload " << payload_total << " Bytes = region " << region_size << " Bytes, on port "
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
    if (!setup_endpoint(ep, region_size, dev_idx, ib_port)) {
        return EXIT_FAILURE;
    }

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

    std::cout << "Waiting for connection from client on port " << port << ":" << local_ipv4_addresses() << std::endl;

    // Exchange QP metadata with the client. The client sends its QP first; we reply
    // with ours, advertising the region's rkey and address for remote reads.
    ibvQ local;
    local.ip_addr = local_ip;
    local.qpn     = ep.qp->qp_num;
    local.rkey    = ep.mr->rkey;
    local.vaddr   = ep.mem;
    local.size    = region_size;
    // Coyote encodes the GID as the RoCE IP repeated four times (see ibvQ::gidToUint).
    snprintf(local.gid, sizeof(local.gid), "%08x%08x%08x%08x", local_ip, local_ip, local_ip, local_ip);

    ibvQ remote;
    memset(&remote, 0, sizeof(remote));
    int connfd = exchange_qp(port, local, remote);
    if (connfd < 0) {
        return EXIT_FAILURE;
    }

    remote.print("Remote");
    local.print("Local");

    // Connect our QP to the client's and move it to RTS so the NIC can answer reads.
    if (!connect_qp(ep, remote, local.psn, ib_port, gid_idx)) {
        close(connfd);
        return EXIT_FAILURE;
    }

    std::cout << "Now serving... Press Ctrl+C to exit." << std::endl;

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);
    while (!g_stop.load()) {
        pause();
    }

    std::cout << "Shutting down!" << std::endl;
    close(connfd);
    return EXIT_SUCCESS;
}
