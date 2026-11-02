// S3-compatible object server that moves payload over RDMA.
//
// Control is ordinary S3 over HTTP. A request carrying an x-amz-rdma-token has its payload moved
// by the server: an RDMA WRITE for GetObject, an RDMA READ for PutObject and UploadPart. A request
// without a token works like any S3 server and carries the payload in the HTTP body. Objects live
// in one memory region for now, so nothing survives a restart.

#include "arena.hpp"
#include "object_store.hpp"
#include "rdma_engine.hpp"
#include "s3_server.hpp"

#include <boost/program_options.hpp>

#include <atomic>
#include <cctype>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <pthread.h>
#include <sched.h>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

std::atomic<bool> g_stop{false};
void              handle_signal(int) { g_stop.store(true); }

// Parses a byte count such as 4096, 64M or 16G.
uint64_t parse_size(const std::string &text) {
    size_t   used  = 0;
    uint64_t value = std::stoull(text, &used);
    if (used < text.size()) {
        switch (std::toupper(static_cast<unsigned char>(text[used]))) {
        case 'K':
            return value << 10;
        case 'M':
            return value << 20;
        case 'G':
            return value << 30;
        case 'T':
            return value << 40;
        default:
            throw std::invalid_argument("Invalid size suffix in " + text);
        }
    }
    return value;
}

// Keeps every thread, and through first touch the arena, on the NIC's NUMA node. Crossing the
// socket interconnect would otherwise sit in the path of every packet.
void pin_to_nic_cpus(int device_index) {
    int          num_devices = 0;
    ibv_device **devices     = ibv_get_device_list(&num_devices);
    if (!devices || device_index >= num_devices) {
        if (devices) {
            ibv_free_device_list(devices);
        }
        return;
    }
    const std::string device = ibv_get_device_name(devices[device_index]);
    ibv_free_device_list(devices);

    std::ifstream file("/sys/class/infiniband/" + device + "/device/local_cpulist");
    std::string   list;
    if (!std::getline(file, list) || list.empty()) {
        return;
    }

    cpu_set_t set;
    CPU_ZERO(&set);
    std::stringstream ranges(list);
    std::string       range;
    while (std::getline(ranges, range, ',')) {
        const size_t dash  = range.find('-');
        const int    first = std::stoi(range.substr(0, dash));
        const int    last  = dash == std::string::npos ? first : std::stoi(range.substr(dash + 1));
        for (int cpu = first; cpu <= last; ++cpu) {
            CPU_SET(cpu, &set);
        }
    }
    if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0) {
        std::cerr << "Could not pin to the CPUs of " << device << ", continuing unpinned\n";
    }
}

// Loads --preload BUCKET=PATH: every regular file of a directory, or one file, keyed by file name.
bool preload(oasis_s3::ObjectStore &store, const std::string &spec) {
    const size_t equals = spec.find('=');
    if (equals == std::string::npos || equals == 0) {
        std::cerr << "--preload expects BUCKET=PATH, got " << spec << "\n";
        return false;
    }
    const std::string bucket = spec.substr(0, equals);
    const std::filesystem::path root(spec.substr(equals + 1));
    store.create_bucket(bucket);

    std::vector<std::filesystem::path> files;
    std::error_code                    ec;
    if (std::filesystem::is_directory(root, ec)) {
        for (const auto &entry : std::filesystem::directory_iterator(root)) {
            if (entry.is_regular_file()) {
                files.push_back(entry.path());
            }
        }
    } else {
        files.push_back(root);
    }

    std::vector<std::thread> loaders;
    std::atomic<bool>        ok{true};
    std::atomic<size_t>      next{0};
    const size_t thread_count = std::min<size_t>(std::max(std::thread::hardware_concurrency() / 2, 1u), 16);
    for (size_t i = 0; i < thread_count; ++i) {
        loaders.emplace_back([&] {
            for (size_t index = next.fetch_add(1); index < files.size(); index = next.fetch_add(1)) {
                std::ifstream file(files[index], std::ios::binary | std::ios::ate);
                if (!file) {
                    std::cerr << "Cannot open " << files[index] << "\n";
                    ok.store(false);
                    continue;
                }
                const auto size   = static_cast<uint64_t>(file.tellg());
                auto       object = store.allocate(size);
                if (!object) {
                    std::cerr << "The arena is too small for " << files[index] << "\n";
                    ok.store(false);
                    continue;
                }
                file.seekg(0);
                file.read(reinterpret_cast<char *>(object->data()), static_cast<std::streamsize>(size));
                if (static_cast<uint64_t>(file.gcount()) != size) {
                    std::cerr << "Short read on " << files[index] << "\n";
                    ok.store(false);
                    continue;
                }
                object->etag          = oasis_s3::md5_hex(object->data(), size);
                object->last_modified = std::time(nullptr);
                store.put(bucket, files[index].filename().string(), std::move(object));
                // Built first: the loaders print concurrently and a line must stay in one piece.
                std::ostringstream line;
                line << "  s3://" << bucket << "/" << files[index].filename().string() << " (" << size
                     << " bytes)\n";
                std::cout << line.str() << std::flush;
            }
        });
    }
    for (auto &loader : loaders) {
        loader.join();
    }
    return ok.load();
}

} // namespace

