// Standalone server that hosts a set of Parquet files in a Coyote RDMA
// memory region for the Oasis extension's rdma:// filesystem.
//
// Layout of the region (matches RDMAFileSystem::LoadDirectory):
//   uint64 dir_size  // total bytes of the directory header (including this field)
//   repeated until dir_size bytes consumed:
//     uint64 name_len
//     char[name_len] name
//     uint64 offset    // absolute offset within the region
//     uint64 size      // bytes
//   <file payloads, packed at the recorded offsets>

#include <coyote/cDefs.hpp>
#include <coyote/cThread.hpp>

#include <boost/program_options.hpp>

#include <algorithm>
#include <arpa/inet.h>
#include <atomic>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <ifaddrs.h>
#include <iomanip>
#include <iostream>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

constexpr int32_t DEFAULT_VFPGA_ID = 0;

std::atomic<bool> g_stop{false};
void              handle_signal(int) { g_stop.store(true); }

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

} // namespace

int main(int argc, char *argv[]) {
    uint16_t                 port;
    std::vector<std::string> files;

    boost::program_options::options_description options("RDMA server options");
    options.add_options()("help,h", "Show help")(
        "port,p", boost::program_options::value<uint16_t>(&port)->default_value(coyote::DEF_PORT),
        "TCP port for QP exchange")(
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

    // Set up Coyote + RDMA in server mode (no server address).
    std::unique_ptr<coyote::cThread> coyote_thread;
    try {
        coyote_thread = std::make_unique<coyote::cThread>(DEFAULT_VFPGA_ID, getpid(), 0);
    } catch (const boost::interprocess::interprocess_exception &e) {
        std::cerr << "Coyote initialization failed: " << e.what() << std::endl
                  << "This usually means the Coyote driver was not inserted properly." << std::endl;
        return EXIT_FAILURE;
    }

    std::cout << "Waiting for connection from client on port " << port << ":"
              << local_ipv4_addresses() << std::endl;

    auto mem =
        static_cast<uint8_t *>(coyote_thread->initRDMA(static_cast<uint32_t>(region_size), port));
    if (!mem) {
        std::cerr << "Coyote initRDMA failed\n";
        return EXIT_FAILURE;
    }
    std::memset(mem, 0, dir_header_size);

    // Lay out the directory.
    uint8_t *p = mem;
    write_header_value<uint64_t>(p, dir_header_size);

    uint64_t              cursor = dir_header_size;
    std::vector<uint64_t> offsets(files.size());
    for (size_t i = 0; i < files.size(); ++i) {
        offsets[i] = cursor;
        write_header_value<uint64_t>(p, static_cast<uint64_t>(names[i].size()));
        std::memcpy(p, names[i].data(), names[i].size());
        p += names[i].size();
        write_header_value<uint64_t>(p, offsets[i]);
        write_header_value<uint64_t>(p, sizes[i]);
        cursor += sizes[i];
    }

    // Copy file Bytes into the region at their assigned offsets.
    for (size_t i = 0; i < files.size(); ++i) {
        std::ifstream f(files[i], std::ios::binary);
        if (!f) {
            std::cerr << "Cannot reopen " << files[i] << std::endl;
            return EXIT_FAILURE;
        }
        f.read(reinterpret_cast<char *>(mem + offsets[i]), static_cast<std::streamsize>(sizes[i]));
        if (static_cast<uint64_t>(f.gcount()) != sizes[i]) {
            std::cerr << "Short read on " << files[i] << std::endl;
            return EXIT_FAILURE;
        }
    }

    std::cout << "Oasis RDMA Server: Serving " << files.size() << " file(s), directory header "
              << dir_header_size << " Bytes + payload " << payload_total << " Bytes = region "
              << region_size << " Bytes, on port " << port << std::endl;
    size_t max_name_len   = 0;
    size_t max_offset_len = 0;
    for (const auto &name : names) max_name_len = std::max(max_name_len, name.size());
    for (const auto &off : offsets)
        max_offset_len = std::max(max_offset_len, std::to_string(off).size());
    for (size_t i = 0; i < files.size(); ++i) {
        std::string quoted = "\"" + names[i] + "\"";
        std::cout << "  [" << i << "] " << std::left << std::setw(max_name_len + 2) << quoted
                  << " offset=" << std::right << std::setw(max_offset_len) << offsets[i]
                  << " size=" << sizes[i] << std::endl;
    }
    std::cout << "Press Ctrl+C to exit." << std::endl;

    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);
    while (!g_stop.load()) {
        pause();
    }

    std::cout << "Oasis RDMA Server: Shutting down" << std::endl;
    return EXIT_SUCCESS;
}
