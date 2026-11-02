// The client side of S3 over RDMA: a keep-alive HTTP connection plus the RC QP it set up.
#pragma once

#include "rdma_token.hpp"

#include <infiniband/verbs.h>

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace oasis_s3 {

class RdmaDevice {
public:
	explicit RdmaDevice(int device_index);
	~RdmaDevice();

	RdmaDevice(const RdmaDevice &) = delete;
	RdmaDevice &operator=(const RdmaDevice &) = delete;

	ibv_context *context = nullptr;
	ibv_pd *pd = nullptr;
	int ib_port = 1;
	int gid_index = -1;
	ibv_gid gid = {};
	ibv_mtu path_mtu = IBV_MTU_4096;
};

struct HttpResponse {
	int status = 0;
	std::map<std::string, std::string> headers; // Names are lowercase.
	std::string body;

	std::string header(const std::string &name) const;
};

class HttpConnection {
public:
	HttpConnection(std::string host, uint16_t port);
	~HttpConnection();

	HttpConnection(const HttpConnection &) = delete;
	HttpConnection &operator=(const HttpConnection &) = delete;

	HttpResponse request(const std::string &method, const std::string &target,
	                     const std::vector<std::pair<std::string, std::string>> &headers = {});

private:
	std::string host_;
	uint16_t port_;
	int fd_ = -1;
	std::string buffer_;
};

// One QP and the HTTP connection that drives it. Use it from one thread at a time.
class RdmaConnection {
public:
	RdmaConnection(RdmaDevice &device, const std::string &host, uint16_t port);
	~RdmaConnection();

	RdmaConnection(const RdmaConnection &) = delete;
	RdmaConnection &operator=(const RdmaConnection &) = delete;

	// Has the server write [offset, offset + size) of `target` directly into `dst`. Throws if the
	// server does not use RDMA or if the object no longer has the ETag.
	void read(const std::string &target, uint64_t offset, uint64_t size, uint8_t *dst,
	          const std::string &expected_etag);

private:
	void Connect();

	RdmaDevice &device_;
	HttpConnection http_;
	ibv_cq *cq_ = nullptr;
	ibv_qp *qp_ = nullptr;
};

} // namespace oasis_s3