int main(int argc, char *argv[]) {
    std::string              listen;
    uint16_t                 port;
    std::string              capacity_text;
    size_t                   workers;
    int                      device, ib_port, gid_index, traffic_class, service_level;
    bool                     no_rdma = false;
    std::vector<std::string> preloads;

    namespace po = boost::program_options;
    po::options_description options("Oasis S3 server options");
    // clang-format off
    options.add_options()
        ("help,h", "Show help")
        ("listen,l", po::value<std::string>(&listen)->default_value("0.0.0.0"), "HTTP listen address")
        ("port,p", po::value<uint16_t>(&port)->default_value(9000), "HTTP port")
        ("capacity,c", po::value<std::string>(&capacity_text)->default_value("16G"),
         "Object arena size, e.g. 64G")
        ("preload", po::value<std::vector<std::string>>(&preloads)->multitoken(),
         "Load BUCKET=PATH at startup, a file or every file of a directory (repeatable)")
        ("device,d", po::value<int>(&device)->default_value(0), "RDMA device index")
        ("ib_port,b", po::value<int>(&ib_port)->default_value(1), "HCA physical port number")
        ("gid_idx,g", po::value<int>(&gid_index)->default_value(-1),
         "Local GID index, -1 picks the first RoCE v2 IPv4 GID")
        ("tclass", po::value<int>(&traffic_class)->default_value(0), "RoCE traffic class")
        ("sl", po::value<int>(&service_level)->default_value(0), "Service level")
        ("workers,w", po::value<size_t>(&workers)->default_value(2), "RDMA worker threads")
        ("no-rdma", po::bool_switch(&no_rdma), "Serve HTTP only and decline every RDMA request");
    // clang-format on
    po::variables_map vm;
    try {
        po::store(po::parse_command_line(argc, argv, options), vm);
        po::notify(vm);
    } catch (const po::error &error) {
        std::cerr << error.what() << "\n" << options << std::endl;
        return EXIT_FAILURE;
    }
    if (vm.count("help")) {
        std::cout << options << std::endl;
        return EXIT_SUCCESS;
    }

    uint64_t capacity = 0;
    try {
        capacity = parse_size(capacity_text);
    } catch (const std::exception &) {
        std::cerr << "Invalid capacity " << capacity_text << "\n";
        return EXIT_FAILURE;
    }

    try {
        if (!no_rdma) {
            pin_to_nic_cpus(device);
        }
        oasis_s3::Arena arena(capacity);
        std::cout << "Object arena: " << arena.capacity() << " bytes on " << arena.page_kind() << " pages"
                  << std::endl;

        std::unique_ptr<oasis_s3::RdmaEngine> engine;
        if (!no_rdma) {
            oasis_s3::RdmaEngine::Options engine_options;
            engine_options.device_index  = device;
            engine_options.ib_port       = ib_port;
            engine_options.gid_index     = gid_index;
            engine_options.traffic_class = traffic_class;
            engine_options.service_level = service_level;
            engine_options.workers       = workers;
            engine = std::make_unique<oasis_s3::RdmaEngine>(engine_options, arena.data(), arena.capacity());
            std::cout << "RDMA: " << engine->device_name() << " GID index " << engine->gid_index() << " ("
                      << engine->gid_string() << ")" << std::endl;
        }

        oasis_s3::ObjectStore store(arena);
        for (const auto &spec : preloads) {
            if (!preload(store, spec)) {
                return EXIT_FAILURE;
            }
        }

        struct sigaction action;
        std::memset(&action, 0, sizeof(action));
        action.sa_handler = handle_signal;
        sigaction(SIGINT, &action, nullptr);
        sigaction(SIGTERM, &action, nullptr);
        signal(SIGPIPE, SIG_IGN);

        oasis_s3::S3Server server(store, engine.get(), arena.capacity());
        std::cout << "Serving S3 on " << listen << ":" << port << ". Press Ctrl+C to exit." << std::endl;
        if (!server.run(listen, port, g_stop)) {
            return EXIT_FAILURE;
        }
        std::cout << "Shutting down!" << std::endl;
    } catch (const std::exception &error) {
        std::cerr << error.what() << std::endl;
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
