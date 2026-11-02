#pragma once

#include "object_store.hpp"
#include "rdma_engine.hpp"

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace oasis_s3 {

/**
 * The S3 control plane, served over plain HTTP/1.1. Requests on one connection are handled strictly
 * in order.
 *
 * Each connection owns a blocking thread. The connection count is small, requests are cheap in RDMA
 * mode, and a request that hashes or copies a large object cannot delay any other connection.
 *
 * Signatures are not checked yet, so any client can read and write everything. This server belongs on
 * a trusted network.
 */
class S3Server {
  public:
    // `engine` may be null, in which case every RDMA request is declined with a 501.
    S3Server(ObjectStore &store, RdmaEngine *engine, uint64_t body_limit)
        : store_(store), engine_(engine), body_limit_(body_limit) {}

    // Serves until `stop` becomes true. Returns false if the port could not be bound.
    bool run(const std::string &address, uint16_t port, const std::atomic<bool> &stop);

  private:
    struct Connection {
        std::thread       thread;
        std::atomic<bool> done{false};
        int               fd = -1;
    };

    void serve_connection(int fd, Connection &connection);

    ObjectStore &store_;
    RdmaEngine  *engine_;
    uint64_t     body_limit_;
};

} // namespace oasis_s3
